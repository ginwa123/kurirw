//! The HTTP layer: one injectable transport, a real kabelweb client, and a fake so tests never touch the network.
const std = @import("std");
const glinlandui = @import("glinlandui");
const kabelweb = @import("kabelweb");
const postman = @import("../model/postman.zig");

const Ctx = glinlandui.Ctx;

pub const Allocator = std.mem.Allocator;
pub const client = kabelweb.client;

// A request a person would wait for is a request with a deadline; a hung server must not hang the window.
pub const default_timeout_ms: u32 = 15_000;
pub const max_url: usize = 4096;

pub const Header = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const Request = struct {
    method: []const u8 = postman.default_method,
    url: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u32 = default_timeout_ms,
};

pub const Result = struct {
    status: u16 = 0,
    reason: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
    time_ms: u64 = 0,
    failed: bool = false,
    // A short headline and a sentence that says what to do about it.
    error_title: []const u8 = "",
    error_message: []const u8 = "",

    pub fn sizes(self: Result) usize {
        return self.body.len;
    }
};

// The one seam a test replaces. `arena` owns everything the Result points at.
pub const Transport = struct {
    ctx: Ctx = Ctx.none,
    arena: Allocator,
    send_fn: *const fn (Ctx, Allocator, Request) Result,

    pub fn perform(self: Transport, req: Request) Result {
        return self.send_fn(self.ctx, self.arena, req);
    }
};

// The reason phrase a status line carries, for the handful of codes a client sees every day.
pub fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        418 => "I'm a teapot",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

// A failure that never reached a transport: no URL, nothing to send.
fn reject(arena: Allocator, title: []const u8, message: []const u8) Result {
    return .{ .failed = true, .error_title = title, .error_message = arena.dupe(u8, message) catch "" };
}

// ---- the real transport --------------------------------------------------------------------------------------

