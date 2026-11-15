//! The response pane's ViewModel: the last result, the arena behind it, and the two views it can show.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const state_mod = @import("../../state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Session = session_mod.Session;
const Value = postman.Value;

// A response bigger than this is cut before it is drawn: the body is a text run, not a download.
pub const max_response_bytes: usize = 256 * 1024;

pub const Response = struct {
    session: *Session = undefined,

    // The last response and everything it points at.
    arena_state: std.heap.ArenaAllocator = undefined,
    view: state_mod.ResponseView = .{},
    tab: state_mod.Tab = .body,

    pub fn start(self: *Response, session: *Session) void {
        self.session = session;
        self.arena_state = std.heap.ArenaAllocator.init(session.gpa);
    }

    pub fn deinit(self: *Response) void {
        self.arena_state.deinit();
    }

    // A response body, pretty-printed or not: what the pane draws, and how many lines were cut.
    pub const Pretty = struct {
        text: []const u8 = "",
        truncated_lines: usize = 0,
    };

    pub fn begin(self: *Response) Allocator {
        _ = self.arena_state.reset(.retain_capacity);
        return self.arena_state.allocator();
    }

    pub fn setTab(self: *Response, tab: state_mod.Tab) void {
        self.tab = tab;
        self.session.touch();
    }

    // The pane's slice of the frame.
    pub fn snapshot(self: *Response, u: *UiState) void {
        u.response = self.view;
        u.response_tab = self.tab;
    }

    pub fn store(self: *Response, arena: Allocator, result: http_mod.Result) void {
        var response = state_mod.ResponseView{};
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        var status_buf: [64]u8 = undefined;

        response.time_ms = result.time_ms;
        response.time_text = arena.dupe(u8, state_mod.timeLabel(&time_buf, result.time_ms)) catch "";
        response.size = result.sizes();
        response.size_text = arena.dupe(u8, state_mod.sizeLabel(&size_buf, result.sizes())) catch "";

        if (result.failed) {
            response.kind = .failed;
            response.error_title = arena.dupe(u8, result.error_title) catch "";
            response.error_message = arena.dupe(u8, result.error_message) catch "";
            self.view = response;
            self.session.setStatus(true, "Request failed: {s}", .{result.error_title});
            return;
        }

        response.kind = .ok;
        response.status = result.status;
        response.status_text = arena.dupe(u8, state_mod.statusLabel(&status_buf, result.status, result.reason)) catch "";
        const shown = pretty(arena, result.body);
        response.body = shown.text;
        response.truncated_lines = shown.truncated_lines;

        var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
        for (result.headers) |header| {
            header_rows.append(arena, .{ .name = header.name, .value = header.value }) catch break;
        }
        response.headers = header_rows.toOwnedSlice(arena) catch &.{};
        self.view = response;
        self.session.setStatus(false, "{d} {s} · {s} · {s}", .{ result.status, result.reason, response.time_text, response.size_text });
    }

    pub fn pretty(arena: Allocator, body: []const u8) Pretty {
        const capped = if (body.len > max_response_bytes) body[0..max_response_bytes] else body;
        const parsed = std.json.parseFromSliceLeaky(Value, arena, capped, .{}) catch
            return .{ .text = sanitize(arena, capped), .truncated_lines = if (body.len > capped.len) 1 else 0 };
        const text = postman.write(arena, parsed, true) catch
            return .{ .text = sanitize(arena, capped), .truncated_lines = if (body.len > capped.len) 1 else 0 };
        return .{ .text = sanitize(arena, text) };
    }

    pub fn sanitize(arena: Allocator, bytes: []const u8) []const u8 {
        const out = arena.alloc(u8, bytes.len) catch return "";
        for (bytes, 0..) |byte, i| {
            out[i] = if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) byte else 0xb7;
        }
        return out;
    }
};

const testing = std.testing;

test "a JSON body reads as a document, and a body that is not JSON is shown as it arrived" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pretty = Response.pretty(arena, "{\"a\":1}");
    try testing.expect(std.mem.indexOfScalar(u8, pretty.text, '\n') != null);
    const plain = Response.pretty(arena, "hello");
    try testing.expectEqualStrings("hello", plain.text);
}

test "a byte a font cannot draw becomes a middle dot, so a binary body never breaks the run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualSlices(u8, &.{ 'a', 0xb7, 'b' }, Response.sanitize(arena, "a\x00b"));
    try testing.expectEqualStrings("a\nb\tc", Response.sanitize(arena, "a\nb\tc"));
}
