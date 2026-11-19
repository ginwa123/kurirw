//! The runner page's model: a flow program, its generated script, and the steps a run sends.
const std = @import("std");
const glinlandui = @import("glinlandui");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const request_job = @import("../../data/remote/request_job.zig");
const env_mod = @import("../../domain/env.zig");
const flow_mod = @import("../../domain/flow.zig");
const runner_mod = @import("../../domain/runner.zig");
const script_mod = @import("../../domain/script.zig");
const data_file = @import("../../domain/data_file.zig");
const run_collection = @import("../../domain/usecase/run_collection.zig");
const send_request = @import("../../domain/usecase/send_request.zig");
const file_picker = @import("../../data/local/file_picker.zig");

const state_mod = @import("../state.zig");
const session_mod = @import("../shell/session.zig");
const env_vm = @import("../env/view_model.zig");
const pump_mod = @import("../shell/pump.zig");

const Session = session_mod.Session;
const Env = env_vm.Env;
const Path = state_mod.Path;
const Allocator = std.mem.Allocator;

pub const page_id = "kurir.runner.page";
pub const run_id = "kurir.runner.run";
pub const stop_id = "kurir.runner.stop";
pub const close_id = "kurir.runner.close";
pub const data_id = "kurir.runner.data";
pub const iterations_id = "kurir.runner.iterations";
pub const delay_id = "kurir.runner.delay";
pub const send_id = "kurir.runner.add.send";
pub const delay_step_id = "kurir.runner.add.delay";
pub const loop_id = "kurir.runner.add.loop";

// How much program the page holds: a flow is a screen or two of text, not a file of megabytes.
pub const flow_cap: usize = 16 * 1024;

