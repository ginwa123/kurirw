//! Kurir's on-disk document: one JSON file holding an array of workspaces, each holding Postman collections.
const std = @import("std");
const postman = @import("../model/postman.zig");

pub const Value = postman.Value;
pub const Object = postman.Object;
pub const Array = postman.Array;
pub const Allocator = std.mem.Allocator;

// The wrapper the PRD asks for: workspaces are not part of the Postman schema, so they live in one of ours.
pub const format_tag = "kurir/workspaces@1";

pub const default_workspace = "My Workspace";
pub const file_name = "workspaces.json";

pub const LoadResult = struct {
    doc: Value,
    // False when the file did not exist yet, so the app can say "started fresh" rather than "loaded".
    from_disk: bool,
    // Set when a file existed but could not be used; the caller shows it instead of a blank screen.
    error_name: []const u8 = "",
};

// An empty document: one workspace and no collections, which is exactly what a first run shows.
pub fn blank(alloc: Allocator, workspace_id: []const u8) !Value {
    var workspace: Object = .empty;
    try workspace.put(alloc, "id", .{ .string = try alloc.dupe(u8, workspace_id) });
    try workspace.put(alloc, "name", .{ .string = try alloc.dupe(u8, default_workspace) });
    try workspace.put(alloc, "collections", .{ .array = Array.init(alloc) });

    var doc: Object = .empty;
    try doc.put(alloc, "format", .{ .string = format_tag });
    try doc.put(alloc, "workspaces", .{ .array = Array.init(alloc) });
    var doc_value = Value{ .object = doc };
    _ = try addWorkspace(alloc, &doc_value, .{ .object = workspace });
    return doc_value;
}

// ---- workspaces ----------------------------------------------------------------------------------------------

pub fn workspaceCount(doc: Value) usize {
    if (doc != .object) return 0;
    const list = doc.object.get("workspaces") orelse return 0;
    if (list != .array) return 0;
    return list.array.items.len;
}

pub fn workspaceAt(doc: Value, index: usize) ?Value {
    if (doc != .object) return null;
    const list = doc.object.get("workspaces") orelse return null;
    if (list != .array) return null;
    if (index >= list.array.items.len) return null;
    return list.array.items[index];
}

pub fn workspacePtr(doc: *Value, index: usize) ?*Value {
    if (doc.* != .object) return null;
    const list = doc.object.getPtr("workspaces") orelse return null;
    if (list.* != .array) return null;
    if (index >= list.array.items.len) return null;
    return &list.array.items[index];
}

pub fn workspaceName(doc: Value, index: usize) []const u8 {
    const workspace = workspaceAt(doc, index) orelse return "";
    return postman.str(workspace, "name");
}

pub fn setWorkspaceName(alloc: Allocator, doc: *Value, index: usize, name: []const u8) void {
    const workspace = workspacePtr(doc, index) orelse return;
    if (workspace.* != .object) return;
    const owned = alloc.dupe(u8, name) catch return;
    workspace.object.put(alloc, "name", .{ .string = owned }) catch {};
}

pub fn addWorkspace(alloc: Allocator, doc: *Value, workspace: Value) !usize {
    if (doc.* != .object) doc.* = .{ .object = .empty };
    const list = try postman.arrayChild(alloc, doc, "workspaces");
    try list.append(workspace);
    return list.items.len - 1;
}

pub fn removeWorkspace(doc: *Value, index: usize) void {
    if (doc.* != .object) return;
    const list = doc.object.getPtr("workspaces") orelse return;
    if (list.* != .array) return;
    if (index >= list.array.items.len) return;
    _ = list.array.orderedRemove(index);
}

// ---- collections inside a workspace --------------------------------------------------------------------------

pub fn collectionsPtr(alloc: Allocator, doc: *Value, workspace_index: usize) !*Array {
    const workspace = workspacePtr(doc, workspace_index) orelse return error.NoSuchWorkspace;
    return postman.arrayChild(alloc, workspace, "collections");
}

