//! The response pane's ViewModel: the last `max_history` results, the one on screen, and the body view.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Field = glinlandui.components.input.Field;

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
pub const history_scroll_id = "kurir.response.history";
pub const history_row_prefix = "kurir.response.history.row";

// The bodies are not capped, so the history is bounded in ENTRIES and in BYTES: a few megabyte answers fit, twenty do not.
pub const max_history: usize = state_mod.max_history;
pub const max_history_bytes: usize = 32 * 1024 * 1024;

// What a result belongs to: an endpoint is its path inside its workspace.
pub const Key = struct {
    workspace: usize = 0,
    path: Path = .{},

    pub fn eql(a: Key, b: Key) bool {
        return a.workspace == b.workspace and Path.eql(a.path, b.path);
    }
};

// What the send was, captured when it started: the row's label, and the endpoint it belongs to.
pub const Meta = struct {
    method: []const u8 = postman.default_method,
    name: []const u8 = "",
    url: []const u8 = "",
};

// One past result. Boxed, because the arena must not move once an allocator has been handed out.
const Entry = struct {
    // Stable across eviction: a click that was registered last frame finds its result by this, not by index.
    serial: u64 = 0,
    key: Key = .{},
    method: []const u8 = "",
    name: []const u8 = "",
    at_ns: i96 = 0,
    arena: std.heap.ArenaAllocator,
    view: state_mod.ResponseView = .{},
};

