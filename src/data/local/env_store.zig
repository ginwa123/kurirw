//! The environment file: every workspace's named environments, with which one is active. Beside the document.
const std = @import("std");

const env = @import("../../domain/env.zig");
const postman = @import("../model/postman.zig");

const Allocator = std.mem.Allocator;
const Variable = env.Variable;

pub const file_name = "environment.json";
pub const format_tag = "kurir/environment@3";

// One environment as the file holds it: a name, and the variables under it.
pub const EnvironmentGroup = struct {
    name: []const u8 = "",
    vars: []const Variable = &.{},
};

// One workspace's environments, filed under the workspace's own id so renaming it never loses them.
pub const Group = struct {
    workspace_id: []const u8 = "",
    // The environment the window sends with, by name; empty means none is active.
    active: []const u8 = "",
    environments: []const EnvironmentGroup = &.{},
};

// What a previous run left behind: every workspace's environments, copied into the caller's arena.
pub const Restored = struct {
    groups: []const Group = &.{},
};

// The environment file lives beside the document, so a scratch home carries all three files.
pub fn pathFor(alloc: Allocator, document_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(document_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, file_name });
}

// Read every workspace's environments, or none when there is no file (a first run, or a file that is not ours).
pub fn load(arena: Allocator, io: std.Io, path: []const u8) Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return .{};
    const tree = postman.parseTree(arena, bytes) catch return .{};
    if (tree != .object) return .{};
    if (!std.mem.eql(u8, postman.str(tree, "format"), format_tag)) return .{};
    const list = tree.object.get("workspaces") orelse return .{};
    if (list != .array) return .{};
    var out: std.ArrayList(Group) = .empty;
    for (list.array.items) |item| {
        const group = readGroup(arena, item) orelse continue;
        out.append(arena, group) catch break;
    }
    return .{ .groups = out.toOwnedSlice(arena) catch &.{} };
}

fn readGroup(arena: Allocator, item: postman.Value) ?Group {
    if (item != .object) return null;
    const id = postman.str(item, "id");
    if (id.len == 0) return null;
    var environments: std.ArrayList(EnvironmentGroup) = .empty;
    if (item.object.get("environments")) |list| {
        if (list == .array) {
            for (list.array.items) |entry| {
                const environment = readEnvironment(arena, entry) orelse continue;
                environments.append(arena, environment) catch break;
            }
        }
    }
    return .{
        .workspace_id = arena.dupe(u8, id) catch return null,
        .active = arena.dupe(u8, postman.str(item, "active")) catch return null,
        .environments = environments.toOwnedSlice(arena) catch &.{},
    };
}

fn readEnvironment(arena: Allocator, item: postman.Value) ?EnvironmentGroup {
    if (item != .object) return null;
    const name = postman.str(item, "name");
    if (name.len == 0) return null;
    var vars: std.ArrayList(Variable) = .empty;
    if (item.object.get("variables")) |list| {
        if (list == .array) readVariables(arena, &vars, list);
    }
    return .{
        .name = arena.dupe(u8, name) catch return null,
        .vars = vars.toOwnedSlice(arena) catch &.{},
    };
}

fn readVariables(arena: Allocator, vars: *std.ArrayList(Variable), entries: postman.Value) void {
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const name = postman.str(entry, "name");
        if (name.len == 0) continue;
        vars.append(arena, .{
            .name = arena.dupe(u8, name) catch continue,
            .initial = arena.dupe(u8, postman.str(entry, "initial")) catch continue,
            .current = arena.dupe(u8, postman.str(entry, "current")) catch continue,
            .secret = postman.boolean(entry, "secret"),
        }) catch break;
    }
}

