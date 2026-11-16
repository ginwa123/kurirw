//! The rule for sending: what leaves the process, and how a missing URL is reported. Pure, no window.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");

const Allocator = std.mem.Allocator;

pub const Failure = error{
    // The selected node is not a request.
    NotARequest,
    // A request with no URL is not an error to send, it is a request that cannot be sent.
    NoUrl,
};

// What actually leaves the process: the method, the URL, the enabled headers and the body.
pub const Wire = struct {
    method: []const u8 = postman.default_method,
    url: []const u8 = "",
    headers: []const http_mod.Header = &.{},
    body: []const u8 = "",
};

// Everything the body assembly needs from outside: a `form-data` body has to name its own delimiter.
pub const BuildOptions = struct {
    // A random ASCII token in the app; a fixed one in a test, so the bytes can be compared.
    boundary: []const u8 = "kurir-boundary",
};

pub fn build(arena: Allocator, node: postman.Value, opts: BuildOptions) Failure!Wire {
    if (!postman.isRequest(node)) return error.NotARequest;
    const request = postman.requestView(arena, node) catch return error.NotARequest;
    if (request.url.len == 0) return error.NoUrl;

    var headers: std.ArrayList(http_mod.Header) = .empty;
    var has_content_type = false;
    for (request.headers) |header| {
        // Postman marks a header disabled; sending it anyway would be surprising.
        if (header.disabled or header.key.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(header.key, "content-type")) has_content_type = true;
        headers.append(arena, .{ .name = header.key, .value = header.value }) catch break;
    }

    const mode = modeOf(node, request);
    const body = bodyFor(arena, node, mode, opts) catch return error.NotARequest;
    // A mode with bytes of its own names their type, unless the request already said which type to use.
    if (!has_content_type and body.len > 0) {
        if (contentTypeFor(arena, mode, request.body_language, opts)) |value| {
            headers.append(arena, .{ .name = "Content-Type", .value = value }) catch {};
        }
    }
    return .{
        .method = request.method,
        .url = request.url,
        .headers = headers.items,
        .body = body,
    };
}

// The mode the document asks for; a body with raw text but NO mode at all is an old file, and it means raw.
fn modeOf(node: postman.Value, request: postman.RequestView) postman.BodyMode {
    if (request.body_mode.len == 0) return if (postman.bodyRawText(node).len > 0) .raw else .none;
    return postman.BodyMode.fromPostman(request.body_mode);
}

fn bodyFor(arena: Allocator, node: postman.Value, mode: postman.BodyMode, opts: BuildOptions) ![]const u8 {
    return switch (mode) {
        .none => "",
        // Read from the document, not from the view: an old file's raw text carries no mode beside it.
        .raw => postman.bodyRawText(node),
        .urlencoded => try urlencodedBody(arena, node),
        .formdata => try multipartBody(arena, node, opts.boundary),
    };
}

// `a=1&b=two+words`: the pairs Postman would put on the wire, with the disabled rows left out.
fn urlencodedBody(arena: Allocator, node: postman.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var i: usize = 0;
    while (i < postman.bodyPartCount(node)) : (i += 1) {
        const part = postman.bodyPart(node, i);
        if (part.disabled or part.key.len == 0) continue;
        if (!first) try out.append(arena, '&');
        first = false;
        try appendEncoded(arena, &out, part.key);
        try out.append(arena, '=');
        try appendEncoded(arena, &out, part.value);
    }
    return out.items;
}

// A form field is percent-encoded, except the unreserved characters, and a space is the `+` a form decoder expects.
fn appendEncoded(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (unreserved) {
            try out.append(arena, byte);
        } else if (byte == ' ') {
            try out.append(arena, '+');
        } else {
            try out.appendSlice(arena, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

// The multipart body a form-data request sends: one part per enabled row, then the closing delimiter.
fn multipartBody(arena: Allocator, node: postman.Value, boundary: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < postman.bodyPartCount(node)) : (i += 1) {
        const part = postman.bodyPart(node, i);
        if (part.disabled or part.key.len == 0) continue;
        try out.appendSlice(arena, "--");
        try out.appendSlice(arena, boundary);
        try out.appendSlice(arena, "\r\nContent-Disposition: form-data; name=\"");
        try out.appendSlice(arena, part.key);
        try out.appendSlice(arena, "\"\r\n\r\n");
        try out.appendSlice(arena, part.value);
        try out.appendSlice(arena, "\r\n");
    }
    try out.appendSlice(arena, "--");
    try out.appendSlice(arena, boundary);
    try out.appendSlice(arena, "--\r\n");
    return out.items;
}

// The Content-Type a mode implies, or null when it implies none (only `none` does).
fn contentTypeFor(arena: Allocator, mode: postman.BodyMode, language: []const u8, opts: BuildOptions) ?[]const u8 {
    return switch (mode) {
        .none => null,
        .raw => rawContentType(language),
        .urlencoded => "application/x-www-form-urlencoded",
        .formdata => std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{opts.boundary}) catch null,
    };
}

// The Content-Type a raw body's language implies; json is the default the app writes.
pub fn rawContentType(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "xml")) return "application/xml";
    if (std.mem.eql(u8, language, "html")) return "text/html";
    if (std.mem.eql(u8, language, "text")) return "text/plain";
    return "application/json";
}