pub const Response = struct {
    session: *Session = undefined,
    // Every result this session has seen, oldest first and newest last, bounded by `max_history`.
    entries: std.ArrayList(*Entry) = .empty,
    next_serial: u64 = 1,
    // The result on screen when it is not the newest one for the selection; zero means "the latest".
    pinned: u64 = 0,
    tab: state_mod.ResponseTab = .body,
    // The body itself: one read-only multiline field, so a response can be selected and copied like any text.
    body_field: Field = undefined,

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
        // And no focus ring either: an outline around a page of printed JSON reads as a defect, and the caret shows the focus.
        self.body_field.focus_ring_w = .{ .px = 0 };
        self.body_field.radius = glinlandui.props.Radius.all(0);
        self.body_field.h = .{ .fixed = 30 };
    }

    pub fn deinit(self: *Response) void {
        self.forgetAll();
        self.entries.deinit(self.session.gpa);
    }

    pub fn setTab(self: *Response, tab: state_mod.ResponseTab) void {
        self.tab = tab;
        self.session.touch();
    }

    // The pane is derived from the selection: an endpoint shows the last result IT got, never a neighbour's.
    pub fn snapshot(self: *Response, u: *UiState, arena: Allocator) void {
        const current = self.keyNow();
        const entry = self.entryOnScreen(current);
        u.response = if (entry) |found| found.view else .{};
        u.response_tab = self.tab;
        u.response_pinned = self.pinned != 0 and entry != null;
        u.history = self.buildRows(arena);
    }

    // A send begins: the endpoint the answer will belong to.
    pub fn begin(self: *Response) ?Key {
        return self.keyNow();
    }

    // The answer lands: a NEW entry, because the previous answer for this endpoint is history now.
    pub fn store(self: *Response, key: Key, meta: Meta, result: http_mod.Result, shown: body_mod.Shown) void {
        const entry = self.create() orelse return;
        const arena = entry.arena.allocator();
        entry.key = key;
        entry.serial = self.next_serial;
        self.next_serial += 1;
        entry.method = arena.dupe(u8, meta.method) catch "";
        entry.name = arena.dupe(u8, meta.name) catch "";
        entry.at_ns = std.Io.Timestamp.now(self.session.io, .real).nanoseconds;

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
            // A fresh answer always becomes the one on screen: the pane shows the latest, never a stale pin.
            self.pinned = 0;
            self.session.setStatus(true, "Request failed: {s}", .{result.error_title});
            self.evict(entry);
            self.session.touch();
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
        self.pinned = 0;
        self.session.setStatus(false, "{d} {s} · {s} · {s}", .{ result.status, result.reason, response.time_text, response.size_text });
        self.evict(entry);
        self.session.touch();
    }

    // A history row was clicked: show that result, and keep showing it until a send or a selection moves on.
    pub fn pin(self: *Response, serial: u64) void {
        if (self.bySerial(serial) == null) return;
        self.pinned = serial;
        self.tab = .body;
        self.session.touch();
    }

    // Back to the newest result for the selection.
    pub fn clearPin(self: *Response) void {
        if (self.pinned == 0) return;
        self.pinned = 0;
        self.session.touch();
    }

    // The endpoint a serial belongs to, so the shell can select the request a history row names.
    pub fn keyFor(self: *Response, serial: u64) ?Key {
        const entry = self.bySerial(serial) orelse return null;
        return entry.key;
    }

    // A node was deleted, so a path can now address a different endpoint: no result survives that.
    pub fn forgetAll(self: *Response) void {
        for (self.entries.items) |entry| self.destroy(entry);
        self.entries.clearRetainingCapacity();
        self.pinned = 0;
    }

    // The result the pane draws: the pinned one, else the newest one for the selection.
    fn entryOnScreen(self: *Response, current: ?Key) ?*Entry {
        if (self.pinned != 0) {
            if (self.bySerial(self.pinned)) |found| return found;
            self.pinned = 0;
        }
        const key = current orelse return null;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].key.eql(key)) return self.entries.items[i];
        }
        return null;
    }

    fn buildRows(self: *Response, arena: Allocator) []const state_mod.HistoryRow {
        var rows: std.ArrayList(state_mod.HistoryRow) = .empty;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            // Only the results of the workspace on screen: a row must resolve to a request you can select.
            if (entry.key.workspace != self.session.workspace) continue;
            if (rows.items.len >= max_history) break;
            var age_buf: [16]u8 = undefined;
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{s} · {s} · {s}", .{
                entry.view.time_text,
                entry.view.size_text,
                state_mod.ageLabel(&age_buf, self.ageMs(entry)),
            }) catch "";
            const row = state_mod.HistoryRow{
                .serial = entry.serial,
                .method = entry.method,
                .name = clip(arena, entry.name),
                .status = clip(arena, if (entry.view.kind == .failed) entry.view.error_title else entry.view.status_text),
                .detail = arena.dupe(u8, detail) catch "",
                .failed = entry.view.kind == .failed,
                .pinned = entry.serial == self.pinned,
            };
            rows.append(arena, row) catch break;
        }
        return rows.toOwnedSlice(arena) catch &.{};
    }

    // How long ago the result landed, in whole milliseconds; a clock that jumped back reads as "now".
    fn ageMs(self: *Response, entry: *Entry) u64 {
        const now = std.Io.Timestamp.now(self.session.io, .real).nanoseconds;
        const delta = now - entry.at_ns;
        if (delta <= 0) return 0;
        return @intCast(@divTrunc(delta, 1_000_000));
    }

    fn keyNow(self: *Response) ?Key {
        const path = self.session.selection orelse return null;
        if (path.depth == 0) return null;
        return .{ .workspace = self.session.workspace, .path = path };
    }

    fn bySerial(self: *Response, serial: u64) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.serial == serial) return entry;
        }
        return null;
    }

    fn create(self: *Response) ?*Entry {
        const gpa = self.session.gpa;
        const entry = gpa.create(Entry) catch return null;
        entry.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        self.entries.append(gpa, entry) catch {
            entry.arena.deinit();
            gpa.destroy(entry);
            return null;
        };
        return entry;
    }

    fn destroy(self: *Response, entry: *Entry) void {
        entry.arena.deinit();
        self.session.gpa.destroy(entry);
    }

    // Keep the history inside its entry cap and its byte budget by dropping the oldest, never the one just stored.
    fn evict(self: *Response, keep: *Entry) void {
        while (self.entries.items.len > max_history) self.dropOldest(keep);
        while (self.entries.items.len > 1 and self.totalBytes() > max_history_bytes) self.dropOldest(keep);
    }

    fn dropOldest(self: *Response, keep: *Entry) void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const candidate = self.entries.items[i];
            if (candidate == keep) continue;
            _ = self.entries.orderedRemove(i);
            if (self.pinned == candidate.serial) self.pinned = 0;
            self.destroy(candidate);
            return;
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

// A row's text is cut at a character boundary, so a long name never widens the pane past its edge.
fn clip(arena: Allocator, text: []const u8) []const u8 {
    if (text.len <= 48) return text;
    var end: usize = 48;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return arena.dupe(u8, text[0..end]) catch "";
}

const testing = std.testing;

// A session with nothing but the allocator and the clock, which is all a store needs.
fn testSession() Session {
    var session = Session{};
    session.gpa = testing.allocator;
    session.io = testing.io;
    return session;
}

