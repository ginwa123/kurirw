//! One collection run, driven request by request with no window: the CLI runs this directly.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const env_mod = @import("../env.zig");
const runner = @import("../runner.zig");
const script_mod = @import("../script.zig");
const data_file = @import("../data_file.zig");
const send_request = @import("send_request.zig");

pub const Allocator = std.mem.Allocator;

// A writable environment: the CLI's stand-in for the page's Env panel, so a script's `set` still lands somewhere.
pub const Vars = struct {
    arena: Allocator = undefined,
    items: std.ArrayList(env_mod.Variable) = .empty,

    pub fn lookup(self: *const Vars, name: []const u8) ?[]const u8 {
        for (self.items.items) |variable| {
            if (!std.mem.eql(u8, variable.name, name)) continue;
            const value = env_mod.value(variable);
            return if (value.len > 0) value else null;
        }
        return null;
    }

    // A write replaces `current`, which is what `value()` reads first; a new name is appended.
    pub fn set(self: *Vars, name: []const u8, value: []const u8) bool {
        const copy = self.arena.dupe(u8, value) catch return false;
        for (self.items.items) |*variable| {
            if (!std.mem.eql(u8, variable.name, name)) continue;
            variable.current = copy;
            return true;
        }
        const key = self.arena.dupe(u8, name) catch return false;
        self.items.append(self.arena, .{ .name = key, .current = copy }) catch return false;
        return true;
    }

    pub fn slice(self: *const Vars) []const env_mod.Variable {
        return self.items.items;
    }
};

fn scriptGet(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
    const vars: *Vars = @ptrCast(@alignCast(ctx.?));
    return vars.lookup(name);
}

fn scriptSet(ctx: ?*anyopaque, name: []const u8, value: []const u8) bool {
    const vars: *Vars = @ptrCast(@alignCast(ctx.?));
    return vars.set(name, value);
}

// One request's outcome, which is one row of the report and one line of the page's table.
pub const Row = struct {
    iteration: usize = 1,
    name: []const u8 = "",
    method: []const u8 = postman.default_method,
    status: u16 = 0,
    time_ms: u64 = 0,
    url: []const u8 = "",
    ok: bool = false,
    failure: runner.Failure = .none,
    // The one line a person can act on: a script diagnostic, a transport message, or "".
    error_text: []const u8 = "",
    tests: []const script_mod.Test = &.{},
    logs: []const u8 = "",
};

pub const Options = struct {
    io: std.Io,
    // An empty `data` means the iteration count comes from `iterations` alone.
    data: data_file.Data = .{},
    iterations: usize = 1,
    delay_ms: u32 = 0,
    // A caller that wants to stop between requests; checked before each one.
    stop: ?*const fn (?*anyopaque) bool = null,
    stop_ctx: ?*anyopaque = null,
};

pub const Report = struct {
    rows: []const Row = &.{},
    requests: usize = 0,
    ok: usize = 0,
    failed: usize = 0,
    duration_ms: u64 = 0,
    stopped: bool = false,
    // Set when the run could not even be planned; the caller reports it instead of pretending it ran.
    failure: []const u8 = "",
};

// The braces of one request: the data row first, then its own variables, the environment, and the collection's.
pub fn scopeFor(
    arena: Allocator,
    node: postman.Value,
    collection: postman.Value,
    environment: []const env_mod.Variable,
    data_pairs: []const env_mod.Pair,
) env_mod.Scope {
    const own = pairsOf(arena, node);
    var request = own;
    if (data_pairs.len > 0) {
        const merged = arena.alloc(env_mod.Pair, data_pairs.len + own.len) catch return .{
            .request = data_pairs,
            .environment = environment,
            .collection = pairsOf(arena, collection),
        };
        @memcpy(merged[0..data_pairs.len], data_pairs);
        @memcpy(merged[data_pairs.len..], own);
        request = merged;
    }
    return .{
        .request = request,
        .environment = environment,
        .collection = pairsOf(arena, collection),
    };
}

