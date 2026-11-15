//! The response pane's ViewModel: one last result PER endpoint, and what the body view needs to draw it.
const std = @import("std");
const glinlandui = @import("glinlandui");
const scroll_mod = glinlandui.components.scroll;
const input_mod = glinlandui.components.input;

const postman = @import("../../data/model/postman.zig");
const body_mod = @import("../../data/model/body.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const state_mod = @import("../../ui/state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Session = session_mod.Session;
const Path = state_mod.Path;

// The body scroll container, and the height of one drawn line. The pane declares only the lines inside it.
pub const body_scroll_id = "kurir.response.body";
pub const body_text_id = "kurir.response.body.text";

// The bodies are not capped, so the cache is bounded in BYTES: a few megabyte answers fit, twenty do not.
pub const max_cached: usize = 24;
pub const max_cached_bytes: usize = 32 * 1024 * 1024;

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

pub const Response = struct {
    session: *Session = undefined,
    // One result per endpoint, oldest first, bounded by `max_cached` and `max_cached_bytes`.
    entries: std.ArrayList(*Entry) = .empty,
    tab: state_mod.Tab = .body,
    // The body itself: one read-only multiline field, so a response can be selected and copied like any text.
    body_field: input_mod.Field = undefined,

    pub fn start(self: *Response, session: *Session) void {
        self.session = session;
        self.body_field = session.fieldStyle(.{ .text = body_text_id }, @src());
        self.body_field.multiline = true;
        // Read-only: a response is something you read, select and copy — never something you type into.
        self.body_field.readonly = true;
        self.body_field.scroll_id = body_scroll_id;
        self.body_field.pad = glinlandui.props.Pad.all(10);
        // The pane already draws the frame around the body: the field itself is seamless, so the text is the content.
        self.body_field.border = .{};
        self.body_field.radius = glinlandui.props.Radius.all(0);
        self.body_field.h = .{ .fixed = 30 };
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

    // A send begins: the endpoint the answer will belong to.
    pub fn begin(self: *Response) ?Key {
        const key = self.keyNow() orelse return null;
        _ = self.entryFor(key) orelse self.create(key) orelse return null;
        return key;
    }

    // The arena is reset HERE: while the request is in flight the pane still shows the previous result.
    pub fn store(self: *Response, key: Key, result: http_mod.Result, shown: body_mod.Shown) void {
        const entry = self.entryFor(key) orelse return;
        _ = entry.arena.reset(.retain_capacity);
        const arena = entry.arena.allocator();

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
            self.evictOverBudget(entry);
            return;
        }

        response.kind = .ok;
        response.status = result.status;
        response.status_text = arena.dupe(u8, state_mod.statusLabel(&status_buf, result.status, result.reason)) catch "";
        // The body is copied whole: no cap, and the line index travels with it so the pane can draw one line.
        response.body = arena.dupe(u8, shown.text) catch "";
        response.lines = arena.dupe(usize, shown.lines) catch &.{};

        var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
        for (result.headers) |header| {
            // Copied, not borrowed: the answer's strings die with the job that fetched it.
            const name = arena.dupe(u8, header.name) catch break;
            const value = arena.dupe(u8, header.value) catch break;
            header_rows.append(arena, .{ .name = name, .value = value }) catch break;
        }
        response.headers = header_rows.toOwnedSlice(arena) catch &.{};
        entry.view = response;
        self.session.setStatus(false, "{d} {s} · {s} · {s}", .{ result.status, result.reason, response.time_text, response.size_text });
        self.session.touch();
        self.evictOverBudget(entry);
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
        const entry = gpa.create(Entry) catch return null;
        entry.* = .{ .key = key, .arena = std.heap.ArenaAllocator.init(gpa) };
        self.entries.append(gpa, entry) catch {
            entry.arena.deinit();
            gpa.destroy(entry);
            return null;
        };
        return entry;
    }

    // Keep the cache inside its byte budget by dropping the oldest results, never the one just stored.
    fn evictOverBudget(self: *Response, keep: *Entry) void {
        const gpa = self.session.gpa;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items.len <= 1 or self.totalBytes() <= max_cached_bytes) return;
            const candidate = self.entries.items[i];
            if (candidate == keep) {
                i += 1;
                continue;
            }
            _ = self.entries.orderedRemove(i);
            candidate.arena.deinit();
            gpa.destroy(candidate);
        }
    }

    fn totalBytes(self: *Response) usize {
        var sum: usize = 0;
        for (self.entries.items) |entry| {
            sum += entry.view.body.len + entry.view.lines.len * @sizeOf(usize);
        }
        return sum;
    }
};

const testing = std.testing;

test "a key is the endpoint AND its workspace, so two workspaces never share a result" {
    const one = Key{ .workspace = 0, .path = Path.empty.child(0).child(1) };
    const same = Key{ .workspace = 0, .path = Path.empty.child(0).child(1) };
    const other_workspace = Key{ .workspace = 1, .path = Path.empty.child(0).child(1) };
    const other_path = Key{ .workspace = 0, .path = Path.empty.child(0).child(2) };

    try testing.expect(one.eql(same));
    try testing.expect(!one.eql(other_workspace));
    try testing.expect(!one.eql(other_path));
}
