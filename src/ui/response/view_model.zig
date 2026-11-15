//! The response pane's ViewModel: one last result PER endpoint, and the two views it can show.
const std = @import("std");

const postman = @import("../../data/model/postman.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const state_mod = @import("../../ui/state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Session = session_mod.Session;
const Value = postman.Value;
const Path = state_mod.Path;

// A response bigger than this is cut before it is drawn: the body is a text run, not a download.
pub const max_response_bytes: usize = 256 * 1024;

// How many endpoints keep their last result in memory. One body is capped at 256 KiB, so this bounds it.
pub const max_cached: usize = 24;

// What a result belongs to: an endpoint is its path inside its workspace.
pub const Key = struct {
    workspace: usize = 0,
    path: Path = .{},

    pub fn eql(a: Key, b: Key) bool {
        return a.workspace == b.workspace and Path.eql(a.path, b.path);
    }
};

// One endpoint's result. Boxed, because the arena must not move once an allocator has been handed out.
const Entry = struct {
    key: Key,
    arena: std.heap.ArenaAllocator,
    view: state_mod.ResponseView = .{},
};

// A send: the endpoint the result belongs to, and the arena it may use.
pub const Slot = struct {
    key: Key,
    arena: Allocator,
};

pub const Response = struct {
    session: *Session = undefined,
    // One result per endpoint, oldest first, bounded by `max_cached`.
    entries: std.ArrayList(*Entry) = .empty,
    tab: state_mod.Tab = .body,

    pub fn start(self: *Response, session: *Session) void {
        self.session = session;
    }

    pub fn deinit(self: *Response) void {
        self.forgetAll();
        self.entries.deinit(self.session.gpa);
    }

    pub fn setTab(self: *Response, tab: state_mod.Tab) void {
        self.tab = tab;
        self.session.touch();
    }

    // The pane is derived from the selection: an endpoint shows the last result IT got, never a neighbour's.
    pub fn snapshot(self: *Response, u: *UiState) void {
        u.response = if (self.keyNow()) |key| (if (self.entryFor(key)) |found| found.view else .{}) else .{};
        u.response_tab = self.tab;
    }

    // A send begins: the endpoint's arena, reset, plus the key the result will be stored under.
    pub fn begin(self: *Response) ?Slot {
        const key = self.keyNow() orelse return null;
        const entry = self.entryFor(key) orelse self.create(key) orelse return null;
        _ = entry.arena.reset(.retain_capacity);
        return .{ .key = key, .arena = entry.arena.allocator() };
    }

    pub fn store(self: *Response, slot: Slot, result: http_mod.Result) void {
        const entry = self.entryFor(slot.key) orelse return;
        const arena = slot.arena;

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
            entry.view = response;
            self.session.setStatus(true, "Request failed: {s}", .{result.error_title});
            self.session.touch();
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
        entry.view = response;
        self.session.setStatus(false, "{d} {s} · {s} · {s}", .{ result.status, result.reason, response.time_text, response.size_text });
        self.session.touch();
    }

    // A node was deleted, so a path can now address a different endpoint: no result survives that.
    pub fn forgetAll(self: *Response) void {
        const gpa = self.session.gpa;
        for (self.entries.items) |entry| {
            entry.arena.deinit();
            gpa.destroy(entry);
        }
        self.entries.clearRetainingCapacity();
    }

    fn keyNow(self: *Response) ?Key {
        const path = self.session.selection orelse return null;
        if (path.depth == 0) return null;
        return .{ .workspace = self.session.workspace, .path = path };
    }

    fn entryFor(self: *Response, key: Key) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.key.eql(key)) return entry;
        }
        return null;
    }

    fn create(self: *Response, key: Key) ?*Entry {
        const gpa = self.session.gpa;
        // Oldest first: a full cache drops the result that has been on screen longest.
        if (self.entries.items.len >= max_cached) {
            const old = self.entries.orderedRemove(0);
            old.arena.deinit();
            gpa.destroy(old);
        }
        const entry = gpa.create(Entry) catch return null;
        entry.* = .{ .key = key, .arena = std.heap.ArenaAllocator.init(gpa) };
        self.entries.append(gpa, entry) catch {
            entry.arena.deinit();
            gpa.destroy(entry);
            return null;
        };
        return entry;
    }

    // A response body, pretty-printed or not: what the pane draws, and how many lines were cut.
    pub const Pretty = struct {
        text: []const u8 = "",
        truncated_lines: usize = 0,
    };

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

test "a key is the endpoint AND its workspace, so two workspaces never share a result" {
    const one = Key{ .workspace = 0, .path = Path.empty.child(0).child(1) };
    const same = Key{ .workspace = 0, .path = Path.empty.child(0).child(1) };
    const other_workspace = Key{ .workspace = 1, .path = Path.empty.child(0).child(1) };
    const other_path = Key{ .workspace = 0, .path = Path.empty.child(0).child(2) };

    try testing.expect(one.eql(same));
    try testing.expect(!one.eql(other_workspace));
    try testing.expect(!one.eql(other_path));
}