fn pairsOf(arena: Allocator, item: postman.Value) []const env_mod.Pair {
    var out: std.ArrayList(env_mod.Pair) = .empty;
    var index: usize = 0;
    while (index < postman.varCount(item)) : (index += 1) {
        const pair = postman.varAt(item, index);
        if (pair.name.len == 0) continue;
        out.append(arena, .{ .name = pair.name, .value = pair.value }) catch break;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

// Resolve a step's address inside the node the run was started from.
fn resolve(root: postman.Value, base: runner.Address, address: runner.Address) ?postman.Value {
    var node = root;
    var level = base.depth;
    while (level < address.depth) : (level += 1) {
        node = postman.itemAt(node, address.segments[level]) orelse return null;
    }
    return node;
}

// Run `collection` (a collection or a folder) for its plan, and hand back every row plus the totals.
pub fn run(
    arena: Allocator,
    transport: http_mod.Transport,
    collection: postman.Value,
    base: runner.Address,
    vars: *Vars,
    opts: Options,
) Report {
    vars.arena = arena;
    const steps = runner.collect(arena, collection, base) catch
        return .{ .failure = "not enough memory to plan this run" };
    if (steps.len == 0) return .{ .failure = "there is no request under this selection" };

    const iterations = runner.iterationsFor(opts.data.count(), opts.iterations);
    var rows: std.ArrayList(Row) = .empty;
    var report = Report{};

    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        for (steps) |step| {
            if (!step.enabled) continue;
            if (opts.stop) |stop| {
                if (stop(opts.stop_ctx)) {
                    report.stopped = true;
                    break;
                }
            }
            const row = oneStep(arena, transport, collection, base, vars, opts, step, iteration) catch Row{
                .iteration = iteration + 1,
                .name = step.name,
                .method = step.method,
                .failure = .request,
                .error_text = "not enough memory to build this request",
            };
            rows.append(arena, row) catch break;
            report.requests += 1;
            report.duration_ms += row.time_ms;
            if (row.ok) report.ok += 1 else report.failed += 1;
            if (opts.delay_ms > 0 and report.requests < steps.len * iterations) {
                std.Io.sleep(opts.io, .fromMilliseconds(opts.delay_ms), .awake) catch {};
            }
        }
        if (report.stopped) break;
    }
    report.rows = rows.items;
    return report;
}

fn oneStep(
    arena: Allocator,
    transport: http_mod.Transport,
    collection: postman.Value,
    base: runner.Address,
    vars: *Vars,
    opts: Options,
    step: runner.Step,
    iteration: usize,
) Allocator.Error!Row {
    var row = Row{ .iteration = iteration + 1, .name = step.name, .method = step.method };
    const node = resolve(collection, base, step.path) orelse {
        row.failure = .request;
        row.error_text = "this request is no longer in the collection";
        return row;
    };
    const data_pairs = try data_file.pairs(arena, opts.data, iteration);
    const scope = scopeFor(arena, node, collection, vars.slice(), data_pairs);
    const host = script_mod.Host{ .ctx = vars, .get_fn = scriptGet, .set_fn = scriptSet };

    // A Pre-req script runs before anything leaves; a failure stops this request, exactly as Postman stops it.
    const pre = postman.scriptOf(node, .pre);
    if (pre.len > 0) {
        const outcome = script_mod.run(arena, pre, null, host);
        row.logs = outcome.logs;
        if (outcome.failure) |failure| {
            row.failure = .script;
            row.error_text = script_mod.describe(arena, failure);
            return row;
        }
    }

    const wire = send_request.build(arena, node, .{ .boundary = "kurir-run", .scope = scope }) catch |err| {
        row.failure = .request;
        row.error_text = switch (err) {
            error.NoUrl => "this request has no URL",
            error.NotARequest => "this node is not a request",
            error.OutOfMemory => "not enough memory to expand this request's variables",
        };
        return row;
    };
    row.url = wire.url;
    const result = transport.perform(.{ .method = wire.method, .url = wire.url, .headers = wire.headers, .body = wire.body });
    row.status = result.status;
    row.time_ms = result.time_ms;
    if (result.failed) row.error_text = if (result.error_message.len > 0) result.error_message else result.error_title;

    // A Post-res script reads the answer, and its `test(...)` calls are what decides a pass or a fail.
    var post_failed = false;
    const post = postman.scriptOf(node, .post);
    if (post.len > 0) {
        const answer = script_mod.Response{ .status = result.status, .headers = try headersOf(arena, result), .body = result.body };
        const outcome = script_mod.run(arena, post, answer, host);
        row.tests = outcome.tests;
        if (outcome.logs.len > 0) row.logs = outcome.logs;
        if (outcome.failure) |failure| {
            post_failed = true;
            row.error_text = script_mod.describe(arena, failure);
        }
    }

    const verdict = runner.verdict(result, post_failed, row.tests);
    row.ok = verdict.ok;
    row.failure = verdict.failure;
    if (row.ok) row.error_text = "";
    return row;
}

fn headersOf(arena: Allocator, result: http_mod.Result) Allocator.Error![]const script_mod.Header {
    if (result.headers.len == 0) return &.{};
    const headers = try arena.alloc(script_mod.Header, result.headers.len);
    for (result.headers, 0..) |header, index| headers[index] = .{ .name = header.name, .value = header.value };
    return headers;
}

// The report as JSON: what a build reads after `kurirw run`, and what a person keeps as a record.
pub fn reportJson(arena: Allocator, collection_name: []const u8, report: Report) ![]u8 {
    var root: postman.Object = .empty;
    try root.put(arena, "format", .{ .string = "kurir/report@1" });
    try root.put(arena, "collection", .{ .string = collection_name });
    try root.put(arena, "stopped", .{ .bool = report.stopped });

    var summary: postman.Object = .empty;
    try summary.put(arena, "requests", .{ .integer = @intCast(report.requests) });
    try summary.put(arena, "ok", .{ .integer = @intCast(report.ok) });
    try summary.put(arena, "failed", .{ .integer = @intCast(report.failed) });
    try summary.put(arena, "duration_ms", .{ .integer = @intCast(report.duration_ms) });
    try root.put(arena, "summary", .{ .object = summary });

    var rows: postman.Array = .init(arena);
    for (report.rows) |row| {
        var entry: postman.Object = .empty;
        try entry.put(arena, "iteration", .{ .integer = @intCast(row.iteration) });
        try entry.put(arena, "name", .{ .string = row.name });
        try entry.put(arena, "method", .{ .string = row.method });
        try entry.put(arena, "url", .{ .string = row.url });
        try entry.put(arena, "status", .{ .integer = row.status });
        try entry.put(arena, "time_ms", .{ .integer = @intCast(row.time_ms) });
        try entry.put(arena, "ok", .{ .bool = row.ok });
        try entry.put(arena, "failure", .{ .string = runner.failureLabel(row.failure) });
        try entry.put(arena, "error", .{ .string = row.error_text });
        var tests: postman.Array = .init(arena);
        for (row.tests) |one| {
            var check: postman.Object = .empty;
            try check.put(arena, "name", .{ .string = one.name });
            try check.put(arena, "passed", .{ .bool = one.passed });
            try tests.append(.{ .object = check });
        }
        try entry.put(arena, "tests", .{ .array = tests });
        try rows.append(.{ .object = entry });
    }
    try root.put(arena, "rows", .{ .array = rows });
    return postman.write(arena, .{ .object = root }, true);
}

const testing = std.testing;

// Two requests, one collection: enough to prove ordering, iteration and the verdict.
const fixture =
    \\{"info":{"name":"billing"},"item":[
    \\ {"name":"first","request":{"method":"GET","url":"https://api.test/a"}},
    \\ {"name":"second","request":{"method":"POST","url":"https://api.test/b","post_script":"test(\"status is 200\", pm.response.code == 200)"}}
    \\]}
;

test "a run sends each request once, in order, and totals the rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collection = try postman.parseTree(arena, fixture);
    var fake = http_mod.Fake.init(arena);
    var vars = Vars{};
    const report = run(arena, fake.transport(), collection, .{}, &vars, .{ .io = testing.io });

    try testing.expectEqualStrings("", report.failure);
    try testing.expectEqual(@as(usize, 2), report.requests);
    try testing.expectEqual(@as(usize, 2), report.ok);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqualStrings("first", report.rows[0].name);
    try testing.expectEqualStrings("second", report.rows[1].name);
    // The post script's own `test(...)` passed, so the row carries it and the verdict is a pass.
    try testing.expectEqual(@as(usize, 1), report.rows[1].tests.len);
    try testing.expect(report.rows[1].tests[0].passed);
}