pub const Runner = struct {
    session: *Session = undefined,
    env: *Env = undefined,
    pump: *pump_mod.Pump = undefined,
    dialogs: *file_picker.Dialogs = undefined,
    // The shell builds the transport (a real one, or a test's fake) for the arena the request will use.
    transport_fn: ?*const fn (?*anyopaque, Allocator) http_mod.Transport = null,
    transport_ctx: ?*anyopaque = null,

    open: bool = false,
    phase: state_mod.RunnerPhase = .idle,
    // The program and the steps it expands to own their strings, so one arena is reset whenever it is re-read.
    arena: std.heap.ArenaAllocator = undefined,
    // The data file outlives a re-parse, so its rows live in their own arena.
    data_arena: std.heap.ArenaAllocator = undefined,
    started: bool = false,
    flow_buf: [flow_cap]u8 = undefined,
    flow_len: usize = 0,
    program: flow_mod.Flow = .{},
    steps: []flow_mod.Step = &.{},
    data: data_file.Data = .{},
    data_name: []const u8 = "",
    at: usize = 0,
    iteration: usize = 0,
    iterations: usize = 1,
    iterations_text: [8]u8 = @splat('1'),
    iterations_len: usize = 1,
    delay_text: [8]u8 = @splat('0'),
    delay_len: usize = 1,
    next_at_ns: i96 = 0,
    rows: [state_mod.max_runner_rows]state_mod.RunnerRow = undefined,
    row_count: usize = 0,
    ok: usize = 0,
    failed: usize = 0,
    done: usize = 0,
    total_ms: u64 = 0,
    job: ?Pending = null,
    // The document item this page is bound to, when it was opened from a saved runner.
    flow_path: ?Path = null,
    // True while the program is being read from the document, so reading does not write it back.
    loading: bool = false,
    note: [160]u8 = undefined,
    note_len: usize = 0,
    // Which row a box's children callback is drawing, and which cell of it (the callback gets only the scope).
    draw_row: usize = 0,
    draw_cell: usize = 0,

    const Pending = struct {
        job: *request_job.Job,
        step: flow_mod.Step,
        iteration: usize,
    };

    pub fn start(self: *Runner, session: *Session, env: *Env, pump: *pump_mod.Pump, dialogs: *file_picker.Dialogs) void {
        self.session = session;
        self.env = env;
        self.pump = pump;
        self.dialogs = dialogs;
        self.arena = .init(session.gpa);
        self.data_arena = .init(session.gpa);
        self.rows = undefined;
        self.flow_len = 0;
        self.started = true;
    }

    pub fn deinit(self: *Runner) void {
        if (!self.started) return;
        if (self.job) |pending| {
            if (pending.job.poll()) pending.job.destroy(self.session.gpa) else pending.job.abandon();
        }
        self.job = null;
        self.arena.deinit();
        self.data_arena.deinit();
        self.started = false;
    }

    // ---- the program ------------------------------------------------------------------------------------

    // A saved runner, opened from its row: the document is the source of the program.
    pub fn openFlow(self: *Runner, path: Path) void {
        const node = self.session.nodeAt(path) orelse return;
        if (!postman.isFlow(node.*)) return;
        // One run at a time: a step in flight belongs to the program that is on screen.
        if (self.phase == .running or self.phase == .stopping) return self.session.failNow("This runner is still running. Stop it before opening another one.");
        self.flow_path = path;
        self.open = true;
        self.phase = .idle;
        self.reset();
        self.pump.set(false);
        self.loading = true;
        self.setFlow(postman.flowOf(node.*));
        self.loading = false;
        self.session.setStatus(false, "Runner {s}: {d} steps.", .{ Session.name(node.*), self.steps.len });
        self.session.touch();
    }

    // The program a row seeds: a request is one `send`, a collection or folder sends every request under it.
    pub fn programFor(self: *Runner, arena: Allocator, path: Path) []const u8 {
        const node = self.session.nodeAt(path) orelse return "";
        var text: std.ArrayList(u8) = .empty;
        if (postman.isRequest(node.*)) {
            appendSend(arena, &text, Session.name(node.*)) catch return text.items;
            return text.items;
        }
        const steps = runner_mod.collect(arena, node.*, addressOf(path)) catch &.{};
        for (steps) |step| appendSend(arena, &text, step.name) catch return text.items;
        return text.items;
    }

    // The script IS the source: re-read it and the steps follow. A broken line keeps what parsed.
    pub fn setFlow(self: *Runner, text: []const u8) void {
        const length = @min(text.len, flow_cap);
        @memcpy(self.flow_buf[0..length], text[0..length]);
        self.flow_len = length;
        self.reparse();
        // A page bound to a saved runner writes every edit back to the document; Ctrl+S then saves it.
        if (!self.loading) self.persistFlow();
    }

    // The program goes back into the item it came from, marked unsaved like any other edit.
    fn persistFlow(self: *Runner) void {
        const path = self.flow_path orelse return;
        const node = self.session.nodeAt(path) orelse return;
        postman.setFlowSource(self.session.docArena(), node, self.flow_buf[0..self.flow_len]) catch return;
        self.session.markDirty(path);
    }

    fn reparse(self: *Runner) void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        self.program = flow_mod.parse(arena, self.flow_buf[0..self.flow_len]) catch .{};
        self.steps = flow_mod.expand(arena, self.program, self.data.count()) catch &.{};
        self.session.touch();
    }

    // The script the page shows: written from the program, so a change made through the UI cannot drift.
    pub fn script(self: *Runner, arena: Allocator) []const u8 {
        if (self.program.failure) |_| return self.flow_buf[0..self.flow_len];
        return flow_mod.write(arena, self.program) catch self.flow_buf[0..self.flow_len];
    }

    // Our own text with a line appended, which is what a button on the page does.
    fn appendLine(self: *Runner, line: []const u8) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.session.gpa);
        text.appendSlice(self.session.gpa, self.flow_buf[0..self.flow_len]) catch return;
        if (text.items.len > 0 and text.items[text.items.len - 1] != '\n') text.append(self.session.gpa, '\n') catch return;
        text.appendSlice(self.session.gpa, line) catch return;
        text.append(self.session.gpa, '\n') catch return;
        self.setFlow(text.items);
    }

    // A request chosen in the tree becomes one more `send` at the end of the program.
    pub fn addSend(self: *Runner) void {
        const node = self.session.selectedNode() orelse return self.session.failNow("Select a request in the tree first.");
        if (!postman.isRequest(node.*)) return self.session.failNow("Select a request, not a folder.");
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.session.gpa);
        line.appendSlice(self.session.gpa, "send \"") catch return;
        line.appendSlice(self.session.gpa, Session.name(node.*)) catch return;
        line.appendSlice(self.session.gpa, "\"") catch return;
        self.appendLine(line.items);
    }

    pub fn addDelay(self: *Runner) void {
        self.appendLine("delay 250");
    }

    // Wrap the whole program in the data loop: the UI's way of saying "one pass per row".
    pub fn wrapData(self: *Runner) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.session.gpa);
        text.appendSlice(self.session.gpa, "for row in data do\n") catch return;
        var it = std.mem.splitScalar(u8, self.flow_buf[0..self.flow_len], '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            text.appendSlice(self.session.gpa, "  ") catch return;
            text.appendSlice(self.session.gpa, line) catch return;
            text.append(self.session.gpa, '\n') catch return;
        }
        text.appendSlice(self.session.gpa, "end\n") catch return;
        self.setFlow(text.items);
    }

    pub fn close(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) self.stop();
        // With nothing in flight there is no frame to wait for, so the pump goes off with the page.
        if (self.job == null) self.pump.set(false);
        self.open = false;
        self.session.touch();
    }

    // The row this page was bound to is gone: the page goes with it, instead of writing into a dead path.
    pub fn detach(self: *Runner, path: Path) void {
        const bound = self.flow_path orelse return;
        if (!Path.eql(bound, path)) return;
        if (self.phase == .running or self.phase == .stopping) self.stop();
        self.flow_path = null;
        self.open = false;
        self.pump.set(false);
        self.session.touch();
    }

    fn reset(self: *Runner) void {
        self.row_count = 0;
        self.ok = 0;
        self.failed = 0;
        self.done = 0;
        self.total_ms = 0;
        self.at = 0;
        self.iteration = 0;
        self.note_len = 0;
    }

    pub fn setIterations(self: *Runner, text: []const u8) void {
        self.iterations_len = copyNumber(&self.iterations_text, text, self.iterations_text[0..self.iterations_len]);
        self.iterations = std.fmt.parseInt(usize, self.iterations_text[0..self.iterations_len], 10) catch 1;
    }

    pub fn setDelay(self: *Runner, text: []const u8) void {
        self.delay_len = copyNumber(&self.delay_text, text, self.delay_text[0..self.delay_len]);
    }

    pub fn onIterationsTyped(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.setIterations(text);
    }

    pub fn onDelayTyped(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.setDelay(text);
    }

    pub fn chooseData(self: *Runner) void {
        const dialogs = self.dialogs;
        if (!dialogs.available) return self.session.failNow("This build has no file dialog.");
        const picked = dialogs.open_fn(dialogs.ctx, self.session.gpa, "Choose a CSV or JSON data file") orelse return;
        defer self.session.gpa.free(picked);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.session.io, picked, self.data_arena.allocator(), .limited(8 * 1024 * 1024)) catch
            return self.session.failNow("That data file could not be read.");
        const parsed = data_file.parse(self.data_arena.allocator(), bytes) catch
            return self.session.failNow("That data file is too large to read.");
        if (parsed.failure) |failure| {
            self.session.setStatus(true, "{s}", .{failure.message});
            return;
        }
        self.data = parsed;
        self.data_name = std.fs.path.basename(picked);
        // The data file decides how many copies a `for row in data` loop expands to.
        self.reparse();
        self.session.setStatus(false, "Runner data: {d} rows, {d} columns.", .{ parsed.count(), parsed.columns.len });
    }

    // ---- the run ----------------------------------------------------------------------------------------

    pub fn run(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) return;
        self.reparse();
        if (self.program.failure) |failure| {
            self.session.setStatus(true, "Line {d}: {s}", .{ failure.line, failure.message });
            return;
        }
        if (self.steps.len == 0) return self.session.failNow("This flow sends nothing. Add a `send \"request\"` line.");
        self.reset();
        self.phase = .running;
        self.next_at_ns = 0;
        self.pump.set(true);
        self.session.setStatus(false, "Runner: {d} steps x {d}.", .{ self.steps.len, self.iterations });
        self.session.touch();
        self.tick();
    }

    pub fn stop(self: *Runner) void {
        if (self.phase != .running) return;
        self.phase = .stopping;
        self.session.setStatus(false, "Runner: stopping after the step in flight.", .{});
        self.session.touch();
    }

    pub fn tick(self: *Runner) void {
        if (self.phase != .running and self.phase != .stopping) return;
        if (self.job) |pending| {
            if (!pending.job.poll()) return;
            const result = pending.job.take();
            self.finish(pending, result);
            pending.job.destroy(self.session.gpa);
            self.job = null;
            if (self.phase == .stopping) return self.finishRun(.stopped);
            self.advance();
            return;
        }
        if (self.phase != .running) return;
        if (self.at >= self.steps.len) {
            self.iteration += 1;
            self.at = 0;
            if (self.iteration >= self.iterations) return self.finishRun(.finished);
        }
        if (self.next_at_ns != 0 and nowNs(self.session.io) < self.next_at_ns) return;
        self.begin();
    }

    fn begin(self: *Runner) void {
        const step = self.steps[self.at];
        const path = self.session.findRequest(step.request) orelse {
            self.failStep(step, "no saved request has that name");
            return;
        };
        const node = self.session.nodeAt(path) orelse {
            self.failStep(step, "that request is gone");
            return;
        };
        const collection_path = Path{ .depth = 1, .segments = splatOf(path.segments[0]) };
        const collection = self.session.nodeAt(collection_path) orelse {
            self.failStep(step, "its collection is gone");
            return;
        };
        const arena = self.arena.allocator();
        const data_pairs = if (step.data_row) |row| data_file.pairs(arena, self.data, row) catch &.{} else &.{};
        const scope = run_collection.scopeFor(arena, node.*, collection.*, self.env.activeVars(), data_pairs);
        const host = script_mod.Host{ .ctx = self.env, .get_fn = scriptGet, .set_fn = scriptSet };

        // The saved request's own Pre-req runs first: `send` runs the request, not just its URL.
        const own_pre = postman.scriptOf(node.*, .pre);
        if (own_pre.len > 0) {
            const outcome = script_mod.run(arena, own_pre, null, host);
            if (outcome.failure) |failure| {
                self.failStep(step, script_mod.describe(arena, failure));
                return;
            }
        }

        // The statements written above the send run before it, with no answer to read.
        if (step.pre.len > 0) {
            const outcome = script_mod.run(arena, step.pre, null, host);
            if (outcome.failure) |failure| {
                self.failStep(step, script_mod.describe(arena, failure));
                return;
            }
        }

        const gpa = self.session.gpa;
        const job = request_job.Job.create(gpa, self.session.io) catch {
            self.failStep(step, "could not start the request");
            return;
        };
        const wire = send_request.build(job.arena(), node.*, .{ .boundary = "kurir-runner", .scope = scope }) catch |err| {
            job.destroy(gpa);
            self.failStep(step, switch (err) {
                error.NoUrl => "this request has no URL",
                error.NotARequest => "this node is not a request",
                error.OutOfMemory => "not enough memory to expand this request",
            });
            return;
        };
        job.request = .{ .method = wire.method, .url = wire.url, .headers = wire.headers, .body = wire.body };
        job.start(self.transport(job.arena()));
        self.job = .{ .job = job, .step = step, .iteration = self.iteration };
        self.pump.set(true);
        self.session.setStatus(false, "Runner: {s}…", .{step.request});
        self.session.touch();
    }

    fn transport(self: *Runner, arena: Allocator) http_mod.Transport {
        const build = self.transport_fn orelse return .{ .ctx = null, .arena = arena, .send_fn = http_mod.sendOffline };
        return build(self.transport_ctx, arena);
    }

    fn failStep(self: *Runner, step: flow_mod.Step, reason: []const u8) void {
        self.pushRow(.{
            .iteration = self.iteration + 1,
            .name = step.request,
            .method = "",
            .ok = false,
            .failure = runner_mod.failureLabel(.request),
        }, reason);
        self.advance();
    }

    fn finish(self: *Runner, pending: Pending, result: http_mod.Result) void {
        const arena = self.arena.allocator();
        const host = script_mod.Host{ .ctx = self.env, .get_fn = scriptGet, .set_fn = scriptSet };
        var found: std.ArrayList(script_mod.Test) = .empty;
        var post_failed = false;
        var error_text: []const u8 = "";

        // The saved request's own Post-res runs, then the statements written under the send.
        const node_post: []const u8 = if (self.session.findRequest(pending.step.request)) |path| blk: {
            const node = self.session.nodeAt(path) orelse break :blk "";
            break :blk postman.scriptOf(node.*, .post);
        } else "";
        for ([_][]const u8{ node_post, pending.step.post }) |source| {
            if (source.len == 0) continue;
            const headers = headersOf(arena, result) catch &.{};
            const answer = script_mod.Response{ .status = result.status, .headers = headers, .body = result.body };
            const outcome = script_mod.run(arena, source, answer, host);
            for (outcome.tests) |one| found.append(arena, one) catch {};
            if (outcome.failure) |failure| {
                post_failed = true;
                error_text = script_mod.describe(arena, failure);
            }
        }
        const tests = found.items;
        if (result.failed) error_text = if (result.error_message.len > 0) result.error_message else result.error_title;
        const verdict = runner_mod.verdict(result, post_failed, tests);
        var passed: usize = 0;
        for (tests) |one| {
            if (one.passed) passed += 1;
        }
        self.pushRow(.{
            .iteration = pending.iteration + 1,
            .name = pending.step.request,
            .method = "",
            .status = result.status,
            .time_ms = result.time_ms,
            .ok = verdict.ok,
            .failure = runner_mod.failureLabel(verdict.failure),
            .tests_passed = passed,
            .tests_total = tests.len,
        }, error_text);
        self.next_at_ns = if (pending.step.delay_ms > 0) nowNs(self.session.io) + @as(i96, pending.step.delay_ms) * 1_000_000 else 0;
        // The next step needs a frame of its own, so the pump stays on until the run is over.
        self.pump.set(true);
    }

    fn pushRow(self: *Runner, row: state_mod.RunnerRow, error_text: []const u8) void {
        if (self.row_count < state_mod.max_runner_rows) {
            self.rows[self.row_count] = row;
            self.row_count += 1;
        }
        self.done += 1;
        self.total_ms += row.time_ms;
        if (row.ok) self.ok += 1 else self.failed += 1;
        if (error_text.len > 0) {
            self.session.setStatus(true, "Runner: {s} — {s}", .{ row.name, error_text });
        } else {
            self.session.setStatus(!row.ok, "Runner: {s} {s}.", .{ row.name, row.failure });
        }
        self.session.touch();
    }

    fn advance(self: *Runner) void {
        self.at += 1;
        if (self.at < self.steps.len) return;
        self.at = 0;
        self.iteration += 1;
        if (self.iteration >= self.iterations) return self.finishRun(.finished);
    }

    fn finishRun(self: *Runner, phase: state_mod.RunnerPhase) void {
        self.phase = phase;
        self.pump.set(false);
        self.job = null;
        self.session.setStatus(phase == .stopped, "Runner {s}: {d} steps, {d} ok, {d} failed.", .{
            if (phase == .stopped) "stopped" else "finished",
            self.done,
            self.ok,
            self.failed,
        });
        self.session.touch();
    }

    // ---- the page's snapshot ----------------------------------------------------------------------------

    pub fn snapshot(self: *Runner, u: *state_mod.UiState, arena: Allocator) void {
        u.runner_open = self.open;
        u.runner_phase = self.phase;
        // The title is the runner itself, read from the document, so a rename in the tree renames the page.
        u.runner_name = if (self.flow_path) |path| blk: {
            const node = self.session.nodeAt(path) orelse break :blk "";
            break :blk Session.name(node.*);
        } else "";
        u.runner_flow = self.script(arena);
        u.runner_error = if (self.program.failure) |failure|
            frameText(arena, "line {d}: {s}", .{ failure.line, failure.message })
        else
            "";
        u.runner_iterations = self.iterations_text[0..self.iterations_len];
        u.runner_delay = self.delay_text[0..self.delay_len];
        u.runner_env = self.env.activeName() orelse "No environment";
        u.runner_data = if (self.data_name.len > 0) self.data_name else "None";
        u.runner_selected = self.steps.len;
        u.runner_total = self.steps.len * @max(@as(usize, 1), self.iterations);
        u.runner_done = self.done;
        u.runner_ok = self.ok;
        u.runner_failed = self.failed;
        u.runner_ms = self.total_ms;
        u.runner_note = self.note[0..self.note_len];
        u.runner_steps = &.{};

        const rows: []state_mod.RunnerRow = arena.alloc(state_mod.RunnerRow, self.row_count) catch &.{};
        @memcpy(rows, self.rows[0..self.row_count]);
        u.runner_rows = rows;
    }
};

