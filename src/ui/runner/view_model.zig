//! The runner page's model: a Playwright spec, the tests it lists, and the rows one run produced.
const std = @import("std");
const glinlandui = @import("glinlandui");

const postman = @import("../../data/model/postman.zig");
const pw_run = @import("../../data/local/pw_run.zig");
const env_mod = @import("../../domain/env.zig");
const spec_mod = @import("../../domain/spec.zig");

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
pub const send_id = "kurir.runner.add.send";
pub const test_id = "kurir.runner.add.test";
pub const code_id = "kurir.runner.code";
pub const spec_field_id = "kurir.runner.spec";

// How much code the page holds: a spec is a screen or two, not a bundle.
pub const flow_cap: usize = 64 * 1024;

// The variable an environment uses to say what the spec's relative URLs are relative TO.
const base_url_names = [_][]const u8{ "baseUrl", "base_url", "baseURL" };

pub const Runner = struct {
    session: *Session = undefined,
    env: *Env = undefined,
    pump: *pump_mod.Pump = undefined,
    // Where Playwright may live, in the order they are tried (a project root, not node_modules).
    roots: []const []const u8 = &.{},
    // The process environment, so the child keeps PATH and gains the active environment's variables.
    environ: ?*const std.process.Environ.Map = null,

    open: bool = false,
    phase: state_mod.RunnerPhase = .idle,
    started: bool = false,
    // The tests and the rows' own text live here, and it is reset whenever the spec or a run changes.
    arena: std.heap.ArenaAllocator = undefined,
    // Where Playwright was found: kept apart, because a re-parse of the spec must not free these paths.
    install_arena: std.heap.ArenaAllocator = undefined,
    // The spec text of the bound runner: the document is the source, this is its buffer for the frame.
    flow_buf: [flow_cap]u8 = undefined,
    flow_len: usize = 0,
    flow_path: ?Path = null,
    loading: bool = false,
    // FLOW: the tests the spec declares, or the spec itself when the page is showing its code.
    tests: []spec_mod.Test = &.{},
    code_open: bool = false,
    // Where Playwright lives, once looked for, and the one line the page says about it.
    install: ?pw_run.Install = null,
    install_checked: bool = false,
    engine_buf: [512]u8 = undefined,
    engine_len: usize = 0,

    rows: [state_mod.max_runner_rows]state_mod.RunnerRow = undefined,
    row_count: usize = 0,
    ok: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    total_ms: u64 = 0,
    job: ?*pw_run.Job = null,
    // Which row a box's children callback is drawing, and which cell of it (the callback gets only the scope).
    draw_row: usize = 0,
    draw_cell: usize = 0,

    pub fn start(self: *Runner, session: *Session, env: *Env, pump: *pump_mod.Pump) void {
        self.session = session;
        self.env = env;
        self.pump = pump;
        self.arena = .init(session.gpa);
        self.install_arena = .init(session.gpa);
        self.rows = undefined;
        self.flow_len = 0;
        self.started = true;
    }

    pub fn deinit(self: *Runner) void {
        if (!self.started) return;
        if (self.job) |job| job.destroy();
        self.job = null;
        self.arena.deinit();
        self.install_arena.deinit();
        // The roots were built for this run of the app, so it gives them back.
        if (self.roots.len > 0) {
            for (self.roots) |root| self.session.gpa.free(root);
            self.session.gpa.free(self.roots);
        }
        self.roots = &.{};
        self.started = false;
    }

    // ---- the spec ---------------------------------------------------------------------------------------

    // A saved runner, opened from its row: the document is the source of the spec, and of its tests.
    pub fn openFlow(self: *Runner, path: Path) void {
        const node = self.session.nodeAt(path) orelse return;
        if (!postman.isFlow(node.*)) return;
        if (self.phase == .running or self.phase == .stopping) return self.session.failNow("This runner is still running. Stop it before opening another one.");
        self.flow_path = path;
        self.open = true;
        self.phase = .idle;
        self.code_open = false;
        self.reset();
        self.pump.set(false);
        self.loading = true;
        self.setFlow(postman.flowOf(node.*));
        self.loading = false;
        self.ensureInstall();
        self.session.setStatus(false, "Runner {s}: {d} tests.", .{ Session.name(node.*), self.tests.len });
        self.session.touch();
    }

    // The spec IS the source: re-read it and the listed tests follow, then write it back into its item.
    pub fn setFlow(self: *Runner, text: []const u8) void {
        const length = @min(text.len, flow_cap);
        @memcpy(self.flow_buf[0..length], text[0..length]);
        self.flow_len = length;
        self.reparse();
        if (!self.loading) self.persistFlow();
    }

    pub fn source(self: *const Runner) []const u8 {
        return self.flow_buf[0..self.flow_len];
    }

    // The spec goes back into the item it came from, marked unsaved like any other edit.
    fn persistFlow(self: *Runner) void {
        const path = self.flow_path orelse return;
        const node = self.session.nodeAt(path) orelse return;
        postman.setFlowSource(self.session.docArena(), node, self.source()) catch return;
        self.session.markDirty(path);
        self.session.touch();
    }

    fn reparse(self: *Runner) void {
        _ = self.arena.reset(.retain_capacity);
        self.tests = spec_mod.parse(self.arena.allocator(), self.source()) catch &.{};
        self.session.touch();
    }

    // Our own text with a block appended, which is what a button on the page does.
    fn appendText(self: *Runner, block: []const u8) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.session.gpa);
        text.appendSlice(self.session.gpa, self.source()) catch return;
        if (text.items.len > 0 and text.items[text.items.len - 1] != '\n') text.append(self.session.gpa, '\n') catch return;
        if (text.items.len > 0) text.append(self.session.gpa, '\n') catch return;
        text.appendSlice(self.session.gpa, block) catch return;
        self.setFlow(text.items);
    }

    // A request chosen in the tree becomes one more test at the end of the spec.
    pub fn addSend(self: *Runner) void {
        const node = self.session.selectedNode() orelse return self.session.failNow("Select a request in the tree first.");
        if (!postman.isRequest(node.*)) return self.session.failNow("Select a request, not a folder or a runner.");
        const request = node.object.get("request") orelse return self.session.failNow("That row is not a request.");
        const block = spec_mod.requestTest(self.session.gpa, Session.name(node.*), postman.str(request, "method"), postman.urlRaw(request)) catch
            return self.session.failNow("Not enough memory to add a test.");
        defer self.session.gpa.free(block);
        self.appendText(block);
        self.session.setStatus(false, "Added a test for {s}.", .{Session.name(node.*)});
    }

    // An empty test to fill in: the button that says "write it yourself".
    pub fn addTest(self: *Runner) void {
        self.appendText(
            \\test('a new test', async ({ request }) => {
            \\  const r = await request.get('/');
            \\  expect(r.ok()).toBeTruthy();
            \\});
            \\
        );
        self.session.setStatus(false, "Added a test. Open Code to write it.", .{});
    }

    // FLOW is a list of tests by name; Code is the spec itself.
    pub fn toggleCode(self: *Runner) void {
        self.code_open = !self.code_open;
        self.session.touch();
    }

    // A keystroke in the spec editor: the document holds the code, so every edit is a document edit.
    pub fn onSpecTyped(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.setFlow(text);
    }

    // The tests a row seeds: its requests, each as its own test, so a collection becomes a spec in one click.
    pub fn seedFrom(self: *Runner, arena: Allocator, path: Path) []const u8 {
        const node = self.session.nodeAt(path) orelse return "";
        var text: std.ArrayList(u8) = .empty;
        var walker = Seeder{ .arena = arena, .text = &text };
        walker.walk(node.*, 0);
        return text.items;
    }

    const Seeder = struct {
        arena: Allocator,
        text: *std.ArrayList(u8),

        fn walk(self: *Seeder, node: postman.Value, depth: usize) void {
            if (postman.isRequest(node)) {
                const request = node.object.get("request") orelse return;
                const block = spec_mod.requestTest(self.arena, postman.str(node, "name"), postman.str(request, "method"), postman.urlRaw(request)) catch return;
                self.text.appendSlice(self.arena, block) catch return;
                self.text.append(self.arena, '\n') catch return;
                return;
            }
            // A folder is walked by the same rule; a tree deeper than this is not a page's worth of tests.
            if (depth > 6) return;
            var index: usize = 0;
            const count = postman.itemCount(node);
            while (index < count) : (index += 1) {
                const item = postman.itemAt(node, index) orelse continue;
                self.walk(item, depth + 1);
            }
        }
    };

    // ---- the run ----------------------------------------------------------------------------------------

    // Where Playwright is, once: the first root that holds it, or the sentence that says it is missing.
    fn ensureInstall(self: *Runner) void {
        if (self.install_checked) return;
        self.install_checked = true;
        // The paths outlive a re-parse of the spec, so they get an arena of their own.
        self.install = pw_run.locate(self.install_arena.allocator(), self.session.io, self.roots) catch null;
        const text = if (self.install) |install|
            std.fmt.bufPrint(&self.engine_buf, "playwright: {s}", .{install.root}) catch ""
        else
            std.fmt.bufPrint(&self.engine_buf, "Playwright is not installed: npm i -D @playwright/test in {s}", .{if (self.roots.len > 0) self.roots[0] else "(no runner folder)"}) catch "";
        self.engine_len = text.len;
    }

    pub fn engine(self: *const Runner) []const u8 {
        return self.engine_buf[0..self.engine_len];
    }

    pub fn run(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) return;
        self.ensureInstall();
        if (self.install == null) return self.session.fail("Playwright is not installed: the runner cannot start. {s}", .{self.engine()});
        if (self.tests.len == 0) return self.session.failNow("This runner has no tests yet. Press + Send for a request, or + Test, then Run.");
        const install = self.install.?;

        const gpa = self.session.gpa;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const prepared = pw_run.writeRun(arena, self.session.io, install, self.source(), self.baseUrl()) catch |err|
            return self.session.fail("The runner's folder could not be written ({s}).", .{@errorName(err)});

        const job = pw_run.Job.create(gpa, self.session.io) catch
            return self.session.failNow("Not enough memory to start the runner.");
        var vars: std.ArrayList(pw_run.Pair) = .empty;
        defer vars.deinit(gpa);
        for (self.env.activeVars()) |variable| {
            const value = env_mod.value(variable);
            if (variable.name.len == 0) continue;
            vars.append(gpa, .{ .name = variable.name, .value = value }) catch break;
        }
        self.reset();
        self.phase = .running;
        job.start(prepared, self.environ, vars.items);
        self.job = job;
        self.pump.set(true);
        self.session.setStatus(false, "Runner: {d} tests, {s}.", .{ self.tests.len, self.engine() });
        self.session.touch();
    }

    // The base URL a spec's relative requests resolve against: the active environment's `baseUrl`, when it has one.
    fn baseUrl(self: *Runner) []const u8 {
        for (self.env.activeVars()) |variable| {
            for (base_url_names) |name| {
                if (!std.ascii.eqlIgnoreCase(variable.name, name)) continue;
                const value = env_mod.value(variable);
                if (value.len > 0) return value;
            }
        }
        return "";
    }

    pub fn stop(self: *Runner) void {
        if (self.phase != .running) return;
        self.phase = .stopping;
        if (self.job) |job| job.stop();
        self.session.setStatus(false, "Runner: stopping.", .{});
        self.session.touch();
    }

    // Called once per frame: the run lands here, and the page reads its rows.
    pub fn tick(self: *Runner) void {
        if (self.phase != .running and self.phase != .stopping) return;
        const job = self.job orelse return;
        if (!job.poll()) return;
        // The rows are copied out FIRST: the report lives in the job's arena, and destroying it frees them.
        const report = job.take();
        self.apply(report);
        job.destroy();
        self.job = null;
    }

    // The report becomes the table: one row a test, and the summary the page prints under it.
    fn apply(self: *Runner, report: pw_run.Report) void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        // The listed tests live in this arena too, so they are read again from the spec that produced them.
        self.tests = spec_mod.parse(arena, self.source()) catch &.{};
        self.row_count = 0;
        for (report.rows) |row| {
            if (self.row_count >= state_mod.max_runner_rows) break;
            const label = if (row.skipped) "skipped" else if (row.ok) "ok" else "failed";
            self.rows[self.row_count] = .{
                .name = arena.dupe(u8, row.name) catch row.name,
                .ok = row.ok,
                .skipped = row.skipped,
                .time_ms = row.duration_ms,
                .label = label,
                .detail = arena.dupe(u8, row.error_text) catch row.error_text,
            };
            self.row_count += 1;
            self.total_ms += row.duration_ms;
            if (row.skipped) self.skipped += 1 else if (row.ok) self.ok += 1 else self.failed += 1;
        }
        self.phase = if (report.stopped) .stopped else .finished;
        self.pump.set(false);
        if (report.failure.len > 0) {
            self.session.setStatus(true, "Runner: {s}", .{report.failure});
        } else if (report.stopped) {
            self.session.setStatus(false, "Runner stopped: {d} tests ran.", .{self.row_count});
        } else {
            self.session.setStatus(self.failed > 0, "Runner {s}: {d} passed, {d} failed, {d} skipped, {d} ms.", .{
                if (self.failed > 0) "finished with failures" else "finished",
                self.ok,
                self.failed,
                self.skipped,
                self.total_ms,
            });
        }
        self.session.touch();
    }

    pub fn close(self: *Runner) void {
        if (self.phase == .running or self.phase == .stopping) self.stop();
        self.open = false;
        self.code_open = false;
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
        self.skipped = 0;
        self.total_ms = 0;
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
        u.runner_flow = self.source();
        u.runner_code_open = self.code_open;
        u.runner_engine = self.engine();
        u.runner_error = "";

        const tests: []state_mod.RunnerTest = arena.alloc(state_mod.RunnerTest, self.tests.len) catch &.{};
        for (self.tests, tests) |one, *row| row.* = .{ .name = one.name, .line = one.line };
        u.runner_tests = tests;

        u.runner_iterations = "1";
        u.runner_delay = "0";
        u.runner_env = self.env.activeName() orelse "No environment";
        u.runner_data = "None";
        u.runner_selected = self.tests.len;
        u.runner_total = self.tests.len;
        u.runner_done = self.row_count;
        u.runner_ok = self.ok;
        u.runner_failed = self.failed;
        u.runner_skipped = self.skipped;
        u.runner_ms = self.total_ms;
        u.runner_note = "";
        u.runner_steps = &.{};

        const rows: []state_mod.RunnerRow = arena.alloc(state_mod.RunnerRow, self.row_count) catch &.{};
        @memcpy(rows, self.rows[0..self.row_count]);
        u.runner_rows = rows;
    }
};
