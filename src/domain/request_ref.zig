//! The name a runner's test calls: `send(request, 'collection/request')`, resolved when the run starts. Pure.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

// How many calls one spec may name: a suite longer than this is not one page's worth of tests.
pub const max_refs: usize = 256;

// One `send(request, '…')` call: the name it asks for, and the line it is on.
pub const Ref = struct {
    text: []const u8 = "",
    line: usize = 1,
};

// ---- reading -------------------------------------------------------------------------------------------------

// Every `send(request, '…')` of a spec, in file order: what the helper looks up at run time.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error![]Ref {
    var out: std.ArrayList(Ref) = .empty;
    var line: usize = 1;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, source[index..], "send(")) continue;
        const text = refAt(source, index + "send(".len) orelse continue;
        if (out.items.len >= max_refs) break;
        try out.append(arena, .{ .text = try unescape(arena, text), .line = line });
    }
    return out.items;
}

// The quoted name of a `send(request, '…')` call starting just after `send(`, or null when the call is another shape.
fn refAt(source: []const u8, start: usize) ?[]const u8 {
    var cursor = start;
    cursor = skipBlank(source, cursor);
    if (!std.mem.startsWith(u8, source[cursor..], "request")) return null;
    cursor += "request".len;
    cursor = skipBlank(source, cursor);
    if (cursor >= source.len or source[cursor] != ',') return null;
    cursor += 1;
    cursor = skipBlank(source, cursor);
    if (cursor >= source.len) return null;
    const quote = source[cursor];
    if (quote != '\'' and quote != '"' and quote != '`') return null;
    cursor += 1;
    const first = cursor;
    while (cursor < source.len) : (cursor += 1) {
        if (source[cursor] == '\\') {
            cursor += 1;
            continue;
        }
        if (source[cursor] == quote) return source[first..cursor];
    }
    return null;
}

fn skipBlank(source: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r' or source[cursor] == '\n')) cursor += 1;
    return cursor;
}

// The escapes the generator writes, undone: `\'`, `\"`, `` \` `` and `\\` stand for the character itself.
fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '\\' and index + 1 < raw.len) index += 1;
        try out.append(arena, raw[index]);
    }
    return out.items;
}

// ---- writing -------------------------------------------------------------------------------------------------

// The ref a saved request answers to: its collection, any folders, and its own name, joined by '/'.
pub fn join(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names) |name| {
        if (name.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, name);
    }
    // Owned: a caller frees this, and an ArrayList's buffer is not the slice it returns.
    return out.toOwnedSlice(arena);
}

// ---- resolving -----------------------------------------------------------------------------------------------

// What a lookup found: one entry, none, or more than one (the short name was not enough).
pub const Match = union(enum) {
    found: usize,
    missing,
    ambiguous,
};

// Exact first, then a unique `…/wanted` suffix: a bare request name is enough while it names one request.
pub fn resolve(candidates: []const []const u8, wanted: []const u8) Match {
    const text = std.mem.trim(u8, wanted, " \t\r\n");
    if (text.len == 0) return .missing;
    for (candidates, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, text)) return .{ .found = index };
    }
    var found: ?usize = null;
    for (candidates, 0..) |candidate, index| {
        if (!std.mem.endsWith(u8, candidate, text)) continue;
        if (candidate.len > text.len and candidate[candidate.len - text.len - 1] != '/') continue;
        if (found != null) return .ambiguous;
        found = index;
    }
    return if (found) |index| .{ .found = index } else .missing;
}

const testing = std.testing;

test "a spec's send() calls are read with their line numbers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\import { send } from '../kurir/index';
        \\
        \\test('one', async ({ request }) => {
        \\  const r = await send(request, 'billing/ok');
        \\});
        \\
        \\test('two', async ({ request }) => {
        \\  const r = await send( request , "billing/fail" );
        \\  const q = await send(request, 'billing/it\'s');
        \\});
        \\
        \\test('three', async ({ request }) => {
        \\  const r = await request.get('https://x.test/raw');
        \\});
    ;
    const refs = try parse(arena, source);
    try testing.expectEqual(@as(usize, 3), refs.len);
    try testing.expectEqualStrings("billing/ok", refs[0].text);
    try testing.expectEqual(@as(usize, 4), refs[0].line);
    try testing.expectEqualStrings("billing/fail", refs[1].text);
    try testing.expectEqual(@as(usize, 8), refs[1].line);
    // An escaped quote is part of the name, and a raw request.get() is not a ref at all.
    try testing.expectEqualStrings("billing/it's", refs[2].text);
    try testing.expectEqual(@as(usize, 9), refs[2].line);
}

test "a ref joins the names of the row it points at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("billing/ok", try join(arena, &.{ "billing", "ok" }));
    try testing.expectEqualStrings("billing/v2/ok", try join(arena, &.{ "billing", "v2", "ok" }));
    // An unnamed level is skipped rather than leaving an empty segment.
    try testing.expectEqualStrings("billing/ok", try join(arena, &.{ "billing", "", "ok" }));
}

test "a ref resolves exactly, by unique short name, or not at all" {
    const candidates = [_][]const u8{ "billing/ok", "billing/v2/ok", "auth/token" };
    try testing.expectEqual(@as(usize, 0), resolve(&candidates, "billing/ok").found);
    // A bare name one row answers to is enough.
    try testing.expectEqual(@as(usize, 2), resolve(&candidates, "token").found);
    // Two rows answer to `ok`, so the short form is refused instead of guessing.
    try testing.expect(resolve(&candidates, "ok") == .ambiguous);
    try testing.expect(resolve(&candidates, "billing/nope") == .missing);
    try testing.expect(resolve(&candidates, "") == .missing);
}