pub fn collectionCount(doc: Value, workspace_index: usize) usize {
    const workspace = workspaceAt(doc, workspace_index) orelse return 0;
    if (workspace != .object) return 0;
    const list = workspace.object.get("collections") orelse return 0;
    if (list != .array) return 0;
    return list.array.items.len;
}

pub fn collectionAt(doc: Value, workspace_index: usize, index: usize) ?Value {
    const workspace = workspaceAt(doc, workspace_index) orelse return null;
    if (workspace != .object) return null;
    const list = workspace.object.get("collections") orelse return null;
    if (list != .array) return null;
    if (index >= list.array.items.len) return null;
    return list.array.items[index];
}

pub fn collectionPtr(doc: *Value, workspace_index: usize, index: usize) ?*Value {
    const workspace = workspacePtr(doc, workspace_index) orelse return null;
    if (workspace.* != .object) return null;
    const list = workspace.object.getPtr("collections") orelse return null;
    if (list.* != .array) return null;
    if (index >= list.array.items.len) return null;
    return &list.array.items[index];
}

pub fn addCollection(alloc: Allocator, doc: *Value, workspace_index: usize, collection: Value) !usize {
    const list = try collectionsPtr(alloc, doc, workspace_index);
    try list.append(collection);
    return list.items.len - 1;
}

pub fn removeCollection(doc: *Value, workspace_index: usize, index: usize) void {
    const workspace = workspacePtr(doc, workspace_index) orelse return;
    if (workspace.* != .object) return;
    const list = workspace.object.getPtr("collections") orelse return;
    if (list.* != .array) return;
    if (index >= list.array.items.len) return;
    _ = list.array.orderedRemove(index);
}

// ---- the file ------------------------------------------------------------------------------------------------

// `$KURIR_HOME`, else `$HOME/.kurir`, else the current directory. Returns the full path to the document file.
pub fn defaultPath(alloc: Allocator, environ: anytype) ![]u8 {
    if (environ.get("KURIR_HOME")) |home| return std.fs.path.join(alloc, &.{ home, file_name });
    if (environ.get("HOME")) |home| return std.fs.path.join(alloc, &.{ home, ".kurir", file_name });
    return alloc.dupe(u8, file_name);
}

// The directory part of `path`, so a save can create it.
fn parentDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

// Read the document, or hand back a blank one when there is no file yet. A corrupt file is reported, not swallowed.
pub fn load(io: std.Io, alloc: Allocator, path: []const u8, workspace_id: []const u8) LoadResult {
    const dir = std.Io.Dir.cwd();
    const bytes = dir.readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .doc = blank(alloc, workspace_id) catch .{ .null = {} }, .from_disk = false },
        else => return .{
            .doc = blank(alloc, workspace_id) catch .{ .null = {} },
            .from_disk = false,
            .error_name = @errorName(err),
        },
    };
    const parsed = postman.parseTree(alloc, bytes) catch |err| return .{
        .doc = blank(alloc, workspace_id) catch .{ .null = {} },
        .from_disk = false,
        .error_name = @errorName(err),
    };
    if (workspaceCount(parsed) == 0) return .{
        .doc = blank(alloc, workspace_id) catch parsed,
        .from_disk = true,
        .error_name = "EmptyDocument",
    };
    return .{ .doc = parsed, .from_disk = true };
}

// Write the document. `alloc` must not be an arena: the JSON bytes are freed before returning.
pub fn save(io: std.Io, alloc: Allocator, path: []const u8, doc: Value) !void {
    const bytes = try postman.write(alloc, doc, true);
    defer alloc.free(bytes);
    const dir = std.Io.Dir.cwd();
    const parent = parentDir(path);
    if (!std.mem.eql(u8, parent, ".")) try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ---- tests ---------------------------------------------------------------------------------------------------

const test_id = "00000000000000000000000000000001";

test "a blank document has one workspace and no collections" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try blank(arena, test_id);
    try std.testing.expectEqual(@as(usize, 1), workspaceCount(doc));
    try std.testing.expectEqualStrings(default_workspace, workspaceName(doc, 0));
    try std.testing.expectEqual(@as(usize, 0), collectionCount(doc, 0));
    try std.testing.expectEqualStrings(format_tag, postman.str(doc, "format"));
}

