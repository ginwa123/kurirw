//! A runner's program is a Playwright spec: list the tests it declares, and build one from a saved request. Pure.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

// How many tests a page lists: a spec longer than this is a suite, and the table is one run of a page.
pub const max_tests: usize = 512;

// One `test('name', …)` of the spec: what the FLOW list draws.
pub const Test = struct {
    name: []const u8 = "",
    // The 1-based line the test is declared on, so a failure can point at the program.
    line: usize = 1,
};

// ---- reading -------------------------------------------------------------------------------------------------

// Every test the spec declares, in file order. `test.describe(` is a group, not a test; `test.only`/`skip`/`fixme` are.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error![]Test {
    var out: std.ArrayList(Test) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        if (out.items.len >= max_tests) break;
        const title = titleOf(raw) orelse continue;
        try out.append(arena, .{ .name = try unescape(arena, title), .line = number });
    }
    return out.items;
}

// The quoted title of a `test(…)` declaration on this line, or null when the line is something else.
fn titleOf(raw: []const u8) ?[]const u8 {
    const text = std.mem.trimStart(u8, raw, " \t");
    // A comment is not a test, and neither is a line that merely mentions one.
    if (!std.mem.startsWith(u8, text, "test")) return null;
    var rest = text[4..];
    if (rest.len > 0 and rest[0] == '.') {
        // `test.only(`, `test.skip(`, `test.fixme(` declare a test; `describe`/`step`/hooks do not.
        const allowed = [_][]const u8{ "only", "skip", "fixme" };
        var matched = false;
        for (allowed) |word| {
            if (!std.mem.startsWith(u8, rest[1..], word)) continue;
            const after = rest[1 + word.len ..];
            if (after.len == 0 or after[0] != '(') continue;
            rest = after;
            matched = true;
            break;
        }
        if (!matched) return null;
    }
    if (rest.len == 0 or rest[0] != '(') return null;
    var cursor: usize = 1;
    while (cursor < rest.len and (rest[cursor] == ' ' or rest[cursor] == '\t')) cursor += 1;
    if (cursor >= rest.len) return null;
    const quote = rest[cursor];
    if (quote != '\'' and quote != '"' and quote != '`') return null;
    cursor += 1;
    const start = cursor;
    while (cursor < rest.len) : (cursor += 1) {
        if (rest[cursor] == '\\') {
            cursor += 1;
            continue;
        }
        if (rest[cursor] == quote) return rest[start..cursor];
    }
    return null;
}

// A title with its escapes undone: `\'`, `\"`, `` \` `` and `\\` stand for the character itself.
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

// The import a test that names a saved request needs. The generator adds it once, and never twice.
pub const helper_import = "import { send } from '../kurir/index';";

// The starter a new runner holds: a comment that says where the environment goes, and one test to edit.
pub fn starter(arena: Allocator) Allocator.Error![]u8 {
    return arena.dupe(u8,
        \\// A Playwright spec. The FLOW list shows every test('…') below, and Run executes them all.
        \\// `+ Endpoint` writes a test that NAMES a saved request: `send(request, 'collection/request')`.
        \\// The active environment's variables are `process.env.<NAME>`, and `{{name}}` in the saved request.
        \\import { test, expect } from '@playwright/test';
        \\
        \\test('first test', async ({ request }) => {
        \\  const r = await request.get('/');
        \\  expect(r.ok()).toBeTruthy();
        \\});
        \\
    );
}

// One test built from a saved request: the ref it names, which the helper resolves when the run starts.
pub fn requestTest(arena: Allocator, name: []const u8, ref: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "test('");
    try quoted(arena, &out, name);
    try out.appendSlice(arena, "', async ({ request }) => {\n  const r = await send(request, '");
    try quoted(arena, &out, ref);
    try out.appendSlice(arena, "');\n  expect(r.ok()).toBeTruthy();\n});\n");
    // Owned, not `items`: a caller frees this, and an ArrayList's buffer is bigger than its length.
    return out.toOwnedSlice(arena);
}

