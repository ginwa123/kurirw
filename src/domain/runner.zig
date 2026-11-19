//! A collection run as a value: which requests, in what order, and how one result is judged. Pure.
const std = @import("std");

const postman = @import("../data/model/postman.zig");
const http_mod = @import("../data/remote/http_client.zig");
const script_mod = @import("script.zig");

pub const Allocator = std.mem.Allocator;

// A run is an ordered walk of the tree, so the nesting a collection may have is this module's own limit.
pub const max_depth: usize = 8;
// How many requests one run may carry: a collection larger than this is a job for the CLI, not a page.
pub const max_steps: usize = 256;

// A node's address inside the document: the collection index, then one index per nesting level.
pub const Address = struct {
    depth: usize = 0,
    segments: [max_depth]u16 = @splat(0),

    pub fn child(self: Address, index: u16) Address {
        var next = self;
        if (next.depth < max_depth) {
            next.segments[next.depth] = index;
            next.depth += 1;
        }
        return next;
    }

    pub fn eql(a: Address, b: Address) bool {
        if (a.depth != b.depth) return false;
        for (a.segments[0..a.depth], b.segments[0..b.depth]) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
};

// One request in the run: where it lives, what to call it, and whether this run sends it.
pub const Step = struct {
    path: Address = .{},
    name: []const u8 = "",
    method: []const u8 = postman.default_method,
    enabled: bool = true,
};

// Walk `root` in document order and hand back every request under it, nested folders included.
pub fn collect(arena: Allocator, root: postman.Value, base: Address) Allocator.Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    try walk(arena, root, base, &steps);
    return steps.items;
}

fn walk(arena: Allocator, node: postman.Value, base: Address, steps: *std.ArrayList(Step)) Allocator.Error!void {
    if (steps.items.len >= max_steps) return;
    if (postman.isRequest(node)) {
        try steps.append(arena, .{
            .path = base,
            .name = nameOf(node),
            .method = postman.normalizeMethod(postman.str(node.object.get("request").?, "method")),
        });
        return;
    }
    if (base.depth >= max_depth) return;
    var index: usize = 0;
    while (index < postman.itemCount(node)) : (index += 1) {
        const item = postman.itemAt(node, index) orelse continue;
        try walk(arena, item, base.child(@intCast(index)), steps);
    }
}

// A request's display name; a collection's is under `info`, which is the only place Postman puts it.
fn nameOf(node: postman.Value) []const u8 {
    const name = postman.str(node, "name");
    if (name.len > 0) return name;
    if (node != .object) return "";
    const info = node.object.get("info") orelse return "";
    return postman.str(info, "name");
}

// How many times the run repeats: a data file decides it, and the option is the answer when there is none.
pub fn iterationsFor(data_rows: usize, requested: usize) usize {
    if (data_rows > 0) return data_rows;
    return @max(@as(usize, 1), requested);
}

// Why a result did not pass. `none` is the only passing reason.
pub const Failure = enum { none, request, transport, script, assertion, status };

pub const Verdict = struct {
    ok: bool = true,
    failure: Failure = .none,
};

// A request passes when it was sent, its scripts ran, its own tests passed, and — with no tests — the status is below 400.
pub fn verdict(result: http_mod.Result, script_failed: bool, tests: []const script_mod.Test) Verdict {
    if (result.failed) return .{ .ok = false, .failure = .transport };
    if (script_failed) return .{ .ok = false, .failure = .script };
    if (tests.len > 0) {
        for (tests) |one| {
            if (!one.passed) return .{ .ok = false, .failure = .assertion };
        }
        return .{};
    }
    if (result.status >= 400) return .{ .ok = false, .failure = .status };
    return .{};
}

// The one sentence a row shows, so the table never leaves the reason to the reader.
pub fn failureLabel(failure: Failure) []const u8 {
    return switch (failure) {
        .none => "ok",
        .request => "cannot send",
        .transport => "no answer",
        .script => "script error",
        .assertion => "test failed",
        .status => "status",
    };
}

const testing = std.testing;

test "the plan walks a collection in document order, through folders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collection = try postman.parseTree(arena,
        \\{"info":{"name":"billing"},"item":[
        \\ {"name":"first","request":{"method":"get","url":"https://api.test/a"}},
        \\ {"name":"folder","item":[
        \\   {"name":"nested","request":{"method":"post","url":"https://api.test/b"}}
        \\ ]},
        \\ {"name":"last","request":{"method":"PUT","url":"https://api.test/c"}}
        \\]}
    );
    const steps = try collect(arena, collection, .{});
    try testing.expectEqual(@as(usize, 3), steps.len);
    try testing.expectEqualStrings("first", steps[0].name);
    try testing.expectEqualStrings("GET", steps[0].method);
    // The nested request carries the folder's index in its address, which is what the run opens.
    try testing.expectEqualStrings("nested", steps[1].name);
    try testing.expectEqual(@as(usize, 2), steps[1].path.depth);
    try testing.expectEqual(@as(u16, 1), steps[1].path.segments[0]);
    try testing.expectEqual(@as(u16, 0), steps[1].path.segments[1]);
    try testing.expectEqualStrings("last", steps[2].name);
    // Every step starts enabled: a run sends the collection until someone unchecks a row.
    try testing.expect(steps[0].enabled);
}

test "a data file decides the iterations, and the option answers when there is no file" {
    try testing.expectEqual(@as(usize, 5), iterationsFor(5, 2));
    try testing.expectEqual(@as(usize, 3), iterationsFor(0, 3));
    try testing.expectEqual(@as(usize, 1), iterationsFor(0, 0));
}

test "a verdict prefers the transport, then the script, then the tests, then the status" {
    const ok = http_mod.Result{ .status = 200 };
    try testing.expect(verdict(ok, false, &.{}).ok);

    const broken = http_mod.Result{ .status = 0, .failed = true };
    try testing.expectEqual(Failure.transport, verdict(broken, true, &.{}).failure);

    try testing.expectEqual(Failure.script, verdict(ok, true, &.{}).failure);

    const passed = [_]script_mod.Test{.{ .name = "a", .passed = true }};
    const failed = [_]script_mod.Test{ .{ .name = "a", .passed = true }, .{ .name = "b", .passed = false } };
    try testing.expectEqual(Failure.none, verdict(ok, false, &passed).failure);
    try testing.expectEqual(Failure.assertion, verdict(ok, false, &failed).failure);
    // A failing test wins over a good status, and a good test wins over a bad one.
    try testing.expectEqual(Failure.assertion, verdict(http_mod.Result{ .status = 500 }, false, &failed).failure);
    try testing.expectEqual(Failure.none, verdict(http_mod.Result{ .status = 500 }, false, &passed).failure);
}

test "with no tests at all a status of 400 or more is the failure, and below it is not" {
    try testing.expectEqual(Failure.status, verdict(http_mod.Result{ .status = 404 }, false, &.{}).failure);
    try testing.expectEqual(Failure.none, verdict(http_mod.Result{ .status = 302 }, false, &.{}).failure);
}