test "workspaces can be added, renamed and removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try blank(arena, test_id);
    const second = try blank(arena, test_id);
    const made = try addWorkspace(arena, &doc, workspaceAt(second, 0).?);
    try std.testing.expectEqual(@as(usize, 1), made);
    try std.testing.expectEqual(@as(usize, 2), workspaceCount(doc));

    setWorkspaceName(arena, &doc, 1, "Team");
    try std.testing.expectEqualStrings("Team", workspaceName(doc, 1));

    removeWorkspace(&doc, 0);
    try std.testing.expectEqual(@as(usize, 1), workspaceCount(doc));
    try std.testing.expectEqualStrings("Team", workspaceName(doc, 0));
}

test "a collection goes into the workspace and out again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try blank(arena, test_id);
    const collection = try postman.newCollection(arena, "Payments", try postman.makeId(arena, @splat(1)));
    _ = try addCollection(arena, &doc, 0, collection);
    _ = try addCollection(arena, &doc, 0, try postman.newCollection(arena, "Users", try postman.makeId(arena, @splat(2))));

    try std.testing.expectEqual(@as(usize, 2), collectionCount(doc, 0));
    try std.testing.expectEqualStrings("Users", postman.str(collectionAt(doc, 0, 1).?.object.get("info").?, "name"));

    removeCollection(&doc, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), collectionCount(doc, 0));
    try std.testing.expectEqualStrings("Users", postman.str(collectionAt(doc, 0, 0).?.object.get("info").?, "name"));
}

test "save then load restores the document byte for byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fs.path.join(arena, &.{ dir_path, "nested", file_name });

    var doc = try blank(arena, test_id);
    _ = try addCollection(arena, &doc, 0, try postman.newCollection(arena, "Payments", try postman.makeId(arena, @splat(3))));
    try save(io, std.testing.allocator, path, doc);

    const loaded = load(io, arena, path, test_id);
    try std.testing.expect(loaded.from_disk);
    try std.testing.expectEqualStrings("", loaded.error_name);
    try std.testing.expectEqual(@as(usize, 1), workspaceCount(loaded.doc));
    try std.testing.expectEqual(@as(usize, 1), collectionCount(loaded.doc, 0));

    const before = try postman.write(std.testing.allocator, doc, true);
    defer std.testing.allocator.free(before);
    const after = try postman.write(std.testing.allocator, loaded.doc, true);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "a missing file loads as a fresh document, and a corrupt one reports why" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const missing = try std.fs.path.join(arena, &.{ dir_path, "absent.json" });
    const blank_load = load(io, arena, missing, test_id);
    try std.testing.expect(!blank_load.from_disk);
    try std.testing.expectEqual(@as(usize, 1), workspaceCount(blank_load.doc));

    const corrupt = try std.fs.path.join(arena, &.{ dir_path, "corrupt.json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "corrupt.json", .data = "{ not json" });
    const corrupt_load = load(io, arena, corrupt, test_id);
    try std.testing.expect(!corrupt_load.from_disk);
    try std.testing.expectEqualStrings("SyntaxError", corrupt_load.error_name);
    // A broken file never leaves the app without a workspace to draw.
    try std.testing.expectEqual(@as(usize, 1), workspaceCount(corrupt_load.doc));
}

test "the default path follows KURIR_HOME, then HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    try env_map.put("HOME", "/home/person");
    try env_map.put("KURIR_HOME", "/data/kurir");

    try std.testing.expectEqualStrings("/data/kurir/workspaces.json", try defaultPath(arena, env_map));
    _ = env_map.swapRemove("KURIR_HOME");
    try std.testing.expectEqualStrings("/home/person/.kurir/workspaces.json", try defaultPath(arena, env_map));
}
