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