test "a failed test is what fails the row, even though the status was fine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const asserted = try postman.parseTree(arena,
        \\{"info":{"name":"c"},"item":[{"name":"only","request":{"method":"GET","url":"https://api.test/a","post_script":"test(\"body says ok\", pm.response.text() == \"nope\")"}}]}
    );
    var fake = http_mod.Fake.init(arena);
    var vars = Vars{};
    const report = run(arena, fake.transport(), asserted, .{}, &vars, .{ .io = testing.io });
    try testing.expectEqual(@as(usize, 0), report.ok);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(runner.Failure.assertion, report.rows[0].failure);
}

test "with no tests the status decides, and a transport failure is its own reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try postman.parseTree(arena,
        \\{"info":{"name":"c"},"item":[{"name":"only","request":{"method":"GET","url":"https://api.test/a"}}]}
    );
    var fake = http_mod.Fake.init(arena);
    fake.status = 404;
    var vars = Vars{};
    const refused = run(arena, fake.transport(), plain, .{}, &vars, .{ .io = testing.io });
    try testing.expectEqual(runner.Failure.status, refused.rows[0].failure);

    fake.status = 200;
    fake.failure_name = "ConnectionRefused";
    const broken = run(arena, fake.transport(), plain, .{}, &vars, .{ .io = testing.io });
    try testing.expectEqual(runner.Failure.transport, broken.rows[0].failure);
    try testing.expect(!broken.rows[0].ok);
}

