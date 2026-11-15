//! The rule for importing: which files are a Postman collection, and which are not.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    NotJson,
    NotACollection,
};

// Parse and vet in one step, so the caller cannot forget either check.
pub fn parse(arena: Allocator, bytes: []const u8) Error!postman.Value {
    const value = postman.parseTree(arena, bytes) catch return error.NotJson;
    if (!postman.isCollection(value)) return error.NotACollection;
    return value;
}

const testing = std.testing;

test "a file that is not a collection is refused before it reaches the tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NotJson, parse(arena, "{not json"));
    try testing.expectError(error.NotACollection, parse(arena, "{\"item\":[]}"));
}

test "a v2.1 collection is accepted as it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "{\"info\":{\"name\":\"Payments\",\"schema\":\"" ++ postman.schema_url ++ "\"},\"item\":[]}";
    const value = try parse(arena, file);
    try testing.expect(postman.isCollection(value));
    try testing.expectEqualStrings("Payments", postman.str(value.object.get("info").?, "name"));
}
