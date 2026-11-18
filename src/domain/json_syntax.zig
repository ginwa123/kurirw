//! The JSON rules a CodeEditor colours by: one pass, one token per thing worth a colour, and invalid input still tokens.
const std = @import("std");

const Allocator = std.mem.Allocator;

// What a token is; `key` is a string the next non-space byte after it brings a colon for.
pub const Kind = enum { key, string, number, literal, punct };

// One token: the bytes [start, end) of the text and what they are.
pub const Token = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const tokens_cap: usize = 1 << 16;

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

// A `"…"` run, escape sequences included, ending after the closing quote or at the end of the text.
fn stringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            // The escaped byte belongs to the run whether or not it is a legal escape: an unfinished `\` is still text.
            i += 1;
            continue;
        }
        if (text[i] == '"') return i + 1;
    }
    return text.len;
}

// A loose number so `-` and `1e` keep a colour while they are typed instead of flickering back to plain.
fn numberEnd(text: []const u8, start: usize) usize {
    var i = start;
    if (i < text.len and text[i] == '-') i += 1;
    while (i < text.len and isDigit(text[i])) i += 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and isDigit(text[i])) i += 1;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        while (i < text.len and isDigit(text[i])) i += 1;
    }
    return i;
}

// Whether a string token is an object key: the next non-space byte after it is a colon.
fn isKey(text: []const u8, after: usize) bool {
    var i = after;
    while (i < text.len and isSpace(text[i])) : (i += 1) {}
    return i < text.len and text[i] == ':';
}

fn literalAt(text: []const u8, start: usize) ?usize {
    for ([_][]const u8{ "true", "false", "null" }) |word| {
        if (std.mem.startsWith(u8, text[start..], word)) return start + word.len;
    }
    return null;
}

// Scan `text` into `out`, replacing what it held; the token count is capped so a body that is not JSON cannot eat the heap.
pub fn scan(out: *std.ArrayListUnmanaged(Token), alloc: Allocator, text: []const u8) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < text.len and out.items.len < tokens_cap) {
        const ch = text[i];
        if (isSpace(ch)) {
            i += 1;
            continue;
        }
        if (ch == '"') {
            const end = stringEnd(text, i);
            const kind: Kind = if (isKey(text, end)) .key else .string;
            try out.append(alloc, .{ .start = i, .end = end, .kind = kind });
            i = end;
            continue;
        }
        if (ch == '-' or isDigit(ch)) {
            const end = numberEnd(text, i);
            // A lone `-` is a number being typed; anything the scanner could not advance is skipped byte by byte.
            if (end > i) {
                try out.append(alloc, .{ .start = i, .end = end, .kind = .number });
                i = end;
                continue;
            }
        }
        if (literalAt(text, i)) |end| {
            try out.append(alloc, .{ .start = i, .end = end, .kind = .literal });
            i = end;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "{}[],:", ch) != null) {
            try out.append(alloc, .{ .start = i, .end = i + 1, .kind = .punct });
            i += 1;
            continue;
        }
        // Anything else — a bare word, a stray comma in a broken body — is simply not coloured.
        i += 1;
    }
}

// True when the text starts with an object or an array: the cheap test that says a body is JSON at all.
pub fn looksLikeJson(text: []const u8) bool {
    for (text) |ch| {
        if (isSpace(ch)) continue;
        return ch == '{' or ch == '[';
    }
    return false;
}

const testing = std.testing;

// One token as a test reads it: its bytes and its kind, instead of two offsets.
const Found = struct { bytes: []const u8, kind: Kind };

fn scanAll(list: *std.ArrayListUnmanaged(Token), alloc: Allocator, text: []const u8, out: []Found) ![]Found {
    try scan(list, alloc, text);
    for (list.items, 0..) |t, i| out[i] = .{ .bytes = text[t.start..t.end], .kind = t.kind };
    return out[0..list.items.len];
}