pub const Real = struct {
    allocator: Allocator,
    http: client.Client,

    pub fn init(allocator: Allocator) Real {
        return .{ .allocator = allocator, .http = client.Client.init(allocator) };
    }

    pub fn deinit(self: *Real) void {
        self.http.deinit();
    }

    pub fn transport(self: *Real, arena: Allocator) Transport {
        return .{ .ctx = Ctx.from(self), .arena = arena, .send_fn = sendReal };
    }

    fn sendReal(ctx: Ctx, arena: Allocator, req: Request) Result {
        const self = ctx.get(Real);

        var url_buffer: [max_url]u8 = undefined;
        const url = postman.effectiveUrl(&url_buffer, req.url);
        if (url.len == 0) {
            return reject(arena, "No URL", "Type a URL before sending, for example https://api.example.com/v1/items.");
        }
        const method = client.Method.parse(req.method) orelse .GET;

        var headers: std.ArrayList(client.Header) = .empty;
        for (req.headers) |header| {
            if (header.name.len == 0) continue;
            headers.append(arena, .{ .name = header.name, .value = header.value }) catch
                return reject(arena, "Out of memory", "Kurir could not build the request headers.");
        }

        var response = self.http.perform(.{
            .method = method,
            .url = url,
            .headers = headers.items,
            .body = if (req.body.len > 0) req.body else null,
        }, .{
            .timeout_ms = req.timeout_ms,
            .connect_timeout_ms = req.timeout_ms,
            .follow_redirects = true,
            .user_agent = "kurir/0.1",
            // The client's default is a 10 MiB buffer; Kurir asks for the whole answer instead.
            .max_body_bytes = null,
        }) catch |err| return failFor(arena, err, req, url);
        defer response.deinit(self.allocator);

        var out = Result{
            .status = response.status_code,
            .reason = reasonPhrase(response.status_code),
            .time_ms = response.total_time_ms,
            .body = arena.dupe(u8, response.body) catch "",
        };
        var copies: std.ArrayList(Header) = .empty;
        for (response.headers) |header| {
            copies.append(arena, .{
                .name = arena.dupe(u8, header.name) catch "",
                .value = arena.dupe(u8, header.value) catch "",
            }) catch break;
        }
        out.headers = copies.toOwnedSlice(arena) catch &.{};
        return out;
    }

    // Every transport error becomes a headline plus the sentence that tells the user what to fix.
    fn failFor(arena: Allocator, err: anyerror, req: Request, url: []const u8) Result {
        const name = @errorName(err);
        var out = Result{ .failed = true };
        if (std.mem.eql(u8, name, "ConnectionRefused")) {
            out.error_title = "Connection refused";
            out.error_message = print(arena, "Nothing is listening at {s}. Start the server, or fix the host and port.", .{url});
        } else if (std.mem.eql(u8, name, "DnsError")) {
            out.error_title = "Host not found";
            out.error_message = print(arena, "The host in {s} could not be resolved. Check the spelling and your network.", .{url});
        } else if (std.mem.eql(u8, name, "OperationTimedOut") or std.mem.eql(u8, name, "ConnectionTimeout")) {
            out.error_title = "Request timed out";
            out.error_message = print(arena, "{s} {s} did not answer within {d} ms. Raise the timeout, or check the server.", .{ req.method, url, req.timeout_ms });
        } else if (std.mem.eql(u8, name, "TlsError")) {
            out.error_title = "TLS handshake failed";
            out.error_message = print(arena, "The certificate for {s} is not trusted. Fix the certificate, or use http for a local server.", .{url});
        } else if (std.mem.eql(u8, name, "InvalidUrl") or std.mem.eql(u8, name, "UriMissingHost") or std.mem.eql(u8, name, "UnsupportedProtocol")) {
            out.error_title = "Invalid URL";
            out.error_message = print(arena, "\"{s}\" is not a URL Kurir can send. It needs http or https and a host, for example https://api.example.com/v1.", .{url});
        } else if (std.mem.eql(u8, name, "OutOfMemory")) {
            out.error_title = "Out of memory";
            out.error_message = print(arena, "Kurir could not buffer this response: the machine ran out of memory while the body was arriving.", .{});
        } else if (std.mem.eql(u8, name, "RecvError") or std.mem.eql(u8, name, "SendError") or std.mem.eql(u8, name, "PartialFile")) {
            out.error_title = "Connection dropped";
            out.error_message = print(arena, "The server closed the connection during {s} {s}. Send again, and check the server log.", .{ req.method, url });
        } else {
            out.error_title = "Request failed";
            out.error_message = print(arena, "{s} {s} failed: {s}.", .{ req.method, url, name });
        }
        return out;
    }

    fn print(arena: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(arena, fmt, args) catch "";
    }
};

// ---- the fake transport --------------------------------------------------------------------------------------

