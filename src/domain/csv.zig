//! CSV in the shape a data file uses: a header row, then one record per line. Pure, no I/O.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

// How many columns a data file may carry, and how long one field may be: a pasted spreadsheet, not a database.
pub const max_columns: usize = 64;
pub const max_field: usize = 8 * 1024;

// What the parser hands back: every record, and a sentence when the bytes are not CSV at all.
pub const Table = struct {
    // The first record, which names the columns. Empty when the file has no rows.
    header: []const []const u8 = &.{},
    // One slice per record, each the length of `header`. Short rows are padded with "".
    rows: []const []const []const u8 = &.{},
    // Set when the file stopped making sense; `rows` then holds what was readable before it.
    failure: ?Diagnostic = null,

    pub fn count(self: Table) usize {
        return self.rows.len;
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    message: []const u8 = "",
};

// ",", ";" or tab: the delimiter the header row actually uses, so a spreadsheet export works unchanged.
pub fn delimiterOf(text: []const u8) u8 {
    const first_line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    const first = text[0..@min(first_line_end, 4 * 1024)];
    var commas: usize = 0;
    var semis: usize = 0;
    var tabs: usize = 0;
    var quoted = false;
    for (first) |byte| {
        if (byte == '"') quoted = !quoted;
        if (quoted) continue;
        if (byte == ',') commas += 1;
        if (byte == ';') semis += 1;
        if (byte == '\t') tabs += 1;
    }
    if (semis > commas and semis >= tabs) return ';';
    if (tabs > commas and tabs > semis) return '\t';
    return ',';
}

// Parse `text` into a header and its records. Every string is owned by `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Table {
    const delimiter = delimiterOf(text);
    var records: std.ArrayList([]const []const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var field: std.ArrayList(u8) = .empty;

    var index: usize = 0;
    var line: usize = 1;
    var in_quotes = false;
    var record_started = false;

    while (index <= text.len) : (index += 1) {
        const at_end = index == text.len;
        const byte: u8 = if (at_end) '\n' else text[index];

        if (in_quotes) {
            if (byte == '"') {
                // A doubled quote inside a quoted field is one quote, and the field goes on.
                if (index + 1 < text.len and text[index + 1] == '"') {
                    try field.append(arena, '"');
                    index += 1;
                } else {
                    in_quotes = false;
                }
            } else {
                if (byte == '\n') line += 1;
                try field.append(arena, byte);
            }
            continue;
        }

        if (byte == '"' and field.items.len == 0) {
            in_quotes = true;
            record_started = true;
            continue;
        }
        if (byte == delimiter) {
            try fields.append(arena, try field.toOwnedSlice(arena));
            field = .empty;
            record_started = true;
            continue;
        }
        if (byte == '\r' and !at_end and !in_quotes) continue;
        if (byte == '\n' or at_end) {
            // A blank line is not a record: a trailing newline is the file ending, not an empty row.
            if (record_started or field.items.len > 0 or fields.items.len > 0) {
                try fields.append(arena, try field.toOwnedSlice(arena));
                field = .empty;
                try records.append(arena, try fields.toOwnedSlice(arena));
                fields = .empty;
                record_started = false;
            }
            line += 1;
            continue;
        }
        try field.append(arena, byte);
        record_started = true;
    }

    if (in_quotes) {
        return .{ .failure = .{ .line = line, .message = "a quoted field is not closed before the end of the file" } };
    }
    if (records.items.len == 0) return .{};

    const header = records.items[0];
    if (header.len > max_columns) {
        return .{ .failure = .{ .line = 1, .message = "the header names more columns than a data file may carry" } };
    }
    var rows: std.ArrayList([]const []const u8) = .empty;
    for (records.items[1..], 2..) |record, row_line| {
        const widened = try arena.alloc([]const u8, header.len);
        var i: usize = 0;
        while (i < header.len) : (i += 1) {
            widened[i] = if (i < record.len) record[i] else "";
            if (widened[i].len > max_field) {
                return .{
                    .header = header,
                    .rows = rows.items,
                    .failure = .{ .line = row_line, .message = "a field is longer than 8 KB" },
                };
            }
        }
        try rows.append(arena, widened);
    }
    return .{ .header = header, .rows = rows.items };
}

const testing = std.testing;

test "a header and three records, with the values in the cells they were written in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "name,amount,note\nalpha,100,first\nbeta,200,second\n");
    try testing.expect(table.failure == null);
    try testing.expectEqual(@as(usize, 3), table.header.len);
    try testing.expectEqualStrings("name", table.header[0]);
    try testing.expectEqual(@as(usize, 2), table.count());
    try testing.expectEqualStrings("beta", table.rows[1][0]);
    try testing.expectEqualStrings("second", table.rows[1][2]);
}

test "a quoted field keeps its delimiter, its newline and a doubled quote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "name,note\n\"a,b\",\"line one\nline two\"\n\"say \"\"hi\"\"\",plain\r\n");
    try testing.expect(table.failure == null);
    try testing.expectEqual(@as(usize, 2), table.count());
    try testing.expectEqualStrings("a,b", table.rows[0][0]);
    try testing.expectEqualStrings("line one\nline two", table.rows[0][1]);
    try testing.expectEqualStrings("say \"hi\"", table.rows[1][0]);
    try testing.expectEqualStrings("plain", table.rows[1][1]);
}

test "a short row is padded to the header, and a blank line is not a record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "a,b,c\n1,2\n\n4,5,6\n");
    try testing.expectEqual(@as(usize, 2), table.count());
    try testing.expectEqualStrings("", table.rows[0][2]);
    try testing.expectEqualStrings("4", table.rows[1][0]);
}

test "a semicolon file is read with semicolons, because that is what the header used" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "a;b\n1;2\n");
    try testing.expectEqual(@as(usize, 2), table.header.len);
    try testing.expectEqualStrings("2", table.rows[0][1]);
}

test "an unclosed quote is reported instead of silently swallowing the file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "a,b\n1,\"oops\n");
    try testing.expect(table.failure != null);
    try testing.expect(std.mem.indexOf(u8, table.failure.?.message, "not closed") != null);
}

test "an empty file is a table with no header and no rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try parse(arena, "");
    try testing.expect(table.failure == null);
    try testing.expectEqual(@as(usize, 0), table.header.len);
    try testing.expectEqual(@as(usize, 0), table.count());
}