test "an object's keys, strings, numbers, literals and punctuation are told apart" {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    defer list.deinit(testing.allocator);
    var found: [32]Found = undefined;
    const text = "{\"name\": \"kurir\", \"n\": -12.5e3, \"ok\": true, \"none\": null}";
    const got = try scanAll(&list, testing.allocator, text, &found);

    const expect = [_]Found{
        .{ .bytes = "{", .kind = .punct },
        .{ .bytes = "\"name\"", .kind = .key },
        .{ .bytes = ":", .kind = .punct },
        .{ .bytes = "\"kurir\"", .kind = .string },
        .{ .bytes = ",", .kind = .punct },
        .{ .bytes = "\"n\"", .kind = .key },
        .{ .bytes = ":", .kind = .punct },
        .{ .bytes = "-12.5e3", .kind = .number },
        .{ .bytes = ",", .kind = .punct },
        .{ .bytes = "\"ok\"", .kind = .key },
        .{ .bytes = ":", .kind = .punct },
        .{ .bytes = "true", .kind = .literal },
        .{ .bytes = ",", .kind = .punct },
        .{ .bytes = "\"none\"", .kind = .key },
        .{ .bytes = ":", .kind = .punct },
        .{ .bytes = "null", .kind = .literal },
        .{ .bytes = "}", .kind = .punct },
    };
    try testing.expectEqual(expect.len, got.len);
    for (expect, got) |want, have| {
        try testing.expectEqualStrings(want.bytes, have.bytes);
        try testing.expectEqual(want.kind, have.kind);
    }
}

test "an array is tokens too, and a string after a comma stays a string" {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    defer list.deinit(testing.allocator);
    var found: [16]Found = undefined;
    const got = try scanAll(&list, testing.allocator, "[1, \"two\", false]", &found);
    try testing.expectEqual(@as(usize, 7), got.len);
    try testing.expectEqual(Kind.punct, got[0].kind);
    try testing.expectEqual(Kind.number, got[1].kind);
    try testing.expectEqual(Kind.string, got[3].kind);
    try testing.expectEqual(Kind.literal, got[5].kind);
}

test "a body being typed is coloured while it is still broken" {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    defer list.deinit(testing.allocator);
    var found: [8]Found = undefined;
    // No closing brace, no closing quote: each is still a run, and nothing runs past the text.
    const got = try scanAll(&list, testing.allocator, "{\"a\": \"unfinishe", &found);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqual(Kind.key, got[1].kind);
    try testing.expectEqual(Kind.string, got[3].kind);
    try testing.expectEqualStrings("\"unfinishe", got[3].bytes);

    const dangling = try scanAll(&list, testing.allocator, "{\"n\": -", &found);
    try testing.expectEqual(Kind.number, dangling[3].kind);
    try testing.expectEqualStrings("-", dangling[3].bytes);
}

test "an escape sequence does not end a string early" {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    defer list.deinit(testing.allocator);
    var found: [8]Found = undefined;
    const text = "{\"q\": \"a\\\"b\"}";
    const got = try scanAll(&list, testing.allocator, text, &found);
    try testing.expectEqualStrings("\"a\\\"b\"", got[3].bytes);
    try testing.expectEqual(Kind.punct, got[4].kind);
}

test "a body that is not JSON yields no tokens, and only JSON shapes say they are JSON" {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    defer list.deinit(testing.allocator);
    var found: [8]Found = undefined;
    const got = try scanAll(&list, testing.allocator, "hello world", &found);
    try testing.expectEqual(@as(usize, 0), got.len);
    // The cheap shape test the CodeEditor uses before it colours anything.
    try testing.expect(looksLikeJson("  \n {\"a\":1}"));
    try testing.expect(looksLikeJson("[1,2]"));
    try testing.expect(!looksLikeJson("<html>"));
    try testing.expect(!looksLikeJson("plain text"));
    try testing.expect(!looksLikeJson("   "));
}
