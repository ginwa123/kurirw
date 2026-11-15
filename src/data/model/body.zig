//! A response body as the pane shows it: JSON re-indented when it parses, the bytes as they arrived otherwise.
const std = @import("std");

const postman = @import("postman.zig");

const Allocator = std.mem.Allocator;

pub const Shown = struct {
    text: []const u8 = "",
    // The byte offset of every line start (plus the end), so the pane can draw line N without scanning the body.
    lines: []const usize = &.{},
};

pub fn format(gpa: Allocator, arena: Allocator, body: []const u8) Shown {
    const text = pretty(gpa, arena, body);
    return .{ .text = text, .lines = lineStarts(arena, text) };
}

// A JSON body reads as a document, anything else is shown as it arrived, and nothing is capped.
pub fn pretty(gpa: Allocator, arena: Allocator, body: []const u8) []const u8 {
    if (body.len == 0) return "";
    // The tree gets its own arena: a body that does not parse must not cost a tree in the arena that outlives it.
    var tree = std.heap.ArenaAllocator.init(gpa);
    defer tree.deinit();
    const parsed = std.json.parseFromSliceLeaky(postman.Value, tree.allocator(), body, .{}) catch
        return sanitize(arena, body);
    const text = postman.write(arena, parsed, true) catch return sanitize(arena, body);
    return sanitize(arena, text);
}

// A response is bytes, not text: anything a font cannot draw becomes a middle dot rather than a broken run.
pub fn sanitize(arena: Allocator, bytes: []const u8) []const u8 {
    const out = arena.alloc(u8, bytes.len) catch return "";
    for (bytes, 0..) |byte, i| {
        out[i] = if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) byte else 0xb7;
    }
    return out;
}

// One entry per line plus the end: line i is `text[lines[i]..lines[i + 1]]`.
pub fn lineStarts(arena: Allocator, text: []const u8) []const usize {
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    const starts = arena.alloc(usize, count + 1) catch return &.{};
    var at_line: usize = 0;
    starts[0] = 0;
    for (text, 0..) |byte, at| {
        if (byte != '\n') continue;
        at_line += 1;
        starts[at_line] = at + 1;
    }
    starts[count] = text.len;
    return starts[0 .. count + 1];
}

// Line i of a body, without the newline that ends it: what a row draws.
pub fn line(text: []const u8, starts: []const usize, index: usize) []const u8 {
    if (index + 1 >= starts.len) return "";
    const start = @min(starts[index], text.len);
    var end = @min(starts[index + 1], text.len);
    if (end > start and text[end - 1] == '\n') end -= 1;
    return text[start..end];
}

const testing = std.testing;

test "a JSON body is re-indented, and anything else is shown as it arrived" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shown = format(testing.allocator, arena, "{\"a\":1}");
    try testing.expect(std.mem.indexOfScalar(u8, shown.text, '\n') != null);
    try testing.expectEqual(@as(usize, 4), shown.lines.len);

    const plain = format(testing.allocator, arena, "hello");
    try testing.expectEqualStrings("hello", plain.text);
    try testing.expectEqual(@as(usize, 2), plain.lines.len);
}

test "a byte a font cannot draw becomes a middle dot, so a binary body never breaks the run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualSlices(u8, &.{ 'a', 0xb7, 'b' }, sanitize(arena, "a\x00b"));
    try testing.expectEqualStrings("a\nb\tc", sanitize(arena, "a\nb\tc"));
}

test "every line is addressable, including the empty one a trailing newline leaves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "one\ntwo\n";
    const lines = lineStarts(arena, text);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("one", line(text, lines, 0));
    try testing.expectEqualStrings("two", line(text, lines, 1));
    try testing.expectEqualStrings("", line(text, lines, 2));
}

test "a body far larger than a frame budget keeps every byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "[\n");
    while (body.items.len < 1024 * 1024) {
        try body.appendSlice(testing.allocator, "  { \"name\": \"Adeel\", \"id\": \"V59OF92YF627HFY0\" },\n");
    }
    try body.appendSlice(testing.allocator, "]\n");

    const shown = format(testing.allocator, arena, body.items);
    try testing.expect(shown.text.len > body.items.len - 16);
    try testing.expect(shown.lines.len > 10_000);
}
