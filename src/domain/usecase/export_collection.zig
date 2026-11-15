//! The rule for exporting: a collection is written as v2.1 JSON, named so Postman recognises the file.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");

const Allocator = std.mem.Allocator;

pub const suffix = ".postman_collection.json";

pub fn bytes(gpa: Allocator, collection: postman.Value) ![]u8 {
    return postman.write(gpa, collection, true);
}

// The name the save panel suggests; the caller frees it.
pub fn suggestedName(gpa: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ if (name.len == 0) "collection" else name, suffix }) catch
        "collection.postman_collection.json";
}
