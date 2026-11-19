//! A data file as the runner reads it: CSV or a JSON array of objects, one row per iteration. Pure.
const std = @import("std");

const csv = @import("csv.zig");
const env_mod = @import("env.zig");

pub const Allocator = std.mem.Allocator;

// How many rows a run may carry: a data file is a list of cases, not a database dump.
pub const max_rows: usize = 5_000;

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

// One iteration's variables, in the order the file named them.
pub const Row = struct {
    cells: []const []const u8 = &.{},
};

pub const Data = struct {
    columns: []const []const u8 = &.{},
    rows: []const Row = &.{},
    // The format the bytes were read as, so the page can say "CSV" or "JSON".
    format: Format = .none,
    failure: ?Diagnostic = null,

    pub fn count(self: Data) usize {
        return self.rows.len;
    }
};

pub const Format = enum { none, csv, json };

// A likely-JSON file starts with `[` once whitespace is skipped; anything else is CSV.
pub fn formatOf(bytes: []const u8) Format {
    for (bytes) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') continue;
        return if (byte == '[' or byte == '{') .json else .csv;
    }
    return .none;
}

// Read `bytes` as a data file: a JSON array of objects, or CSV with a header row.
pub fn parse(arena: Allocator, bytes: []const u8) Allocator.Error!Data {
    return switch (formatOf(bytes)) {
        .json => parseJson(arena, bytes),
        .csv => parseCsv(arena, bytes),
        .none => .{},
    };
}

fn parseCsv(arena: Allocator, bytes: []const u8) Allocator.Error!Data {
    const table = try csv.parse(arena, bytes);
    if (table.count() > max_rows) {
        return .{ .columns = table.header, .format = .csv, .failure = .{ .line = 0, .message = "the file has more rows than a run may carry" } };
    }
    const rows = try arena.alloc(Row, table.count());
    for (table.rows, 0..) |cells, index| rows[index] = .{ .cells = cells };
    return .{ .columns = table.header, .rows = rows, .format = .csv, .failure = if (table.failure) |f| .{ .line = f.line, .message = f.message } else null };
}

// `[{"name":"a","amount":1}, …]`: the first object names the columns, and every value becomes the text a URL expects.
fn parseJson(arena: Allocator, bytes: []const u8) Allocator.Error!Data {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
        return .{ .format = .json, .failure = .{ .line = 1, .message = "the file is not valid JSON" } };
    if (root != .array) return .{ .format = .json, .failure = .{ .line = 1, .message = "the JSON data file must be an array of objects" } };
    if (root.array.items.len == 0) return .{ .format = .json };
    if (root.array.items.len > max_rows) {
        return .{ .format = .json, .failure = .{ .line = 1, .message = "the file has more rows than a run may carry" } };
    }
    const first = root.array.items[0];
    if (first != .object) return .{ .format = .json, .failure = .{ .line = 1, .message = "the JSON data file must be an array of objects" } };

    var columns: std.ArrayList([]const u8) = .empty;
    var it = first.object.iterator();
    while (it.next()) |entry| try columns.append(arena, try arena.dupe(u8, entry.key_ptr.*));

    const rows = try arena.alloc(Row, root.array.items.len);
    for (root.array.items, 0..) |item, index| {
        const cells = try arena.alloc([]const u8, columns.items.len);
        for (columns.items, 0..) |column, column_index| {
            cells[column_index] = try textOf(arena, item, column);
        }
        rows[index] = .{ .cells = cells };
    }
    return .{ .columns = columns.items, .rows = rows, .format = .json };
}

// A missing key is the empty string, so a sparse row still lines up with the header.
fn textOf(arena: Allocator, item: std.json.Value, key: []const u8) Allocator.Error![]const u8 {
    if (item != .object) return "";
    const value = item.object.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(arena, "{d}", .{number}),
        .float => |number| std.fmt.allocPrint(arena, "{d}", .{number}),
        .bool => |on| if (on) "true" else "false",
        .null => "",
        else => std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})}),
    };
}

// One row as the `{{name}}` pairs the request walk sees: a data variable outranks everything below it.
pub fn pairs(arena: Allocator, data: Data, index: usize) Allocator.Error![]const env_mod.Pair {
    if (index >= data.rows.len) return &.{};
    const cells = data.rows[index].cells;
    const pairs_out = try arena.alloc(env_mod.Pair, data.columns.len);
    for (data.columns, 0..) |column, column_index| {
        pairs_out[column_index] = .{ .name = column, .value = if (column_index < cells.len) cells[column_index] else "" };
    }
    return pairs_out;
}

const testing = std.testing;

test "a CSV data file is its header and one row per record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = try parse(arena, "name,amount\nalpha,100\nbeta,200\n");
    try testing.expect(data.failure == null);
    try testing.expectEqual(Format.csv, data.format);
    try testing.expectEqual(@as(usize, 2), data.count());
    try testing.expectEqualStrings("amount", data.columns[1]);

    const row = try pairs(arena, data, 1);
    try testing.expectEqualStrings("beta", row[0].value);
    try testing.expectEqualStrings("200", row[1].value);
}

test "a JSON array of objects uses the first object's keys and stringifies every kind of value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = try parse(arena, "[{\"name\":\"alpha\",\"amount\":100,\"ok\":true,\"note\":null},{\"name\":\"beta\",\"amount\":2.5}]");
    try testing.expect(data.failure == null);
    try testing.expectEqual(Format.json, data.format);
    try testing.expectEqual(@as(usize, 2), data.count());
    const row = try pairs(arena, data, 0);
    try testing.expectEqual(@as(usize, 4), row.len);
    // Order is the file's own; find each column by name rather than by position.
    var amount: []const u8 = "";
    var ok: []const u8 = "";
    var note: []const u8 = "";
    for (row) |pair| {
        if (std.mem.eql(u8, pair.name, "amount")) amount = pair.value;
        if (std.mem.eql(u8, pair.name, "ok")) ok = pair.value;
        if (std.mem.eql(u8, pair.name, "note")) note = pair.value;
    }
    try testing.expectEqualStrings("100", amount);
    try testing.expectEqualStrings("true", ok);
    try testing.expectEqualStrings("", note);
}

test "a sparse row still lines up with the header, and a JSON object that is not an array is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = try parse(arena, "[{\"a\":1,\"b\":2},{\"a\":3}]");
    const second = try pairs(arena, data, 1);
    try testing.expectEqualStrings("", second[1].value);

    const bad = try parse(arena, "{\"a\":1}");
    try testing.expect(bad.failure != null);
}

test "an empty file is no data at all, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = try parse(arena, "\n\n");
    try testing.expect(data.failure == null);
    try testing.expectEqual(@as(usize, 0), data.count());
}