pub fn send(arena: Allocator, transport: http_mod.Transport, wire: Wire) http_mod.Result {
    _ = arena;
    return transport.perform(.{
        .method = wire.method,
        .url = wire.url,
        .headers = wire.headers,
        .body = wire.body,
    });
}

const testing = std.testing;

test "a request with no URL is not sent, it is explained" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const node = try postman.newRequest(arena, "R", postman.default_method, "");
    try testing.expectError(error.NoUrl, build(arena, node, .{}));
}

test "a disabled header never leaves the process, and an empty key is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var node = try postman.newRequest(arena, "R", "POST", "https://api.test/charges");
    try postman.setHeaderKey(arena, &node, 0, "X-Off");
    try postman.setHeaderValue(arena, &node, 0, "1");
    try postman.setHeaderEnabled(arena, &node, 0, false);
    try postman.setHeaderKey(arena, &node, 1, "Accept");
    try postman.setHeaderValue(arena, &node, 1, "application/json");

    const wire = try build(arena, node, .{});
    try testing.expectEqualStrings("POST", wire.method);
    try testing.expectEqual(@as(usize, 1), wire.headers.len);
    try testing.expectEqualStrings("Accept", wire.headers[0].name);
}

test "a folder is not a request, so it never reaches a transport" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const folder = try postman.newFolder(arena, "F");
    try testing.expectError(error.NotARequest, build(arena, folder, .{}));
}

test "a none body sends no bytes and claims no type of its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var node = try postman.newRequest(arena, "R", "POST", "https://api.test/charges");
    try postman.setBodyMode(arena, &node, "none");

    const wire = try build(arena, node, .{});
    try testing.expectEqualStrings("", wire.body);
    try testing.expectEqual(@as(usize, 0), wire.headers.len);
}

test "a raw body sends its text and the type its language implies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var node = try postman.newRequest(arena, "R", "POST", "https://api.test/charges");
    try postman.setBodyRaw(arena, &node, "{\"amount\":100}");

    const wire = try build(arena, node, .{});
    try testing.expectEqualStrings("{\"amount\":100}", wire.body);
    try testing.expectEqual(@as(usize, 1), wire.headers.len);
    try testing.expectEqualStrings("Content-Type", wire.headers[0].name);
    try testing.expectEqualStrings("application/json", wire.headers[0].value);

    // XML is a different type, and a type the request already set is never replaced.
    try postman.setBodyLanguage(arena, &node, "xml");
    const xml = try build(arena, node, .{});
    try testing.expectEqualStrings("application/xml", xml.headers[0].value);

    try postman.setHeaderKey(arena, &node, 0, "content-type");
    try postman.setHeaderValue(arena, &node, 0, "application/vnd.api+json");
    const kept = try build(arena, node, .{});
    try testing.expectEqual(@as(usize, 1), kept.headers.len);
    try testing.expectEqualStrings("application/vnd.api+json", kept.headers[0].value);
}

test "a urlencoded body is the enabled rows, encoded, and the form type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var node = try postman.newRequest(arena, "R", "POST", "https://api.test/token");
    try postman.setBodyMode(arena, &node, "urlencoded");
    _ = try postman.addBodyPart(arena, &node);
    try postman.setBodyPartKey(arena, &node, 0, "grant_type");
    try postman.setBodyPartValue(arena, &node, 0, "client credentials");
    _ = try postman.addBodyPart(arena, &node);
    try postman.setBodyPartKey(arena, &node, 1, "scope");
    try postman.setBodyPartValue(arena, &node, 1, "read write");
    _ = try postman.addBodyPart(arena, &node);
    try postman.setBodyPartKey(arena, &node, 2, "off");
    try postman.setBodyPartValue(arena, &node, 2, "1");
    try postman.setBodyPartEnabled(arena, &node, 2, false);

    const wire = try build(arena, node, .{});
    // A space is the `+` a form decoder reads, and a disabled row is not sent.
    try testing.expectEqualStrings("grant_type=client+credentials&scope=read+write", wire.body);
    try testing.expectEqualStrings("application/x-www-form-urlencoded", wire.headers[0].value);
}

test "a form-data body is multipart, delimited by the boundary it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var node = try postman.newRequest(arena, "R", "POST", "https://api.test/upload");
    try postman.setBodyMode(arena, &node, "formdata");
    _ = try postman.addBodyPart(arena, &node);
    try postman.setBodyPartKey(arena, &node, 0, "name");
    try postman.setBodyPartValue(arena, &node, 0, "widget");

    const wire = try build(arena, node, .{ .boundary = "test-boundary" });
    try testing.expect(std.mem.startsWith(u8, wire.body, "--test-boundary\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nwidget\r\n"));
    try testing.expect(std.mem.endsWith(u8, wire.body, "--test-boundary--\r\n"));
    try testing.expectEqualStrings("multipart/form-data; boundary=test-boundary", wire.headers[0].value);
}

test "an old document with raw text and no mode still sends that text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const node = try postman.parseTree(arena, "{\"name\":\"R\",\"request\":{\"method\":\"POST\",\"url\":\"https://api.test/x\",\"body\":{\"raw\":\"{\\\"a\\\":1}\"}}}");
    const wire = try build(arena, node, .{});
    try testing.expectEqualStrings("{\"a\":1}", wire.body);
    try testing.expectEqual(@as(usize, 1), wire.headers.len);
}