// The spec with the helper's import put on top, or null when it already has it: a test cannot name a ref without it.
pub fn missingImport(arena: Allocator, source: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, source, "'../kurir/index'") != null) return null;
    if (std.mem.indexOf(u8, source, "\"../kurir/index\"") != null) return null;
    return try std.mem.concat(arena, u8, &.{ helper_import, "\n\n", source });
}

// Text inside a single-quoted JavaScript string: a quote or a backslash is escaped, and no newline survives.
fn quoted(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| {
        if (byte == '\'' or byte == '\\') try out.append(arena, '\\');
        try out.append(arena, if (byte == '\n' or byte == '\r') ' ' else byte);
    }
}

const testing = std.testing;

// The human's own file, verbatim in its first lines.
const sample =
    \\import { test, expect } from '@playwright/test';
    \\
    \\test('should create a bug report', async ({ request }) => {
    \\  const newIssue = await request.post(`/repos/${USER}/${REPO}/issues`, {
    \\    data: {
    \\      title: '[Bug] report 1',
    \\      body: 'Bug description',
    \\    }
    \\  });
    \\  expect(newIssue.ok()).toBeTruthy();
    \\});
    \\
    \\test("a second one", async ({ request }) => {
    \\  expect((await request.get('/ok')).status()).toBe(200);
    \\});
;

test "a spec lists its tests by name and line, and a describe group is not one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tests = try parse(arena, sample);
    try testing.expectEqual(@as(usize, 2), tests.len);
    try testing.expectEqualStrings("should create a bug report", tests[0].name);
    try testing.expectEqual(@as(usize, 3), tests[0].line);
    try testing.expectEqualStrings("a second one", tests[1].name);
    try testing.expectEqual(@as(usize, 13), tests[1].line);

    const groups = try parse(arena,
        \\test.describe('a group', () => {
        \\  test('inside', async ({ request }) => {});
        \\});
        \\// test('commented out', async () => {});
    );
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("inside", groups[0].name);

    // The variants that still run a test are listed; the ones that are not tests are not.
    const variants = try parse(arena,
        \\test.only('only one', async ({ request }) => {});
        \\test.skip('skipped', async ({ request }) => {});
        \\test.beforeEach(async ({ request }) => {});
        \\test.step('a step', async () => {});
    );
    try testing.expectEqual(@as(usize, 2), variants.len);
    try testing.expectEqualStrings("only one", variants[0].name);
    try testing.expectEqualStrings("skipped", variants[1].name);
}

test "a generated request test is a test the parser finds again, and it names a ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const generated = try requestTest(arena, "it's ok", "billing/ok");
    const tests = try parse(arena, generated);
    try testing.expectEqual(@as(usize, 1), tests.len);
    try testing.expectEqualStrings("it's ok", tests[0].name);
    // The test carries a NAME, not a URL: the run resolves it against the saved collection.
    try testing.expect(std.mem.indexOf(u8, generated, "send(request, 'billing/ok')") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "request.get(") == null);

    // The helper's import is added once, and a spec that already has it is left alone.
    try testing.expectEqualStrings(helper_import, (try missingImport(arena, "test('x', async () => {});")).?[0..helper_import.len]);
    try testing.expect(try missingImport(arena, "import { send } from '../kurir/index';\n") == null);
}

test "the starter is a spec with one test a person can edit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try starter(arena);
    const tests = try parse(arena, text);
    try testing.expectEqual(@as(usize, 1), tests.len);
    try testing.expectEqualStrings("first test", tests[0].name);
    try testing.expect(std.mem.indexOf(u8, text, "process.env") != null);
    // The starter has no ref of its own, so it does not import the helper: + Endpoint adds it.
    try testing.expect(try missingImport(arena, text) != null);
}
