//! The working session, kept beside the document: the tabs that were open, and the edits nobody saved yet.
const std = @import("std");

const postman = @import("../model/postman.zig");

const Allocator = std.mem.Allocator;
const Value = postman.Value;

pub const file_name = "session.json";
pub const format_tag = "kurir/session@1";

// What a previous run left behind: the document as it was on screen (edits and all), and the tabs around it.
pub const Restored = struct {
    doc: ?Value = null,
    workspace: usize = 0,
    active: []const u8 = "",
    tabs: []const []const u8 = &.{},
    dirty: []const []const u8 = &.{},
};

// The session file lives next to the document it belongs to, so a scratch home carries both.
pub fn pathFor(alloc: Allocator, document_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(document_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, file_name });
}

// Read the session file, or null when there is none (a first run, or a run that never wrote one).
pub fn load(arena: Allocator, io: std.Io, path: []const u8) ?Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024)) catch return null;
    const tree = postman.parseTree(arena, bytes) catch return null;
    if (tree != .object) return null;
    if (!std.mem.eql(u8, postman.str(tree, "format"), format_tag)) return null;

    var out = Restored{};
    if (tree.object.get("doc")) |doc| {
        if (doc == .object) out.doc = doc;
    }
    if (tree.object.get("workspace")) |workspace| {
        if (workspace == .integer and workspace.integer >= 0) out.workspace = @intCast(workspace.integer);
    }
    out.active = postman.str(tree, "active");
    out.tabs = listOf(arena, tree, "tabs") catch &.{};
    out.dirty = listOf(arena, tree, "dirty") catch &.{};
    return out;
}

// The strings of a JSON array, copied into `arena` so the caller owns them.
fn listOf(arena: Allocator, tree: Value, key: []const u8) ![]const []const u8 {
    if (tree != .object) return &.{};
    const list = tree.object.get(key) orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        if (item != .string) continue;
        try out.append(arena, try arena.dupe(u8, item.string));
    }
    return out.toOwnedSlice(arena);
}

// Write the session: the document as it stands, the tabs, and which of them are not on disk.
pub fn save(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    doc: Value,
    workspace: usize,
    active: []const u8,
    tabs: []const []const u8,
    dirty: []const []const u8,
) !void {
    var root: postman.Object = .empty;
    try root.put(alloc, "format", .{ .string = format_tag });
    try root.put(alloc, "workspace", .{ .integer = @intCast(workspace) });
    try root.put(alloc, "active", .{ .string = try alloc.dupe(u8, active) });
    try root.put(alloc, "tabs", .{ .array = try stringArray(alloc, tabs) });
    try root.put(alloc, "dirty", .{ .array = try stringArray(alloc, dirty) });
    try root.put(alloc, "doc", doc);

    const bytes = try postman.write(alloc, .{ .object = root }, false);
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.mem.eql(u8, parent, ".")) dir.createDirPath(io, parent) catch {};
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn stringArray(alloc: Allocator, items: []const []const u8) !postman.Array {
    var out: postman.Array = .init(alloc);
    for (items) |item| try out.append(.{ .string = item });
    return out;
}

const testing = std.testing;

test "a session round-trips its document, its tabs and its dirty paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    const path = try std.fs.path.join(arena, &.{ buf[0..len], file_name });

    const doc = try postman.parseTree(arena, "{\"format\":\"kurir/workspaces@1\",\"workspaces\":[]}");
    const tabs = [_][]const u8{ "0.0", "0.1" };
    const dirty = [_][]const u8{"0.0"};
    try save(arena, testing.io, path, doc, 0, "0.1", &tabs, &dirty);

    const restored = load(arena, testing.io, path) orelse return error.SessionMissing;
    try testing.expect(restored.doc != null);
    try testing.expectEqualStrings("kurir/workspaces@1", postman.str(restored.doc.?, "format"));
    try testing.expectEqualStrings("0.1", restored.active);
    try testing.expectEqual(@as(usize, 2), restored.tabs.len);
    try testing.expectEqualStrings("0.0", restored.tabs[0]);
    try testing.expectEqual(@as(usize, 1), restored.dirty.len);
    try testing.expectEqualStrings("0.0", restored.dirty[0]);
}

test "a file that is not a session is ignored, not half-read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{\"format\":\"someone/else@1\"}" });
    const path = try std.fs.path.join(arena, &.{ buf[0..len], file_name });
    try testing.expect(load(arena, testing.io, path) == null);
}

test "the session path sits beside the document it belongs to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try pathFor(arena, "/home/someone/.kurir/workspaces.json");
    // The separator is the host's, so the expectation is joined rather than spelled: this suite runs on all three.
    const want = try std.fs.path.join(arena, &.{ "/home/someone/.kurir", file_name });
    try testing.expectEqualStrings(want, path);
}
