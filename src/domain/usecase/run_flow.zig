//! One flow program, run with no window: the steps the Runner page sends, driven by `kurirw run --runner`.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");
const store_mod = @import("../../data/local/workspace_store.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const flow_mod = @import("../flow.zig");
const runner = @import("../runner.zig");
const data_file = @import("../data_file.zig");
const run_collection = @import("run_collection.zig");

pub const Allocator = std.mem.Allocator;

// The request a `send` names, with the collection that scopes its variables.
pub const Target = struct {
    node: postman.Value,
    collection: postman.Value,
};

// `name`, or `collection/name`: the same rule the page's `findRequest` uses, over the workspace's roots.
pub fn findRequest(doc: postman.Value, workspace: usize, wanted_name: []const u8) ?Target {
    const slash = std.mem.indexOfScalar(u8, wanted_name, '/');
    const wanted_collection = if (slash) |at| wanted_name[0..at] else "";
    const wanted = if (slash) |at| wanted_name[at + 1 ..] else wanted_name;
    var index: usize = 0;
    const count = store_mod.rootCount(doc, workspace);
    while (index < count) : (index += 1) {
        const root = store_mod.rootAt(doc, workspace, index) orelse continue;
        // A runner is a root too, and holds no requests: only a collection can answer a `send`.
        if (!postman.isCollection(root)) continue;
        if (wanted_collection.len > 0) {
            const info = root.object.get("info") orelse continue;
            if (!std.ascii.eqlIgnoreCase(postman.str(info, "name"), wanted_collection)) continue;
        }
        if (findIn(root, wanted)) |node| return .{ .node = node, .collection = root };
    }
    return null;
}

// A depth-first walk for one request name, folders included.
fn findIn(node: postman.Value, wanted: []const u8) ?postman.Value {
    var index: usize = 0;
    while (index < postman.itemCount(node)) : (index += 1) {
        const item = postman.itemAt(node, index) orelse continue;
        if (postman.isRequest(item)) {
            if (std.ascii.eqlIgnoreCase(postman.str(item, "name"), wanted)) return item;
            continue;
        }
        if (findIn(item, wanted)) |found| return found;
    }
    return null;
}

// Run the program: its loops are unrolled first, then one request at a time, each judged like the page's table.
pub fn run(
    arena: Allocator,
    transport: http_mod.Transport,
    doc: postman.Value,
    workspace: usize,
    program: flow_mod.Flow,
    vars: *run_collection.Vars,
    opts: run_collection.Options,
) run_collection.Report {
    vars.arena = arena;
    if (program.failure) |failure| {
        const line = std.fmt.allocPrint(arena, "line {d}: {s}", .{ failure.line, failure.message }) catch "this program does not parse";
        return .{ .failure = line };
    }
    const steps = flow_mod.expand(arena, program, opts.data.count()) catch
        return .{ .failure = "not enough memory to plan this run" };
    if (steps.len == 0) return .{ .failure = "this runner sends nothing: add a `send \"request\"` line" };

    // A flow's own `for row in data` already unrolled the data rows, so the count is the option alone.
    const iterations = runner.iterationsFor(0, opts.iterations);
    var rows: std.ArrayList(run_collection.Row) = .empty;
    var report = run_collection.Report{};

    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        for (steps) |step| {
            if (opts.stop) |stop| {
                if (stop(opts.stop_ctx)) {
                    report.stopped = true;
                    break;
                }
            }
            const row = oneStep(arena, transport, doc, workspace, vars, opts, step, iteration) catch run_collection.Row{
                .iteration = iteration + 1,
                .name = step.request,
                .failure = .request,
                .error_text = "not enough memory to build this request",
            };
            rows.append(arena, row) catch break;
            report.requests += 1;
            report.duration_ms += row.time_ms;
            if (row.ok) report.ok += 1 else report.failed += 1;
            const wait = @max(opts.delay_ms, step.delay_ms);
            if (wait > 0) std.Io.sleep(opts.io, .fromMilliseconds(wait), .awake) catch {};
        }
        if (report.stopped) break;
    }
    report.rows = rows.items;
    return report;
}

