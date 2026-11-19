//! The Playwright runner: find the library, write the spec and its config, run it, and read its JSON report.
const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;

// One test of the report, as the table draws it.
pub const Row = struct {
    name: []const u8 = "",
    line: usize = 1,
    ok: bool = false,
    skipped: bool = false,
    duration_ms: u64 = 0,
    // The first line of the failure, with the colour codes Playwright's expect() leaves in it removed.
    error_text: []const u8 = "",
};

pub const Report = struct {
    rows: []const Row = &.{},
    expected: usize = 0,
    unexpected: usize = 0,
    duration_ms: u64 = 0,
    // Set when the run could not start, or Playwright wrote no report: the page says it instead of guessing.
    failure: []const u8 = "",
    stopped: bool = false,
};

// A Playwright project on this machine: its root, and the CLI inside it that runs a test file.
pub const Install = struct {
    root: []const u8,
    cli: []const u8,
};

// Where the spec and its config go for one run: under the install, so `@playwright/test` resolves from the parent.
pub const Run = struct {
    dir: []const u8,
    spec: []const u8,
    config: []const u8,
    report: []const u8,
    // The CLI inside the install that runs this spec.
    cli: []const u8 = "",
};

// One variable the active environment hands the spec as `process.env.<name>`.
pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

// The first candidate that really holds Playwright, with the CLI path inside it. A candidate is a project root.
pub fn locate(arena: Allocator, io: std.Io, candidates: []const []const u8) Allocator.Error!?Install {
    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        // Absolute, because the child runs in a folder UNDER this root: a relative one would resolve twice.
        const root = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, arena) catch continue;
        const cli = try std.fs.path.join(arena, &.{ root, "node_modules", "@playwright", "test", "cli.js" });
        std.Io.Dir.cwd().access(io, cli, .{}) catch continue;
        return .{ .root = root, .cli = cli };
    }
    return null;
}

// Write the spec and the config that runs it into `<install>/.kurir`, where the import resolves.
pub fn writeRun(arena: Allocator, io: std.Io, install: Install, source: []const u8, base_url: []const u8) !Run {
    const dir = try std.fs.path.join(arena, &.{ install.root, ".kurir" });
    const tests = try std.fs.path.join(arena, &.{ dir, "tests" });
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, tests) catch |err| return err;
    const spec = try std.fs.path.join(arena, &.{ tests, "runner.spec.ts" });
    const config = try std.fs.path.join(arena, &.{ dir, "playwright.config.ts" });
    const report = try std.fs.path.join(arena, &.{ dir, "report.json" });
    cwd.writeFile(io, .{ .sub_path = spec, .data = source }) catch |err| return err;
    const text = try configText(arena, base_url);
    cwd.writeFile(io, .{ .sub_path = config, .data = text }) catch |err| return err;
    // A report from the previous run is never this run's answer, so it goes before the child starts.
    cwd.deleteFile(io, report) catch {};
    return .{ .dir = dir, .spec = spec, .config = config, .report = report, .cli = install.cli };
}

// The config one run uses: one worker, no parallelism, the JSON report, and the environment's base URL.
pub fn configText(arena: Allocator, base_url: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\import { defineConfig } from '@playwright/test';
        \\
        \\export default defineConfig({
        \\  testDir: './tests',
        \\  workers: 1,
        \\  fullyParallel: false,
        \\  timeout: 30_000,
        \\  reporter: [['json', { outputFile: 'report.json' }]],
        \\  use: {
        \\    baseURL: '
    );
    try quoted(arena, &out, base_url);
    try out.appendSlice(arena,
        \\',
        \\  },
        \\});
        \\
    );
    return out.items;
}

// Text inside a single-quoted JavaScript string.
fn quoted(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| {
        if (byte == '\'' or byte == '\\') try out.append(arena, '\\');
        try out.append(arena, if (byte == '\n' or byte == '\r') ' ' else byte);
    }
}

// ---- the report Playwright wrote ------------------------------------------------------------------------------

// The rows of one report: every spec of every suite, in file order, and the totals Playwright already counted.
pub fn parseReport(arena: Allocator, json_text: []const u8) Allocator.Error!Report {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json_text, .{}) catch return .{
        .failure = "the report Playwright wrote could not be read",
    };
    if (parsed.value != .object) return .{ .failure = "the report Playwright wrote is not an object" };
    var report = Report{};
    if (parsed.value.object.get("stats")) |stats| {
        if (stats == .object) {
            report.expected = intOf(stats.object.get("expected"));
            report.unexpected = intOf(stats.object.get("unexpected"));
            report.duration_ms = intOf(stats.object.get("duration"));
        }
    }
    var rows: std.ArrayList(Row) = .empty;
    if (parsed.value.object.get("suites")) |suites| try walkSuites(arena, suites, &rows);
    report.rows = rows.items;
    return report;
}

