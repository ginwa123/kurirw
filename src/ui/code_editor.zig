//! Kurir's code editor: the toolkit's text field plus the one thing a field cannot know — what the text means.
const std = @import("std");
const glinlandui = @import("glinlandui");
const theme_mod = @import("theme/theme.zig");
const json_syntax = @import("../domain/json_syntax.zig");

const input = glinlandui.components.input;
const Color = glinlandui.Color;

/// The languages the editor knows; `plain` colours nothing, which is what anything that is not JSON gets today.
pub const Language = enum { plain, json };

/// The colour a kind of token is drawn in; the palette lives in the theme, so a tone is changed in one place.
pub fn colorOf(kind: json_syntax.Kind) Color {
    return switch (kind) {
        .key => theme_mod.json_key,
        .string => theme_mod.json_string,
        .number => theme_mod.json_number,
        .literal => theme_mod.json_literal,
        .punct => theme_mod.json_punct,
    };
}

// What the text looked like when the runs were computed: length and hash, so an edit anywhere is noticed and no copy is kept.
const Fingerprint = struct {
    len: usize = std.math.maxInt(usize),
    hash: u64 = 0,

    fn of(text: []const u8) Fingerprint {
        return .{ .len = text.len, .hash = std.hash.Wyhash.hash(0, text) };
    }

    fn same(a: Fingerprint, b: Fingerprint) bool {
        return a.len == b.len and a.hash == b.hash;
    }
};

/// The language a body speaks: JSON when it opens with an object or an array, plain otherwise.
pub fn languageOf(text: []const u8) Language {
    return if (json_syntax.looksLikeJson(text)) .json else .plain;
}

pub const CodeEditor = struct {
    alloc: std.mem.Allocator,
    language: Language = .json,
    // The tokens, and the coloured runs built from them; the field draws from `spans`, so they live as long as the editor.
    tokens: std.ArrayListUnmanaged(json_syntax.Token) = .empty,
    spans: std.ArrayListUnmanaged(input.SyntaxSpan) = .empty,
    seen: Fingerprint = .{},

    pub fn init(alloc: std.mem.Allocator) CodeEditor {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *CodeEditor) void {
        self.tokens.deinit(self.alloc);
        self.spans.deinit(self.alloc);
    }

    /// Recompute the runs, but only when the text changed: a body can be a megabyte and the frame is drawn sixty times a second.
    pub fn refresh(self: *CodeEditor, text: []const u8) void {
        const now = Fingerprint.of(text);
        if (Fingerprint.same(now, self.seen)) return;
        self.seen = now;
        self.language = languageOf(text);
        self.spans.clearRetainingCapacity();
        if (self.language == .plain) return;
        // A body the allocator cannot take draws uncoloured rather than not at all: the text is the point, colour is an aid.
        json_syntax.scan(&self.tokens, self.alloc, text) catch return;
        for (self.tokens.items) |token| {
            self.spans.append(self.alloc, .{
                .start = token.start,
                .end = token.end,
                .color = colorOf(token.kind),
            }) catch return;
        }
    }

    /// Declare the field exactly as the toolkit's text field does, with the runs this editor computed for its text.
    pub fn textField(self: *CodeEditor, field: *input.Field) void {
        self.refresh(field.editor.text());
        field.syntax = if (self.spans.items.len == 0) null else self.spans.items;
        input.textField(field);
    }
};

const testing = std.testing;

// The kinds of a body's tokens, in order, which is what a test reads instead of offsets.
fn expectKinds(text: []const u8, editor: *CodeEditor, want: []const json_syntax.Kind) !void {
    editor.refresh(text);
    try testing.expectEqual(want.len, editor.tokens.items.len);
    for (want, editor.tokens.items) |kind, token| try testing.expectEqual(kind, token.kind);
}

test "a JSON body colours its keys, strings, numbers, literals and punctuation" {
    var editor = CodeEditor.init(testing.allocator);
    defer editor.deinit();
    try expectKinds("{\"a\": 1, \"b\": [true, null]}", &editor, &.{
        .punct, .key, .punct, .number, .punct, .key, .punct, .punct, .literal, .punct, .literal, .punct, .punct,
    });
    // One run per token, in that token's tone, and every run sits inside the text.
    try testing.expectEqual(editor.tokens.items.len, editor.spans.items.len);
    for (editor.spans.items, editor.tokens.items) |span, token| {
        try testing.expectEqual(token.start, span.start);
        try testing.expectEqual(token.end, span.end);
        try testing.expectEqual(colorOf(token.kind), span.color);
    }
    // A key and a string are the same bytes in the text and two different tones on screen.
    try testing.expect(!std.meta.eql(colorOf(.key), colorOf(.string)));
}

test "anything that is not JSON is left plain" {
    var editor = CodeEditor.init(testing.allocator);
    defer editor.deinit();
    editor.refresh("<html><body>hello</body></html>");
    try testing.expectEqual(Language.plain, editor.language);
    try testing.expectEqual(@as(usize, 0), editor.spans.items.len);
    editor.refresh("plain words");
    try testing.expectEqual(@as(usize, 0), editor.spans.items.len);
    // An empty body is not JSON either, so an empty editor paints nothing.
    editor.refresh("");
    try testing.expectEqual(@as(usize, 0), editor.spans.items.len);
}

test "the runs are remembered until the text changes, and rebuilt when it does" {
    var editor = CodeEditor.init(testing.allocator);
    defer editor.deinit();
    editor.refresh("{\"a\": 1}");
    const first = editor.spans.items.len;
    try testing.expect(first > 0);
    // The same bytes again: no second scan, and the same runs stand.
    editor.refresh("{\"a\": 1}");
    try testing.expectEqual(first, editor.spans.items.len);
    // A change anywhere rebuilds them, even with the length unchanged: `1` becomes `2`, same size, different text.
    editor.refresh("{\"a\": 2}");
    try testing.expectEqual(first, editor.spans.items.len);
    // And a body that stops being JSON drops them: an answer that came back as HTML must not keep JSON colours.
    editor.refresh("<html>");
    try testing.expectEqual(@as(usize, 0), editor.spans.items.len);
}

test "a half-typed body is coloured as it is written" {
    var editor = CodeEditor.init(testing.allocator);
    defer editor.deinit();
    editor.refresh("{\"a\": ");
    try testing.expectEqual(Language.json, editor.language);
    // The brace, the key and the colon, and nothing for the value that is not there yet.
    try testing.expectEqual(@as(usize, 3), editor.spans.items.len);
}