test "a data row repeats the whole collection, and its column is what the URL expands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collection = try postman.parseTree(arena,
        \\{"info":{"name":"c"},"item":[{"name":"only","request":{"method":"GET","url":"https://api.test/{{id}}"}}]}
    );
    const data = try data_file.parse(arena, "id\n1\n2\n");
    var fake = http_mod.Fake.init(arena);

    var vars = Vars{};
    const first = run(arena, fake.transport(), collection, .{}, &vars, .{ .io = testing.io, .data = data });
    try testing.expectEqual(@as(usize, 2), first.requests);
    try testing.expectEqual(@as(usize, 1), first.rows[0].iteration);
    try testing.expectEqual(@as(usize, 2), first.rows[1].iteration);
    try testing.expectEqualStrings("https://api.test/1", first.rows[0].url);
    try testing.expectEqualStrings("https://api.test/2", first.rows[1].url);
    // The data file decides the count, so the option is not consulted.
    try testing.expectEqual(@as(usize, 2), first.rows.len);
}

test "a pre-req script that fails stops its request and says why" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collection = try postman.parseTree(arena,
        \\{"info":{"name":"c"},"item":[{"name":"only","request":{"method":"GET","url":"https://api.test/a","pre_script":"pm.environment.get("}}]}
    );
    var fake = http_mod.Fake.init(arena);
    var vars = Vars{};
    const report = run(arena, fake.transport(), collection, .{}, &vars, .{ .io = testing.io });
    try testing.expectEqual(runner.Failure.script, report.rows[0].failure);
    try testing.expect(std.mem.indexOf(u8, report.rows[0].error_text, "line") != null);
}

test "a stop between requests ends the run and says it was stopped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = http_mod.Fake.init(arena);
    var vars = Vars{};
    const collection = try postman.parseTree(arena, fixture);
    const report = run(arena, fake.transport(), collection, .{}, &vars, .{
        .io = testing.io,
        .stop = struct {
            fn stop(_: ?*anyopaque) bool {
                return true;
            }
        }.stop,
    });
    try testing.expect(report.stopped);
    try testing.expectEqual(@as(usize, 0), report.requests);
}

test "the report is JSON a build can read: a summary and one row per request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = Report{
        .requests = 1,
        .ok = 1,
        .duration_ms = 412,
        .rows = &.{.{ .iteration = 1, .name = "only", .method = "GET", .status = 200, .time_ms = 412, .ok = true }},
    };
    const json = try reportJson(arena, "billing", report);
    try testing.expect(std.mem.indexOf(u8, json, "\"format\": \"kurir/report@1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ok\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\": \"only\"") != null);
}