fn walkSuites(arena: Allocator, suites: std.json.Value, rows: *std.ArrayList(Row)) Allocator.Error!void {
    if (suites != .array) return;
    for (suites.array.items) |suite| {
        if (suite != .object) continue;
        if (suite.object.get("specs")) |specs| {
            if (specs == .array) {
                for (specs.array.items) |spec| try appendSpec(arena, spec, rows);
            }
        }
        if (suite.object.get("suites")) |inner| try walkSuites(arena, inner, rows);
    }
}

fn appendSpec(arena: Allocator, spec: std.json.Value, rows: *std.ArrayList(Row)) Allocator.Error!void {
    if (spec != .object) return;
    var row = Row{
        .name = try arena.dupe(u8, strOf(spec.object.get("title"))),
        .line = intOf(spec.object.get("line")),
    };
    if (spec.object.get("ok")) |ok| {
        if (ok == .bool) row.ok = ok.bool;
    }
    // The first test of a spec is the one this run executed; its first result is that run.
    if (spec.object.get("tests")) |tests| {
        if (tests == .array and tests.array.items.len > 0) {
            const one = tests.array.items[0];
            if (one == .object) {
                if (one.object.get("results")) |results| {
                    if (results == .array and results.array.items.len > 0) {
                        const result = results.array.items[0];
                        if (result == .object) {
                            row.duration_ms = intOf(result.object.get("duration"));
                            const status = strOf(result.object.get("status"));
                            row.skipped = std.mem.eql(u8, status, "skipped");
                            if (result.object.get("error")) |failure| {
                                if (failure == .object) {
                                    row.error_text = try cleanError(arena, strOf(failure.object.get("message")));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    try rows.append(arena, row);
}

fn strOf(value: ?std.json.Value) []const u8 {
    const found = value orelse return "";
    return if (found == .string) found.string else "";
}

fn intOf(value: ?std.json.Value) u64 {
    const found = value orelse return 0;
    if (found == .integer and found.integer >= 0) return @intCast(found.integer);
    // Playwright writes `stats.duration` as a float, and a report's own rows as integers.
    if (found == .float and found.float >= 0) return @intFromFloat(@round(found.float));
    return 0;
}

// A failure message a row can show: the colour codes gone, and the first line that says something.
fn cleanError(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '[') {
            index += 2;
            while (index < raw.len and raw[index] != 'm') : (index += 1) {}
            continue;
        }
        try plain.append(arena, raw[index]);
    }
    var lines = std.mem.splitScalar(u8, plain.items, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        return arena.dupe(u8, text);
    }
    return "";
}

// ---- one run, off the frame thread ----------------------------------------------------------------------------

// A Playwright process in flight: the frame polls it, and Stop kills the whole tree by pid.
pub const Job = struct {
    gpa: Allocator,
    io: std.Io,
    // The report and this job's own strings live here, and it is freed on destroy.
    arena_state: std.heap.ArenaAllocator,
    child_id: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    stop_requested: std.atomic.Value(bool) = .init(false),
    report: Report = .{},
    future: ?std.Io.Future(void) = null,

    pub fn create(gpa: Allocator, io: std.Io) !*Job {
        const job = try gpa.create(Job);
        job.* = .{ .gpa = gpa, .io = io, .arena_state = std.heap.ArenaAllocator.init(gpa) };
        return job;
    }

    // Hand the run to the pool. The frame keeps its own document; everything else is copied into the job's arena.
    pub fn start(self: *Job, run: Run, parent_env: ?*const std.process.Environ.Map, vars: []const Pair) void {
        const arena = self.arena_state.allocator();
        const argv = arena.alloc([]const u8, 5) catch return self.die("not enough memory to start the runner");
        argv[0] = "node";
        argv[1] = arena.dupe(u8, run.cli) catch return self.die("not enough memory to start the runner");
        argv[2] = "test";
        argv[3] = "--config";
        argv[4] = arena.dupe(u8, run.config) catch return self.die("not enough memory to start the runner");
        const copy = arena.alloc(Pair, vars.len) catch return self.die("not enough memory to start the runner");
        for (vars, copy) |pair, *slot| {
            slot.* = .{
                .name = arena.dupe(u8, pair.name) catch "",
                .value = arena.dupe(u8, pair.value) catch "",
            };
        }
        const request = Request{
            .argv = argv,
            .dir = arena.dupe(u8, run.dir) catch return self.die("not enough memory to start the runner"),
            .report = arena.dupe(u8, run.report) catch return self.die("not enough memory to start the runner"),
            .env = parent_env,
            .vars = copy,
        };
        self.future = std.Io.concurrent(self.io, work, .{ self, request }) catch null;
        if (self.future == null) work(self, request);
    }

    // Safe from the frame: an acquire load, no lock and no waiting.
    pub fn poll(self: *Job) bool {
        return self.finished.load(.acquire);
    }

    pub fn take(self: *Job) Report {
        return self.report;
    }

    // Stop the run: the pid is copied at spawn, so the frame kills the tree without touching the Child struct.
    pub fn stop(self: *Job) void {
        if (self.finished.load(.acquire)) return;
        self.stop_requested.store(true, .release);
        const id = self.child_id.load(.acquire);
        if (id == 0) return;
        killTree(self.gpa, self.io, id);
    }

    // Joins the run before freeing it, so a quit during a run cannot free the arena under the child.
    pub fn destroy(self: *Job) void {
        if (self.future) |*future| _ = future.await(self.io);
        self.future = null;
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    fn die(self: *Job, reason: []const u8) void {
        self.report = .{ .failure = reason };
        self.finished.store(true, .release);
    }
};

const Request = struct {
    argv: []const []const u8,
    dir: []const u8,
    report: []const u8,
    // Null only in a harness that never starts a child; a real app always has the process environment.
    env: ?*const std.process.Environ.Map,
    vars: []const Pair,
};

fn work(job: *Job, request: Request) void {
    job.report = runOnce(job.arena_state.allocator(), job.io, request, job);
    job.report.stopped = job.stop_requested.load(.acquire);
    job.finished.store(true, .release);
}

// One run, to the end: the worker thread of a page and a blocking CLI share this.
fn runOnce(arena: Allocator, io: std.Io, request: Request, sink: ?*Job) Report {
    var env = std.process.Environ.Map.init(arena);
    if (request.env) |parent| {
        var entries = parent.iterator();
        while (entries.next()) |entry| env.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }
    for (request.vars) |pair| env.put(pair.name, pair.value) catch {};

    // What the child said, kept in the run folder: a run that produces no report has a reason, and it is in here.
    const log_path = std.fs.path.join(arena, &.{ request.dir, "run.log" }) catch "run.log";
    const log = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
    defer if (log) |file| file.close(io);
    const out: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .ignore;

    var child = std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = .{ .path = request.dir },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = out,
        .stderr = out,
        .create_no_window = true,
    }) catch |err| {
        const reason = std.fmt.allocPrint(arena, "node could not run Playwright ({s})", .{@errorName(err)}) catch "node could not run Playwright";
        return .{ .failure = reason };
    };
    // The pid goes down before the wait, so Stop can kill the tree from the frame thread.
    if (sink) |job| job.child_id.store(idOf(child), .release);
    _ = child.wait(io) catch {};

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, request.report, arena, .limited(32 * 1024 * 1024)) catch {
        const said = std.Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(8 * 1024)) catch "";
        const said_text = std.mem.trim(u8, said, " \t\r\n");
        if (said_text.len == 0) return .{ .failure = "Playwright wrote no report: the run could not start" };
        const reason = std.fmt.allocPrint(arena, "Playwright wrote no report: {s}", .{said_text}) catch "Playwright wrote no report";
        return .{ .failure = reason };
    };
    return parseReport(arena, bytes) catch Report{ .failure = "the report Playwright wrote could not be read" };
}

// A whole run, blocking: `kurirw run --runner NAME` has no frame to return to.
pub fn runNow(
    arena: Allocator,
    io: std.Io,
    install: Install,
    source: []const u8,
    base_url: []const u8,
    parent_env: ?*const std.process.Environ.Map,
    vars: []const Pair,
) Report {
    const run = writeRun(arena, io, install, source, base_url) catch |err| {
        const reason = std.fmt.allocPrint(arena, "the runner's folder could not be written ({s})", .{@errorName(err)}) catch "the runner's folder could not be written";
        return .{ .failure = reason };
    };
    const argv = arena.alloc([]const u8, 5) catch return .{ .failure = "not enough memory to start the runner" };
    argv[0] = "node";
    argv[1] = run.cli;
    argv[2] = "test";
    argv[3] = "--config";
    argv[4] = run.config;
    return runOnce(arena, io, .{ .argv = argv, .dir = run.dir, .report = run.report, .env = parent_env, .vars = vars }, null);
}

// The report as JSON, for a build that runs a runner from the command line.
pub fn reportJson(arena: Allocator, name: []const u8, report: Report) ![]u8 {
    const postman = @import("../model/postman.zig");
    var root: postman.Object = .empty;
    try root.put(arena, "format", .{ .string = "kurir/runner-report@1" });
    try root.put(arena, "runner", .{ .string = name });
    try root.put(arena, "stopped", .{ .bool = report.stopped });
    try root.put(arena, "failure", .{ .string = report.failure });

    var summary: postman.Object = .empty;
    try summary.put(arena, "tests", .{ .integer = @intCast(report.rows.len) });
    try summary.put(arena, "passed", .{ .integer = @intCast(report.expected) });
    try summary.put(arena, "failed", .{ .integer = @intCast(report.unexpected) });
    try summary.put(arena, "duration_ms", .{ .integer = @intCast(report.duration_ms) });
    try root.put(arena, "summary", .{ .object = summary });

    var rows: postman.Array = .init(arena);
    for (report.rows) |row| {
        var entry: postman.Object = .empty;
        try entry.put(arena, "name", .{ .string = row.name });
        try entry.put(arena, "line", .{ .integer = @intCast(row.line) });
        try entry.put(arena, "ok", .{ .bool = row.ok });
        try entry.put(arena, "skipped", .{ .bool = row.skipped });
        try entry.put(arena, "time_ms", .{ .integer = @intCast(row.duration_ms) });
        try entry.put(arena, "error", .{ .string = row.error_text });
        try rows.append(.{ .object = entry });
    }
    try root.put(arena, "rows", .{ .array = rows });
    return postman.write(arena, .{ .object = root }, true);
}

fn idOf(child: std.process.Child) u64 {
    const id = child.id orelse return 0;
    return switch (builtin.os.tag) {
        .windows => @intFromPtr(id),
        else => @intCast(id),
    };
}

// Kill the whole tree: Playwright runs its tests in a worker process of its own.
fn killTree(gpa: Allocator, io: std.Io, id: u64) void {
    if (builtin.os.tag == .windows) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = std.fmt.allocPrint(arena, "{d}", .{id}) catch return;
        const argv = [_][]const u8{ "taskkill", "/T", "/F", "/PID", text };
        _ = std.process.run(arena, io, .{ .argv = &argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch {};
        return;
    }
    std.posix.kill(@intCast(id), std.posix.SIG.KILL) catch {};
}

const testing = std.testing;

// A report shaped like Playwright's own, trimmed to what the runner reads.
const sample_report =
    \\{"stats":{"expected":1,"unexpected":1,"duration":2033},
    \\"suites":[{"specs":[
    \\ {"title":"ok answers 200","ok":true,"line":3,"tests":[{"results":[{"status":"passed","duration":47}]}]},
    \\ {"title":"a bad one","ok":false,"line":15,"tests":[{"results":[{"status":"failed","duration":12,
    \\  "error":{"message":"\u001b[31mError: expect(received).toBe(expected)\u001b[39m\n\nExpected: 201\nReceived: 200"}}]}]},
    \\ {"title":"skipped one","ok":true,"line":20,"tests":[{"results":[{"status":"skipped","duration":0}]}]}
    \\]}]}
;

test "a report becomes one row per test, with its duration and its first error line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try parseReport(arena, sample_report);
    try testing.expectEqualStrings("", report.failure);
    try testing.expectEqual(@as(usize, 3), report.rows.len);
    try testing.expectEqual(@as(usize, 1), report.expected);
    try testing.expectEqual(@as(usize, 1), report.unexpected);
    try testing.expectEqual(@as(u64, 2033), report.duration_ms);

    try testing.expectEqualStrings("ok answers 200", report.rows[0].name);
    try testing.expect(report.rows[0].ok);
    try testing.expectEqual(@as(u64, 47), report.rows[0].duration_ms);
    try testing.expectEqual(@as(usize, 3), report.rows[0].line);

    try testing.expect(!report.rows[1].ok);
    // The colour codes are gone, and only the line that says what broke survives.
    try testing.expectEqualStrings("Error: expect(received).toBe(expected)", report.rows[1].error_text);
    try testing.expect(std.mem.indexOfScalar(u8, report.rows[1].error_text, 0x1b) == null);

    try testing.expect(report.rows[2].skipped);
    try testing.expect(report.rows[2].ok);
}

test "a report that is not a report is a sentence, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const broken = try parseReport(arena, "{ not json");
    try testing.expect(broken.failure.len > 0);
    try testing.expectEqual(@as(usize, 0), broken.rows.len);
}

test "the config points Playwright at the tests folder, one worker, and the given base URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try configText(arena, "http://127.0.0.1:8099");
    try testing.expect(std.mem.indexOf(u8, text, "testDir: './tests'") != null);
    try testing.expect(std.mem.indexOf(u8, text, "workers: 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "baseURL: 'http://127.0.0.1:8099'") != null);
    try testing.expect(std.mem.indexOf(u8, text, "report.json") != null);

    // A quote in the URL is escaped, so the config still parses.
    const quoted_text = try configText(arena, "http://x/it's");
    try testing.expect(std.mem.indexOf(u8, quoted_text, "baseURL: 'http://x/it\\'s'") != null);
}
