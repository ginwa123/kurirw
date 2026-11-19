//! The saved requests of one workspace, as the runner's helper reads them at run time.
const std = @import("std");

const postman = @import("postman.zig");
const store = @import("../local/workspace_store.zig");

pub const Allocator = std.mem.Allocator;

// How deep the tree is walked: a path deeper than this is not a page's worth of requests.
const max_depth: usize = 8;

// Every request of the workspace as one JSON object keyed by the ref a spec writes: no test carries a URL.
pub fn build(arena: Allocator, doc: postman.Value, workspace: usize) ![]const u8 {
    var map: postman.Object = .empty;
    var walker = Walker{ .arena = arena, .map = &map };
    try walker.workspace(doc, workspace);
    return postman.write(arena, .{ .object = map }, false);
}

// Every ref of the workspace, in tree order: what a spec's `send(…)` is checked against.
pub fn refs(arena: Allocator, doc: postman.Value, workspace: usize) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var walker = Walker{ .arena = arena, .list = &list };
    try walker.workspace(doc, workspace);
    return list.items;
}

// The name a row is known by: a collection keeps it under `info`, everything else under `name`.
pub fn nameOf(node: postman.Value) []const u8 {
    if (postman.isCollection(node)) {
        const info = node.object.get("info") orelse return "";
        return postman.str(info, "name");
    }
    return postman.str(node, "name");
}

const Walker = struct {
    arena: Allocator,
    // One of the two is set: the JSON map, or the flat list of refs.
    map: ?*postman.Object = null,
    list: ?*std.ArrayList([]const u8) = null,
    names: std.ArrayList([]const u8) = .empty,
    // The collection's own variables, which every request under it inherits.
    collection_vars: []const postman.Var = &.{},

    fn workspace(self: *Walker, doc: postman.Value, workspace_index: usize) !void {
        const count = store.rootCount(doc, workspace_index);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const root = store.rootAt(doc, workspace_index, index) orelse continue;
            try self.walk(root, 0);
        }
    }

    fn walk(self: *Walker, node: postman.Value, depth: usize) !void {
        if (depth > max_depth) return;
        // A runner is a program, not an endpoint: it is never a ref.
        if (postman.isFlow(node)) return;
        const name = nameOf(node);
        if (postman.isRequest(node)) {
            try self.add(node, name);
            return;
        }
        const entered_collection = postman.isCollection(node);
        const previous = self.collection_vars;
        if (name.len > 0) try self.names.append(self.arena, name);
        if (entered_collection) self.collection_vars = try self.varsOf(node);
        const count = postman.itemCount(node);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const child = postman.itemAt(node, index) orelse continue;
            try self.walk(child, depth + 1);
        }
        if (entered_collection) self.collection_vars = previous;
        if (name.len > 0) _ = self.names.pop();
    }

    fn add(self: *Walker, node: postman.Value, name: []const u8) !void {
        if (name.len == 0) return;
        try self.names.append(self.arena, name);
        const ref = try joinNames(self.arena, self.names.items);
        _ = self.names.pop();
        if (self.list) |list| try list.append(self.arena, ref);
        if (self.map) |map| try map.put(self.arena, ref, try self.entry(node));
    }

    fn entry(self: *Walker, node: postman.Value) !postman.Value {
        const view = postman.requestView(self.arena, node) catch postman.RequestView{};
        var item: postman.Object = .empty;
        try item.put(self.arena, "method", .{ .string = try self.arena.dupe(u8, view.method) });
        try item.put(self.arena, "url", .{ .string = try self.arena.dupe(u8, view.url) });
        try item.put(self.arena, "bodyMode", .{ .string = try self.arena.dupe(u8, view.body_mode) });
        try item.put(self.arena, "bodyLanguage", .{ .string = try self.arena.dupe(u8, view.body_language) });
        try item.put(self.arena, "body", .{ .string = try self.arena.dupe(u8, view.body) });

        // The enabled header rows, because the helper sends them exactly as they stand.
        var headers: postman.Object = .empty;
        for (view.headers) |header| {
            if (header.disabled or header.key.len == 0) continue;
            try headers.put(self.arena, header.key, .{ .string = try self.arena.dupe(u8, header.value) });
        }
        try item.put(self.arena, "headers", .{ .object = headers });

        var parts: postman.Array = .init(self.arena);
        for (view.parts) |part| {
            var row: postman.Object = .empty;
            try row.put(self.arena, "key", .{ .string = try self.arena.dupe(u8, part.key) });
            try row.put(self.arena, "value", .{ .string = try self.arena.dupe(u8, part.value) });
            try row.put(self.arena, "disabled", .{ .bool = part.disabled });
            try parts.append(.{ .object = row });
        }
        try item.put(self.arena, "parts", .{ .array = parts });

        // The collection's variables, then the request's own: the nearer one wins, as the editor resolves them.
        var vars: postman.Object = .empty;
        for (self.collection_vars) |variable| {
            if (variable.name.len == 0) continue;
            try vars.put(self.arena, variable.name, .{ .string = try self.arena.dupe(u8, variable.value) });
        }
        for (try self.varsOf(node)) |variable| {
            if (variable.name.len == 0) continue;
            try vars.put(self.arena, variable.name, .{ .string = try self.arena.dupe(u8, variable.value) });
        }
        try item.put(self.arena, "vars", .{ .object = vars });

        // Auth travels as the document has it; the helper applies bearer/basic/apikey.
        if (node.object.get("request")) |request| {
            if (request == .object) {
                if (request.object.get("auth")) |auth| {
                    if (auth == .object) try item.put(self.arena, "auth", auth);
                }
            }
        }
        return .{ .object = item };
    }

    fn varsOf(self: *Walker, node: postman.Value) ![]const postman.Var {
        const count = postman.varCount(node);
        if (count == 0) return &.{};
        const out = try self.arena.alloc(postman.Var, count);
        for (out, 0..) |*variable, index| variable.* = postman.varAt(node, index);
        return out;
    }
};