// Write every workspace: an environment with no variables in it is still written, so an empty Dev survives.
pub fn save(alloc: Allocator, io: std.Io, path: []const u8, groups: []const Group) !void {
    var root: postman.Object = .empty;
    try root.put(alloc, "format", .{ .string = format_tag });
    var list: postman.Array = .init(alloc);
    for (groups) |group| {
        if (group.workspace_id.len == 0) continue;
        try list.append(.{ .object = try workspaceObject(alloc, group) });
    }
    try root.put(alloc, "workspaces", .{ .array = list });
    const bytes = try postman.write(alloc, .{ .object = root }, false);
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.mem.eql(u8, parent, ".")) dir.createDirPath(io, parent) catch {};
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn workspaceObject(alloc: Allocator, group: Group) !postman.Object {
    var item: postman.Object = .empty;
    try item.put(alloc, "id", .{ .string = try alloc.dupe(u8, group.workspace_id) });
    if (group.active.len > 0) try item.put(alloc, "active", .{ .string = try alloc.dupe(u8, group.active) });
    var environments: postman.Array = .init(alloc);
    for (group.environments) |environment| {
        if (environment.name.len == 0) continue;
        try environments.append(.{ .object = try environmentObject(alloc, environment) });
    }
    try item.put(alloc, "environments", .{ .array = environments });
    return item;
}

fn environmentObject(alloc: Allocator, environment: EnvironmentGroup) !postman.Object {
    var item: postman.Object = .empty;
    try item.put(alloc, "name", .{ .string = try alloc.dupe(u8, environment.name) });
    var variables: postman.Array = .init(alloc);
    for (environment.vars) |v| {
        if (v.name.len == 0) continue;
        var entry: postman.Object = .empty;
        try entry.put(alloc, "name", .{ .string = try alloc.dupe(u8, v.name) });
        try entry.put(alloc, "initial", .{ .string = try alloc.dupe(u8, v.initial) });
        if (v.current.len > 0) try entry.put(alloc, "current", .{ .string = try alloc.dupe(u8, v.current) });
        if (v.secret) try entry.put(alloc, "secret", .{ .bool = true });
        try variables.append(.{ .object = entry });
    }
    try item.put(alloc, "variables", .{ .array = variables });
    return item;
}

const testing = std.testing;

test "each workspace keeps its own environments, and the active one survives the round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    const path = try std.fs.path.join(arena, &.{ buf[0..len], file_name });

    const dev = [_]Variable{
        .{ .name = "base_url", .initial = "https://dev.example.com", .current = "https://dev2.example.com" },
        .{ .name = "token", .initial = "shared", .current = "s3cret", .secret = true },
    };
    const first = [_]EnvironmentGroup{
        .{ .name = "Dev", .vars = &dev },
        .{ .name = "Staging" },
    };
    const groups = [_]Group{
        .{ .workspace_id = "aaa", .active = "Dev", .environments = &first },
        .{ .workspace_id = "bbb", .environments = &first },
    };
    try save(arena, testing.io, path, &groups);

    const restored = load(arena, testing.io, path);
    try testing.expectEqual(@as(usize, 2), restored.groups.len);
    try testing.expectEqualStrings("aaa", restored.groups[0].workspace_id);
    try testing.expectEqualStrings("Dev", restored.groups[0].active);
    try testing.expectEqual(@as(usize, 2), restored.groups[0].environments.len);
    try testing.expectEqualStrings("Staging", restored.groups[0].environments[1].name);
    // An environment with no variables is still there: an empty Dev must not disappear.
    try testing.expectEqual(@as(usize, 0), restored.groups[0].environments[1].vars.len);

    const variables = restored.groups[0].environments[0].vars;
    try testing.expectEqual(@as(usize, 2), variables.len);
    try testing.expectEqualStrings("https://dev2.example.com", variables[0].current);
    try testing.expectEqualStrings("https://dev.example.com", variables[0].initial);
    try testing.expect(variables[1].secret);
    // The second workspace has no active environment of its own.
    try testing.expectEqualStrings("", restored.groups[1].active);
}

test "a file that is not ours is ignored, not half-read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{\"format\":\"someone/else@1\"}" });
    const path = try std.fs.path.join(arena, &.{ buf[0..len], file_name });
    try testing.expectEqual(@as(usize, 0), load(arena, testing.io, path).groups.len);
}

test "the environment path sits beside the document it belongs to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try pathFor(arena, "/home/someone/.kurir/workspaces.json");
    const want = try std.fs.path.join(arena, &.{ "/home/someone/.kurir", file_name });
    try testing.expectEqualStrings(want, path);
}