fn okResult(arena: Allocator, status: u16, body: []const u8) http_mod.Result {
    return .{ .status = status, .reason = "OK", .body = arena.dupe(u8, body) catch "", .time_ms = 7 };
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

test "the history keeps the newest twenty results and drops the oldest" {
    var session = testSession();
    var response = Response{};
    response.start(&session);
    defer response.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = Key{ .workspace = 0, .path = Path.empty.child(0) };
    var i: usize = 0;
    while (i < max_history + 5) : (i += 1) {
        const label = std.fmt.allocPrint(arena, "R{d}", .{i}) catch @panic("out of memory naming a test result");
        response.store(key, .{ .method = "GET", .name = label, .url = "https://api.test/x" }, okResult(arena, 200, "ok"), .{ .text = "ok", .lines = &.{ 0, 2 } });
    }

    try testing.expectEqual(max_history, response.entries.items.len);
    // The newest one is last, and the five first sends are gone.
    try testing.expectEqualStrings("R24", response.entries.items[max_history - 1].name);
    try testing.expectEqualStrings("R5", response.entries.items[0].name);
    // A send always lands on the newest result.
    var u = UiState{};
    session.selection = Path.empty.child(0);
    response.snapshot(&u, arena);
    try testing.expectEqual(state_mod.ResponseKind.ok, u.response.kind);
    try testing.expectEqual(max_history, u.history.len);
    // Newest first, and each row carries the serial its click needs.
    try testing.expectEqualStrings("R24", u.history[0].name);
    try testing.expect(u.history[0].serial > u.history[1].serial);
}

test "a pinned result stays on screen until a send moves it" {
    var session = testSession();
    var response = Response{};
    response.start(&session);
    defer response.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = Key{ .workspace = 0, .path = Path.empty.child(0) };
    response.store(key, .{ .method = "GET", .name = "first" }, okResult(arena, 200, "first body"), .{ .text = "first body", .lines = &.{ 0, 10 } });
    const first_serial = response.entries.items[0].serial;
    response.store(key, .{ .method = "POST", .name = "second" }, okResult(arena, 201, "second body"), .{ .text = "second body", .lines = &.{ 0, 11 } });

    session.selection = Path.empty.child(0);
    var u = UiState{};
    response.snapshot(&u, arena);
    try testing.expectEqualStrings("second body", u.response.body);
    try testing.expect(!u.response_pinned);

    // An old row pins its own result, and the list says which one is on screen.
    response.pin(first_serial);
    response.snapshot(&u, arena);
    try testing.expect(u.response_pinned);
    try testing.expectEqualStrings("first body", u.response.body);
    try testing.expect(u.history[1].pinned);
    try testing.expect(!u.history[0].pinned);
    try testing.expectEqual(state_mod.ResponseTab.body, response.tab);

    // Sending again is what unpins: the newest answer is the one a person asked for.
    response.store(key, .{ .method = "GET", .name = "third" }, okResult(arena, 200, "third body"), .{ .text = "third body", .lines = &.{ 0, 10 } });
    response.snapshot(&u, arena);
    try testing.expect(!u.response_pinned);
    try testing.expectEqualStrings("third body", u.response.body);

    // A selection change clears it too, so another endpoint never shows a history row's result.
    response.pin(first_serial);
    response.clearPin();
    session.selection = Path.empty.child(1);
    response.snapshot(&u, arena);
    try testing.expectEqual(state_mod.ResponseKind.none, u.response.kind);
}

test "the byte budget evicts the oldest result before the newest one" {
    var session = testSession();
    var response = Response{};
    response.start(&session);
    defer response.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = Key{ .workspace = 0, .path = Path.empty.child(0) };
    const big = arena.alloc(u8, 40 * 1024 * 1024) catch @panic("out of memory building a big body");
    @memset(big, 'x');
    response.store(key, .{ .method = "GET", .name = "big" }, okResult(arena, 200, big), .{ .text = big, .lines = &.{ 0, big.len } });
    response.store(key, .{ .method = "GET", .name = "small" }, okResult(arena, 200, "small"), .{ .text = "small", .lines = &.{ 0, 5 } });

    // Forty megabytes of history cannot exist, so the big entry went and the small one stayed.
    try testing.expectEqual(@as(usize, 1), response.entries.items.len);
    try testing.expectEqualStrings("small", response.entries.items[0].name);
}