fn oneStep(
    arena: Allocator,
    transport: http_mod.Transport,
    doc: postman.Value,
    workspace: usize,
    vars: *run_collection.Vars,
    opts: run_collection.Options,
    step: flow_mod.Step,
    iteration: usize,
) Allocator.Error!run_collection.Row {
    const target = findRequest(doc, workspace, step.request) orelse {
        // A name that matches nothing is a row of its own, exactly as the page reports it.
        return .{
            .iteration = iteration + 1,
            .name = step.request,
            .method = "",
            .failure = .request,
            .error_text = "no saved request has that name",
        };
    };
    const data_row = step.data_row orelse iteration;
    return run_collection.stepRow(arena, transport, target.node, target.collection, vars, opts.data, data_row, iteration, .{
        .pre = step.pre,
        .post = step.post,
    });
}

const testing = std.testing;

// A workspace with one collection of two requests, and a runner that sends both: the shape the page writes.
const collection_json =
    \\{"info":{"name":"billing"},"item":[
    \\ {"name":"first","request":{"method":"GET","url":"https://api.test/a"}},
    \\ {"name":"second","request":{"method":"POST","url":"https://api.test/b"}}
    \\]}
;

fn document(arena: Allocator) !postman.Value {
    var doc = try store_mod.blank(arena, "00000000000000000000000000000001");
    _ = try store_mod.addRoot(arena, &doc, 0, try postman.parseTree(arena, collection_json));
    _ = try store_mod.addRoot(arena, &doc, 0, try postman.newFlow(arena, "Smoke", "send \"first\"\nsend \"second\"\n"));
    return doc;
}

test "a runner's program finds its requests by name and sends them in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try document(arena);
    const program = try flow_mod.parse(arena, "send \"first\"\nsend \"second\"\n");
    var fake = http_mod.Fake.init(arena);
    var vars = run_collection.Vars{};
    const report = run(arena, fake.transport(), doc, 0, program, &vars, .{ .io = testing.io });

    try testing.expectEqualStrings("", report.failure);
    try testing.expectEqual(@as(usize, 2), report.requests);
    try testing.expectEqual(@as(usize, 2), report.ok);
    try testing.expectEqualStrings("first", report.rows[0].name);
    try testing.expectEqualStrings("GET", report.rows[0].method);
    try testing.expectEqualStrings("second", report.rows[1].name);
    try testing.expectEqualStrings("POST", report.rows[1].method);
}

test "the statements written under a send run around it, and their tests decide the row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try document(arena);
    const program = try flow_mod.parse(arena,
        \\pm.environment.set("token", "abc")
        \\send "first"
        \\test("the answer is fine", pm.response.code == 200)
    );
    var fake = http_mod.Fake.init(arena);
    var vars = run_collection.Vars{};
    const report = run(arena, fake.transport(), doc, 0, program, &vars, .{ .io = testing.io });

    try testing.expectEqual(@as(usize, 1), report.requests);
    try testing.expectEqual(@as(usize, 1), report.rows[0].tests.len);
    try testing.expect(report.rows[0].tests[0].passed);
    // The `set` before the send landed in the writable environment, which is how one step feeds the next.
    try testing.expectEqualStrings("abc", vars.lookup("token").?);
}

test "a send that names nothing says so as a row instead of stopping the run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try document(arena);
    const program = try flow_mod.parse(arena, "send \"absent\"\nsend \"second\"\n");
    var fake = http_mod.Fake.init(arena);
    var vars = run_collection.Vars{};
    const report = run(arena, fake.transport(), doc, 0, program, &vars, .{ .io = testing.io });

    try testing.expectEqual(@as(usize, 2), report.requests);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(runner.Failure.request, report.rows[0].failure);
    try testing.expect(std.mem.indexOf(u8, report.rows[0].error_text, "no saved request") != null);
    try testing.expect(report.rows[1].ok);
}

test "an empty program is a sentence, not an empty report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try document(arena);
    const program = try flow_mod.parse(arena, "");
    var fake = http_mod.Fake.init(arena);
    var vars = run_collection.Vars{};
    const report = run(arena, fake.transport(), doc, 0, program, &vars, .{ .io = testing.io });
    try testing.expect(report.failure.len > 0);
    try testing.expectEqual(@as(usize, 0), report.requests);
}
