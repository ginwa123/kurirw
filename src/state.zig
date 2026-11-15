//! The screen's state as a VALUE: every field the view draws, and the pure helpers that turn numbers into labels.
const std = @import("std");
const postman = @import("model/postman.zig");

pub const max_depth: usize = 8;
pub const max_tree_rows: usize = 512;
pub const max_headers: usize = 32;
pub const max_body: usize = 64 * 1024;
pub const max_url: usize = 2048;
pub const max_name: usize = 128;

pub const NodeKind = enum {
    collection,
    folder,
    request,
};

// Which pane the request editor and the response show.
pub const Tab = enum {
    headers,
    body,
};

// A node's address: the collection index, then one index per nesting level inside `item[]`.
pub const Path = struct {
    depth: usize = 0,
    segments: [max_depth]u16 = @splat(0),

    pub const empty: Path = .{};

    pub fn child(self: Path, index: u16) Path {
        var next = self;
        if (next.depth < max_depth) {
            next.segments[next.depth] = index;
            next.depth += 1;
        }
        return next;
    }

    pub fn parent(self: Path) ?Path {
        if (self.depth == 0) return null;
        var next = self;
        next.depth -= 1;
        return next;
    }

    pub fn at(self: Path, level: usize) ?u16 {
        if (level >= self.depth) return null;
        return self.segments[level];
    }

    pub fn eql(a: Path, b: Path) bool {
        if (a.depth != b.depth) return false;
        for (a.segments[0..a.depth], b.segments[0..b.depth]) |x, y| {
            if (x != y) return false;
        }
        return true;
    }

    // "0.2.1", stable enough to be an element id and readable in a test failure.
    pub fn format(self: Path, buffer: []u8) []const u8 {
        var out = std.Io.Writer.fixed(buffer);
        for (self.segments[0..self.depth], 0..) |segment, i| {
            if (i > 0) out.writeByte('.') catch break;
            out.print("{d}", .{segment}) catch break;
        }
        return out.buffered();
    }
};

// One row of the collection tree: what it says, how deep it sits, and what the pointer can do to it.
pub const TreeRow = struct {
    path: Path = .{},
    depth: u16 = 0,
    kind: NodeKind = .collection,
    label: []const u8 = "",
    method: []const u8 = "",
    has_children: bool = false,
    expanded: bool = false,
    selected: bool = false,
};

pub const HeaderRow = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const ResponseKind = enum {
    none,
    ok,
    failed,
};

// The response pane: the status line, the size, the pretty body, and the failure that replaced it.
pub const ResponseView = struct {
    kind: ResponseKind = .none,
    status: u16 = 0,
    status_text: []const u8 = "",
    time_ms: u64 = 0,
    size: usize = 0,
    size_text: []const u8 = "",
    time_text: []const u8 = "",
    body: []const u8 = "",
    truncated_lines: usize = 0,
    headers: []const HeaderRow = &.{},
    error_title: []const u8 = "",
    error_message: []const u8 = "",
};

// Everything the frame draws. Slices point into memory the ViewModel owns and keeps until the next intent.
pub const UiState = struct {
    rows: []const TreeRow = &.{},
    selection: ?Path = null,
    workspace_name: []const u8 = "",
    workspace_index: usize = 0,
    workspace_count: usize = 0,
    workspace_label: []const u8 = "",

    node_kind: ?NodeKind = null,
    node_name: []const u8 = "",
    method: []const u8 = postman.default_method,
    url: []const u8 = "",
    headers: []const HeaderRow = &.{},
    header_count: usize = 0,
    body: []const u8 = "",
    editor_tab: Tab = .headers,
    response_tab: Tab = .body,
    response: ResponseView = .{},

    status: []const u8 = "",
    status_is_error: bool = false,

    can_add_folder: bool = false,
    can_add_request: bool = false,
    can_delete: bool = false,
    has_selection: bool = false,
    has_collection: bool = false,
    dialog_available: bool = true,

    // Which field owns the keyboard this frame, so the view can hand it to the toolkit.
    focus: Focus = .none,
};

pub const Focus = enum {
    none,
    url,
    name,
    workspace,
    header_key,
    header_value,
    body,
};

// "1.4 kB": a size a person can read, in three significant digits and no magic units.
pub fn sizeLabel(buffer: []u8, bytes: usize) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "?";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} kB", .{@as(f64, @floatFromInt(bytes)) / 1024}) catch "?";
    return std.fmt.bufPrint(buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch "?";
}

// "312 ms", or "1.4 s" once a request is slow enough that milliseconds stop reading.
pub fn timeLabel(buffer: []u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buffer, "{d} ms", .{ms}) catch "?";
    return std.fmt.bufPrint(buffer, "{d:.2} s", .{@as(f64, @floatFromInt(ms)) / 1000}) catch "?";
}

// "200 OK", or just the code when the server sent no phrase Kurir knows.
pub fn statusLabel(buffer: []u8, status: u16, reason: []const u8) []const u8 {
    if (reason.len == 0) return std.fmt.bufPrint(buffer, "{d}", .{status}) catch "?";
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ status, reason }) catch "?";
}

// ---- tests ---------------------------------------------------------------------------------------------------

test "a path nests, compares and prints" {
    const root = Path.empty;
    const a = root.child(0);
    const b = a.child(2);
    const c = b.child(1);

    try std.testing.expectEqual(@as(usize, 3), c.depth);
    try std.testing.expectEqual(@as(?u16, 2), c.at(1));
    try std.testing.expect(c.at(4) == null);
    try std.testing.expect(Path.eql(c, root.child(0).child(2).child(1)));
    try std.testing.expect(!Path.eql(c, b));
    try std.testing.expect(Path.eql(b, c.parent().?));

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.2.1", c.format(&buffer));
    try std.testing.expectEqualStrings("", Path.empty.format(&buffer));
}

test "a path stops growing at the depth cap instead of overrunning" {
    var path = Path.empty;
    var i: u16 = 0;
    while (i < max_depth + 4) : (i += 1) path = path.child(i);
    try std.testing.expectEqual(max_depth, path.depth);
    try std.testing.expectEqual(@as(?u16, max_depth - 1), path.at(max_depth - 1));
}

test "a paragraph of labels: sizes, times and status lines" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", sizeLabel(&buffer, 512));
    try std.testing.expectEqualStrings("1.0 kB", sizeLabel(&buffer, 1024));
    try std.testing.expectEqualStrings("1.5 MB", sizeLabel(&buffer, 1024 * 1024 + 512 * 1024));
    try std.testing.expectEqualStrings("12 ms", timeLabel(&buffer, 12));
    try std.testing.expectEqualStrings("1.50 s", timeLabel(&buffer, 1500));
    try std.testing.expectEqualStrings("200 OK", statusLabel(&buffer, 200, "OK"));
    try std.testing.expectEqualStrings("599", statusLabel(&buffer, 599, ""));
}

test "the response view starts empty, which is the empty state the pane draws" {
    const view = ResponseView{};
    try std.testing.expectEqual(ResponseKind.none, view.kind);
    try std.testing.expectEqual(@as(u16, 0), view.status);
    try std.testing.expectEqual(@as(usize, 0), view.headers.len);
}
