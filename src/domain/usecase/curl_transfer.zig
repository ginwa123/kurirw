//! The rules for moving a request across the clipboard: `curl …` in, `curl …` out, and the name to give it.
const std = @import("std");

const curl = @import("../../data/model/curl.zig");
const postman = @import("../../data/model/postman.zig");

const Allocator = std.mem.Allocator;

// What an import produces: a ready-to-store request, and a name for the tree row.
pub const Imported = struct {
    name: []const u8,
    request: curl.Request,
};

pub const Error = curl.Error;

const max_name: usize = 60;

// The row name a pasted command deserves: its last path segment, else its host, else "Request".
pub fn nameFor(arena: Allocator, url: []const u8) Error![]const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const query = std.mem.indexOfScalar(u8, after_scheme, '?') orelse after_scheme.len;
    var rest = after_scheme[0..query];
    const hash = std.mem.indexOfScalar(u8, rest, '#') orelse rest.len;
    rest = rest[0..hash];
    const trimmed = std.mem.trim(u8, rest, "/");
    if (trimmed.len == 0) return "Request";
    const slug = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| trimmed[slash + 1 ..] else trimmed;
    const candidate = if (slug.len > 0) slug else trimmed;
    if (candidate.len == 0) return "Request";
    if (candidate.len <= max_name) return candidate;
    return arena.dupe(u8, candidate[0..max_name]);
}

pub fn parse(arena: Allocator, text: []const u8) Error!Imported {
    const request = try curl.parse(arena, text);
    return .{ .name = try nameFor(arena, request.url), .request = request };
}

// The command that reproduces a stored request: every header that is not disabled, the body, and the method.
pub fn command(arena: Allocator, item: postman.Value) Error![]const u8 {
    const view = postman.requestView(arena, item) catch return error.Empty;
    var headers: std.ArrayList(curl.Header) = .empty;
    for (view.headers) |h| {
        if (h.disabled) continue;
        if (h.key.len == 0) continue;
        try headers.append(arena, .{ .name = h.key, .value = h.value });
    }
    return curl.format(arena, .{
        .method = view.method,
        .url = view.url,
        .headers = headers.items,
        .body = view.body,
    });
}

const testing = std.testing;

test "the name comes from the last path segment, then the host" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("items", try nameFor(arena, "https://api.example.com/v1/items?page=2"));
    try testing.expectEqualStrings("example.com", try nameFor(arena, "https://example.com"));
    try testing.expectEqualStrings("example.com", try nameFor(arena, "https://example.com/"));
}

test "a stored request exports as a command that carries its method, headers and body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var item = try postman.newRequest(arena, "Create widget", "POST", "https://api.example.com/items");
    try postman.setBodyRaw(arena, &item, "{\"name\":\"widget\"}");
    try postman.setHeaderKey(arena, &item, 0, "content-type");
    try postman.setHeaderValue(arena, &item, 0, "application/json");

    const text = try command(arena, item);
    try testing.expect(std.mem.indexOf(u8, text, "-X POST") != null);
    try testing.expect(std.mem.indexOf(u8, text, "content-type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--data-raw") != null);

    const back = try parse(arena, text);
    try testing.expectEqualStrings("POST", back.request.method);
    try testing.expectEqualStrings("https://api.example.com/items", back.request.url);
    try testing.expectEqualStrings("{\"name\":\"widget\"}", back.request.body);
}

test "importing names the request after its URL and keeps the parsed pieces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const imported = try parse(arena_state.allocator(), "curl -X PUT https://api.example.com/v1/items/7 -d 'a=1'");
    try testing.expectEqualStrings("7", imported.name);
    try testing.expectEqualStrings("PUT", imported.request.method);
    try testing.expectEqualStrings("a=1", imported.request.body);
}

test "a disabled header never reaches the exported command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var item = try postman.newRequest(arena, "r", "GET", "https://api.example.com/x");
    try postman.setHeaderKey(arena, &item, 0, "x-off");
    try postman.setHeaderValue(arena, &item, 0, "1");
    try postman.setHeaderEnabled(arena, &item, 0, false);

    const text = try command(arena, item);
    try testing.expect(std.mem.indexOf(u8, text, "x-off") == null);
}
