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

pub fn build(arena: Allocator, node: postman.Value) Failure!Wire {
    if (!postman.isRequest(node)) return error.NotARequest;
    const request = postman.requestView(arena, node) catch return error.NotARequest;
    if (request.url.len == 0) return error.NoUrl;

    var headers: std.ArrayList(http_mod.Header) = .empty;
    for (request.headers) |header| {
        // Postman marks a header disabled; sending it anyway would be surprising.
        if (header.disabled or header.key.len == 0) continue;
        headers.append(arena, .{ .name = header.key, .value = header.value }) catch break;
    }
    return .{
        .method = request.method,
        .url = request.url,
        .headers = headers.items,
        .body = request.body,
    };
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