fn frameText(arena: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "";
}

// One `send "name"` line, appended to a program being seeded from a row of the tree.
fn appendSend(alloc: Allocator, text: *std.ArrayList(u8), name: []const u8) !void {
    try text.appendSlice(alloc, "send \"");
    try text.appendSlice(alloc, name);
    try text.appendSlice(alloc, "\"\n");
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

fn scriptGet(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
    const env: *Env = @ptrCast(@alignCast(ctx.?));
    return env.lookupCurrent(name);
}

fn scriptSet(ctx: ?*anyopaque, name: []const u8, value: []const u8) bool {
    const env: *Env = @ptrCast(@alignCast(ctx.?));
    return env.setCurrent(name, value);
}

fn headersOf(arena: Allocator, result: http_mod.Result) Allocator.Error![]const script_mod.Header {
    if (result.headers.len == 0) return &.{};
    const headers = try arena.alloc(script_mod.Header, result.headers.len);
    for (result.headers, 0..) |header, index| headers[index] = .{ .name = header.name, .value = header.value };
    return headers;
}

pub fn addressOf(path: Path) runner_mod.Address {
    var address = runner_mod.Address{};
    address.depth = path.depth;
    for (path.segments[0..path.depth], 0..) |segment, index| {
        if (index < runner_mod.max_depth) address.segments[index] = segment;
    }
    return address;
}

fn splatOf(value: u16) [state_mod.max_depth]u16 {
    var segments: [state_mod.max_depth]u16 = @splat(0);
    segments[0] = value;
    return segments;
}

// A typed number kept in its own buffer: only digits, at most the buffer, and the old text when there are none.
fn copyNumber(buffer: *[8]u8, text: []const u8, previous: []const u8) usize {
    var length: usize = 0;
    for (text) |byte| {
        if (length == buffer.len) break;
        if (!std.ascii.isDigit(byte)) continue;
        buffer[length] = byte;
        length += 1;
    }
    if (length > 0) return length;
    std.mem.copyForwards(u8, buffer[0..previous.len], previous);
    return previous.len;
}

const testing = std.testing;

test "an address and a path are the same shape" {
    const path = Path.empty.child(2).child(5);
    const address = addressOf(path);
    try testing.expectEqual(@as(usize, 2), address.depth);
    try testing.expectEqual(@as(u16, 5), address.segments[1]);
}

test "a typed number keeps its digits, and an empty one keeps what was there" {
    var buffer: [8]u8 = @splat('1');
    const length = copyNumber(&buffer, "1a2x3", buffer[0..1]);
    try testing.expectEqualStrings("123", buffer[0..length]);
    const kept = copyNumber(&buffer, "", buffer[0..length]);
    try testing.expectEqualStrings("123", buffer[0..kept]);
}
