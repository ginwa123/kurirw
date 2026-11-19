//! The runner page's model: the plan, one request at a time on its own task, and the rows it produced.
const std = @import("std");
const glinlandui = @import("glinlandui");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const request_job = @import("../../data/remote/request_job.zig");
const env_mod = @import("../../domain/env.zig");
const runner_mod = @import("../../domain/runner.zig");
const script_mod = @import("../../domain/script.zig");
const data_file = @import("../../domain/data_file.zig");
const run_collection = @import("../../domain/usecase/run_collection.zig");
const send_request = @import("../../domain/usecase/send_request.zig");

const state_mod = @import("../state.zig");
const session_mod = @import("../shell/session.zig");
const file_picker = @import("../../data/local/file_picker.zig");
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
pub const step_prefix = "kurir.runner.step.";

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
    root: runner_mod.Address = .{},
    collection_name: []const u8 = "",
    // The plan and the data rows own their strings, so one arena per run is reset when it starts.
    arena: std.heap.ArenaAllocator = undefined,
    started: bool = false,
    plan: std.ArrayList(runner_mod.Step) = .empty,
    data: data_file.Data = .{},
    data_name: []const u8 = "",
    at: usize = 0,
    iteration: usize = 0,
    iterations: usize = 1,
    delay_ms: u32 = 0,
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
    note: [160]u8 = undefined,
    note_len: usize = 0,
    // One click context per planned row (a click lands on a later frame than the one that registered it).
    step_ctxs: [runner_mod.max_steps]StepCtx = undefined,
    // Which row a box's children callback is drawing: the callback is handed the scope, not a value.
    draw_row: usize = 0,
    // The cell a row is on, so each of a frame's boxes gets an id of its own.
    draw_cell: usize = 0,

    pub const StepCtx = struct {
        runner: *Runner,
        index: usize,
    };

    const Pending = struct {
        job: *request_job.Job,
        step: runner_mod.Step,
        iteration: usize,
    };

    pub fn start(self: *Runner, session: *Session, env: *Env, pump: *pump_mod.Pump, dialogs: *file_picker.Dialogs) void {
        self.dialogs = dialogs;
        self.session = session;
        self.env = env;
        self.pump = pump;
        self.arena = .init(session.gpa);
        self.rows = undefined;
        self.row_count = 0;
        for (&self.step_ctxs, 0..) |*ctx, index| ctx.* = .{ .runner = self, .index = index };
        self.started = true;
    }

    // A click on a row of the plan: send it, or skip it.
    pub fn onStep(ctx: ?*anyopaque) void {
        const step: *StepCtx = @ptrCast(@alignCast(ctx.?));
        step.runner.toggle(step.index);
    }

    // The two numbers, typed: the field hands its text, and the model keeps the digits.
    pub fn onIterationsTyped(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.setIterations(text);
    }

    pub fn onDelayTyped(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.setDelay(text);
    }

    pub fn deinit(self: *Runner) void {
        if (!self.started) return;
        if (self.job) |pending| {
            if (pending.job.poll()) pending.job.destroy(self.session.gpa) else pending.job.abandon();
        }
        self.job = null;
        self.arena.deinit();
        self.plan.deinit(self.session.gpa);
        self.started = false;
    }

    // ---- the page's intents -----------------------------------------------------------------------------

    // Open the page on a collection or a folder, and plan what a run would send.
    pub fn openAt(self: *Runner, path: Path) void {
        const node = self.session.nodeAt(path) orelse return self.session.failNow("That collection is gone. Right-click it again.");
        if (postman.isRequest(node.*)) return self.session.failNow("Select a collection or a folder to run.");
        self.open = true;
        self.phase = .idle;
        self.root = addressOf(path);
        self.collection_name = Session.name(node.*);
        self.planIt(node.*);
        self.row_count = 0;
        self.ok = 0;
        self.failed = 0;
        self.done = 0;
        self.total_ms = 0;
        self.at = 0;
        self.iteration = 0;
        self.note_len = 0;
        self.session.setStatus(false, "Runner ready: {d} requests.", .{self.plan.items.len});
        self.session.touch();
    }

    fn planIt(self: *Runner, node: postman.Value) void {
        _ = self.arena.reset(.retain_capacity);
        self.plan.clearRetainingCapacity();
        const arena = self.arena.allocator();
        const steps = runner_mod.collect(arena, node, self.root) catch return;
        for (steps) |step| self.plan.append(self.session.gpa, step) catch break;
    }

    pub fn close(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) self.stop();
        self.open = false;
        self.session.touch();
    }

    // One tick box in the left list.
    pub fn toggle(self: *Runner, index: usize) void {
        if (index >= self.plan.items.len) return;
        if (self.phase == .running or self.phase == .stopping) return;
        self.plan.items[index].enabled = !self.plan.items[index].enabled;
        self.session.touch();
    }

    pub fn selected(self: *Runner) usize {
        var count: usize = 0;
        for (self.plan.items) |step| {
            if (step.enabled) count += 1;
        }
        return count;
    }

    // The two numbers, as they are typed: a bad one is not an error, it is the value it was before.
    pub fn setIterations(self: *Runner, text: []const u8) void {
        self.iterations_len = copyNumber(&self.iterations_text, text, self.iterations_text[0..self.iterations_len]);
        self.iterations = std.fmt.parseInt(usize, self.iterations_text[0..self.iterations_len], 10) catch 1;
    }

    pub fn setDelay(self: *Runner, text: []const u8) void {
        self.delay_len = copyNumber(&self.delay_text, text, self.delay_text[0..self.delay_len]);
        self.delay_ms = std.fmt.parseInt(u32, self.delay_text[0..self.delay_len], 10) catch 0;
    }

    pub fn chooseData(self: *Runner) void {
        const dialogs = self.dialogs;
        if (!dialogs.available) return self.session.failNow("This build has no file dialog.");
        if (!dialogs.available) return self.session.failNow("This build has no file dialog.");
        const picked = dialogs.open_fn(dialogs.ctx, self.session.gpa, "Choose a CSV or JSON data file") orelse return;
        defer self.session.gpa.free(picked);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.session.io, picked, self.arena.allocator(), .limited(8 * 1024 * 1024)) catch
            return self.session.failNow("That data file could not be read.");
        const parsed = data_file.parse(self.arena.allocator(), bytes) catch
            return self.session.failNow("That data file is too large to read.");
        if (parsed.failure) |failure| {
            self.session.setStatus(true, "{s}", .{failure.message});
            return;
        }
        self.data = parsed;
        self.data_name = std.fs.path.basename(picked);
        self.session.setStatus(false, "Runner data: {d} rows, {d} columns.", .{ parsed.count(), parsed.columns.len });
        self.session.touch();
    }

    pub fn clearData(self: *Runner) void {
        self.data = .{};
        self.data_name = "";
        self.session.touch();
    }

    pub fn run(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) return;
        if (self.selected() == 0) return self.session.failNow("Tick at least one request to run.");
        // A fresh plan: the document may have changed since the page opened.
        if (self.session.nodeAt(pathOf(self.root))) |node| {
            const steps = runner_mod.collect(self.arena.allocator(), node.*, self.root) catch return self.session.failNow("Not enough memory to plan this run.");
            var i: usize = 0;
            while (i < steps.len and i < self.plan.items.len) : (i += 1) steps[i].enabled = self.plan.items[i].enabled;
            self.plan.clearRetainingCapacity();
            for (steps) |step| self.plan.append(self.session.gpa, step) catch break;
        }
        self.row_count = 0;
        self.ok = 0;
        self.failed = 0;
        self.done = 0;
        self.total_ms = 0;
        self.at = 0;
        self.iteration = 0;
        self.iterations = runner_mod.iterationsFor(self.data.count(), self.iterations);
        self.phase = .running;
        self.next_at_ns = 0;
        self.pump.set(true);
        self.session.setStatus(false, "Runner: starting {d} requests.", .{self.selected() * self.iterations});
        self.session.touch();
        self.tick();
    }

    pub fn stop(self: *Runner) void {
        if (self.phase != .running) return;
        self.phase = .stopping;
        self.session.setStatus(false, "Runner: stopping after the request in flight.", .{});
        self.session.touch();
    }

    // ---- the run, one request at a time -----------------------------------------------------------------

    // Called once per frame: collect the answer that landed, or start the next request.
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
        if (self.at >= self.plan.items.len) {
            self.iteration += 1;
            self.at = 0;
            if (self.iteration >= self.iterations) return self.finishRun(.finished);
        }
        // The delay is spent between requests, never before the first one.
        if (self.delay_ms > 0 and self.next_at_ns != 0 and nowNs(self.session.io) < self.next_at_ns) return;
        self.begin();
    }

    fn begin(self: *Runner) void {
        const step = self.plan.items[self.at];
        if (!step.enabled) {
            self.at += 1;
            self.tick();
            return;
        }
        const path = pathOf(step.path);
        const node = self.session.nodeAt(path) orelse return self.failStep(step, "this request is gone");
        const collection_path = Path{ .depth = 1, .segments = splatOf(step.path.segments[0]) };
        const collection = self.session.nodeAt(collection_path) orelse return self.failStep(step, "its collection is gone");
        const arena = self.arena.allocator();
        const data_pairs = data_file.pairs(arena, self.data, self.iteration) catch &.{};
        const scope = run_collection.scopeFor(arena, node.*, collection.*, self.env.activeVars(), data_pairs);
        const host = script_mod.Host{ .ctx = self.env, .get_fn = scriptGet, .set_fn = scriptSet };

        const pre = postman.scriptOf(node.*, .pre);
        if (pre.len > 0) {
            const outcome = script_mod.run(arena, pre, null, host);
            if (outcome.failure) |failure| return self.failStep(step, script_mod.describe(arena, failure));
        }

        const gpa = self.session.gpa;
        const job = request_job.Job.create(gpa, self.session.io) catch return self.failStep(step, "could not start the request");
        const wire = send_request.build(job.arena(), node.*, .{
            .boundary = "kurir-runner",
            .scope = scope,
        }) catch |err| {
            job.destroy(gpa);
            return self.failStep(step, switch (err) {
                error.NoUrl => "this request has no URL",
                error.NotARequest => "this node is not a request",
                error.OutOfMemory => "not enough memory to expand this request",
            });
        };
        job.request = .{ .method = wire.method, .url = wire.url, .headers = wire.headers, .body = wire.body };
        job.start(self.transport(job.arena()));
        self.job = .{ .job = job, .step = step, .iteration = self.iteration };
        self.pump.set(true);
        self.session.setStatus(false, "Runner: {s} {s}…", .{ step.method, step.name });
        self.session.touch();
    }

    fn transport(self: *Runner, arena: Allocator) http_mod.Transport {
        const build = self.transport_fn orelse return .{ .ctx = null, .arena = arena, .send_fn = http_mod.sendOffline };
        return build(self.transport_ctx, arena);
    }

    // A step that never left the app: it still gets a row, so the table says why.
    fn failStep(self: *Runner, step: runner_mod.Step, reason: []const u8) void {
        self.pushRow(.{
            .iteration = self.iteration + 1,
            .name = step.name,
            .method = step.method,
            .ok = false,
            .failure = runner_mod.failureLabel(.request),
        }, reason);
        self.advance();
    }

    fn finish(self: *Runner, pending: Pending, result: http_mod.Result) void {
        const arena = self.arena.allocator();
        var tests: []const script_mod.Test = &.{};
        var post_failed = false;
        var error_text: []const u8 = "";
        const path = pathOf(pending.step.path);
        if (self.session.nodeAt(path)) |node| {
            const post = postman.scriptOf(node.*, .post);
            if (post.len > 0) {
                const headers = headersOf(arena, result) catch &.{};
                const answer = script_mod.Response{ .status = result.status, .headers = headers, .body = result.body };
                const outcome = script_mod.run(arena, post, answer, .{ .ctx = self.env, .get_fn = scriptGet, .set_fn = scriptSet });
                tests = outcome.tests;
                if (outcome.failure) |failure| {
                    post_failed = true;
                    error_text = script_mod.describe(arena, failure);
                }
            }
        }
        if (result.failed) error_text = if (result.error_message.len > 0) result.error_message else result.error_title;
        const verdict = runner_mod.verdict(result, post_failed, tests);
        var passed: usize = 0;
        for (tests) |one| {
            if (one.passed) passed += 1;
        }
        self.pushRow(.{
            .iteration = pending.iteration + 1,
            .name = pending.step.name,
            .method = pending.step.method,
            .status = result.status,
            .time_ms = result.time_ms,
            .ok = verdict.ok,
            .failure = runner_mod.failureLabel(verdict.failure),
            .tests_passed = passed,
            .tests_total = tests.len,
        }, error_text);
    }

    fn pushRow(self: *Runner, row: state_mod.RunnerRow, error_text: []const u8) void {
        if (self.row_count < state_mod.max_runner_rows) {
            self.rows[self.row_count] = row;
            self.row_count += 1;
        }
        self.done += 1;
        self.total_ms += row.time_ms;
        if (row.ok) self.ok += 1 else self.failed += 1;
        if (error_text.len > 0) self.session.setStatus(true, "Runner: {s} — {s}", .{ row.name, error_text }) else self.session.setStatus(!row.ok, "Runner: {s} {s}.", .{ row.name, row.failure });
        self.session.touch();
    }

    fn advance(self: *Runner) void {
        self.at += 1;
        if (self.at < self.plan.items.len) {
            self.next_at_ns = if (self.delay_ms > 0) nowNs(self.session.io) + @as(i96, self.delay_ms) * 1_000_000 else 0;
            return;
        }
        self.at = 0;
        self.iteration += 1;
        self.next_at_ns = if (self.delay_ms > 0) nowNs(self.session.io) + @as(i96, self.delay_ms) * 1_000_000 else 0;
        if (self.iteration >= self.iterations) return self.finishRun(.finished);
    }

    fn finishRun(self: *Runner, phase: state_mod.RunnerPhase) void {
        self.phase = phase;
        self.pump.set(false);
        self.job = null;
        self.session.setStatus(phase == .stopped, "Runner {s}: {d} requests, {d} ok, {d} failed.", .{
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
        u.runner_collection = self.collection_name;
        u.runner_iterations = self.iterations_text[0..self.iterations_len];
        u.runner_delay = self.delay_text[0..self.delay_len];
        u.runner_env = self.env.activeName() orelse "No environment";
        u.runner_data = if (self.data_name.len > 0) self.data_name else "None";
        u.runner_selected = self.selected();
        u.runner_total = self.plan.items.len;
        u.runner_done = self.done;
        u.runner_ok = self.ok;
        u.runner_failed = self.failed;
        u.runner_ms = self.total_ms;
        u.runner_note = self.note[0..self.note_len];

        const steps: []state_mod.RunnerStep = arena.alloc(state_mod.RunnerStep, self.plan.items.len) catch &.{};
        for (self.plan.items, 0..) |step, index| {
            steps[index] = .{ .name = step.name, .method = step.method, .enabled = step.enabled };
        }
        u.runner_steps = steps;

        const rows: []state_mod.RunnerRow = arena.alloc(state_mod.RunnerRow, self.row_count) catch &.{};
        @memcpy(rows, self.rows[0..self.row_count]);
        u.runner_rows = rows;
    }
};

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

// A path's address inside the document, which is what the domain plan walks with.
pub fn addressOf(path: Path) runner_mod.Address {
    var address = runner_mod.Address{};
    address.depth = path.depth;
    for (path.segments[0..path.depth], 0..) |segment, index| {
        if (index < runner_mod.max_depth) address.segments[index] = segment;
    }
    return address;
}

// And back: the address the plan carries becomes the Path the session resolves.
pub fn pathOf(address: runner_mod.Address) Path {
    var path = Path{};
    path.depth = address.depth;
    for (address.segments[0..address.depth], 0..) |segment, index| {
        if (index < state_mod.max_depth) path.segments[index] = segment;
    }
    return path;
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

test "an address and a path are the same shape, both ways" {
    const path = Path.empty.child(2).child(5).child(1);
    const address = addressOf(path);
    try testing.expectEqual(@as(usize, 3), address.depth);
    try testing.expectEqual(@as(u16, 5), address.segments[1]);
    const back = pathOf(address);
    try testing.expect(Path.eql(path, back));
}

test "a typed number keeps its digits, and an empty one keeps what was there" {
    var buffer: [8]u8 = @splat('1');
    const length = copyNumber(&buffer, "1a2x3", buffer[0..1]);
    try testing.expectEqualStrings("123", buffer[0..length]);
    const kept = copyNumber(&buffer, "", buffer[0..length]);
    try testing.expectEqualStrings("123", buffer[0..kept]);
}