// A transport that answers from a recording instead of a socket, so the suite is offline and deterministic.
pub const Fake = struct {
    arena: Allocator,
    status: u16 = 200,
    body: []const u8 = "{\"ok\":true}",
    headers: []const Header = &.{},
    time_ms: u64 = 11,
    // "" answers with the recorded response; any other value fails with an error of that name.
    failure_name: []const u8 = "",
    // A slow server: the fake sleeps this long before answering, so a test can watch the app while it waits.
    delay_ms: u32 = 0,
    io: ?std.Io = null,

    sends: usize = 0,
    last_method: []const u8 = "",
    last_url: []const u8 = "",
    last_body: []const u8 = "",
    last_header_count: usize = 0,
    last_timeout_ms: u32 = 0,

    pub fn init(arena: Allocator) Fake {
        return .{ .arena = arena };
    }

    pub fn transport(self: *Fake) Transport {
        return .{ .ctx = Ctx.from(self), .arena = self.arena, .send_fn = sendFake };
    }

    // What the last request looked like, once the fake has answered it.
    pub fn reset(self: *Fake) void {
        self.sends = 0;
        self.last_method = "";
        self.last_url = "";
        self.last_body = "";
        self.last_header_count = 0;
        self.last_timeout_ms = 0;
    }

    fn sendFake(ctx: Ctx, arena: Allocator, req: Request) Result {
        const self = ctx.get(Fake);
        if (self.delay_ms > 0) {
            if (self.io) |io| std.Io.sleep(io, .fromMilliseconds(self.delay_ms), .awake) catch {};
        }
        self.sends += 1;
        self.last_method = arena.dupe(u8, req.method) catch "";
        self.last_url = arena.dupe(u8, req.url) catch "";
        self.last_body = arena.dupe(u8, req.body) catch "";
        self.last_header_count = req.headers.len;
        self.last_timeout_ms = req.timeout_ms;

        if (self.failure_name.len > 0) {
            return .{
                .failed = true,
                .error_title = self.failure_name,
                .error_message = std.fmt.allocPrint(arena, "{s} {s} failed with {s}.", .{ req.method, req.url, self.failure_name }) catch "",
            };
        }
        return .{
            .status = self.status,
            .reason = reasonPhrase(self.status),
            .time_ms = self.time_ms,
            .body = arena.dupe(u8, self.body) catch "",
            .headers = self.headers,
        };
    }
};

// The transport used when nothing else is installed: it answers instead of reaching the network.
pub fn sendOffline(_: Ctx, arena: Allocator, req: Request) Result {
    _ = req;
    return .{
        .failed = true,
        .error_title = "No transport",
        .error_message = arena.dupe(u8, "Kurir has no HTTP transport installed, so this request was not sent.") catch "",
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------

fn headerList(arena: Allocator) ![]const Header {
    var list: std.ArrayList(Header) = .empty;
    try list.append(arena, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(arena, .{ .name = "Accept", .value = "application/json" });
    return list.toOwnedSlice(arena);
}

test "the fake records the request and answers with the recording" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = Fake.init(arena);
    fake.status = 201;
    fake.body = "{\"id\":7}";
    const headers = try headerList(arena);

    const result = fake.transport().perform(.{
        .method = "POST",
        .url = "https://api.example.com/v1/charges",
        .headers = headers,
        .body = "{\"amount\":100}",
    });

    try std.testing.expect(!result.failed);
    try std.testing.expectEqual(@as(u16, 201), result.status);
    try std.testing.expectEqualStrings("Created", result.reason);
    try std.testing.expectEqualStrings("{\"id\":7}", result.body);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try std.testing.expectEqualStrings("POST", fake.last_method);
    try std.testing.expectEqualStrings("https://api.example.com/v1/charges", fake.last_url);
    try std.testing.expectEqualStrings("{\"amount\":100}", fake.last_body);
    try std.testing.expectEqual(@as(usize, 2), fake.last_header_count);
    try std.testing.expectEqual(default_timeout_ms, fake.last_timeout_ms);
}

test "the fake can fail, and the failure carries a sentence the banner can show" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = Fake.init(arena);
    fake.failure_name = "ConnectionRefused";

    const result = fake.transport().perform(.{ .method = "GET", .url = "http://127.0.0.1:1/" });
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("ConnectionRefused", result.error_title);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message, "127.0.0.1") != null);
}

test "an empty URL never reaches a transport, so a blank field explains itself" {
    var real = Real.init(std.testing.allocator);
    defer real.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = real.transport(arena).perform(.{ .url = "   " });
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("No URL", result.error_title);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message, "Type a URL") != null);
}

test "a status code maps to its reason phrase, and an unknown code keeps an empty one" {
    try std.testing.expectEqualStrings("OK", reasonPhrase(200));
    try std.testing.expectEqualStrings("Not Found", reasonPhrase(404));
    try std.testing.expectEqualStrings("Internal Server Error", reasonPhrase(500));
    try std.testing.expectEqualStrings("", reasonPhrase(599));
}