// The ref of a row at the depth the walker is on: its names, joined by '/'.
fn joinNames(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names) |name| {
        if (name.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, name);
    }
    return out.items;
}

const testing = std.testing;

const fixture =
    \\{
    \\  "format": "kurir/workspaces@2",
    \\  "workspaces": [
    \\    {
    \\      "id": "00000000000000000000000000000001",
    \\      "name": "Proof",
    \\      "items": [
    \\        {
    \\          "info": { "name": "billing", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
    \\          "variable": [ { "name": "host", "value": "https://api.test" } ],
    \\          "item": [
    \\            {
    \\              "name": "ok",
    \\              "request": {
    \\                "method": "GET",
    \\                "url": "{{host}}/ok",
    \\                "header": [ { "key": "X-Trace", "value": "1" }, { "key": "X-Off", "value": "2", "disabled": true } ]
    \\              }
    \\            },
    \\            {
    \\              "name": "create",
    \\              "request": {
    \\                "method": "POST",
    \\                "url": "{{host}}/create",
    \\                "body": { "mode": "raw", "raw": "{\"amount\":1}", "options": { "raw": { "language": "json" } } }
    \\              }
    \\            },
    \\            { "name": "v2", "item": [ { "name": "deep", "request": { "method": "GET", "url": "{{host}}/v2/deep" } } ] }
    \\          ]
    \\        },
    \\        { "name": "Runner 1", "flow": { "format": "kurir/flow@1", "source": "test('x', async () => {})" } }
    \\      ]
    \\    }
    \\  ]
    \\}
;

test "the map names every request, with what it sends, and skips the runner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try postman.parseTree(arena, fixture);
    const text = try build(arena, doc, 0);
    try testing.expect(std.mem.indexOf(u8, text, "\"billing/ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"billing/create\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"billing/v2/deep\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Runner 1") == null);

    // The URL keeps its `{{var}}`, because the helper resolves it when the call is made.
    try testing.expect(std.mem.indexOf(u8, text, "{{host}}/ok") != null);
    // A disabled header is not sent.
    try testing.expect(std.mem.indexOf(u8, text, "X-Trace") != null);
    try testing.expect(std.mem.indexOf(u8, text, "X-Off") == null);

    // The body travels as text plus its language, so the helper can decide how to send it.
    try testing.expect(std.mem.indexOf(u8, text, "\"bodyMode\":\"raw\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"bodyLanguage\":\"json\"") != null);
    // The collection's variable is beside the request, not only in the environment.
    try testing.expect(std.mem.indexOf(u8, text, "\"host\":\"https://api.test\"") != null);

    // The flat list is what a spec's refs are checked against.
    const list = try refs(arena, doc, 0);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("billing/ok", list[0]);
    try testing.expectEqualStrings("billing/create", list[1]);
    try testing.expectEqualStrings("billing/v2/deep", list[2]);
}
