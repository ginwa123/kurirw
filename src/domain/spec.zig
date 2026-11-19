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

// The starter a new runner holds: a comment that says where the environment goes, and one test to edit.
pub fn starter(arena: Allocator) Allocator.Error![]u8 {
    return arena.dupe(u8,
        \\// A Playwright spec. The FLOW list shows every test('…') below, and Run executes them all.
        \\// `request` is Playwright's API client; the active environment's variables are `process.env.<NAME>`.
        \\import { test, expect } from '@playwright/test';
        \\
        \\test('first test', async ({ request }) => {
        \\  const r = await request.get('/');
        \\  expect(r.ok()).toBeTruthy();
        \\});
        \\
    );
}

// One test built from a saved request: its method, its URL, and an assertion that the call did not fail.
pub fn requestTest(arena: Allocator, name: []const u8, method: []const u8, url: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const verb = verbOf(method);
    try out.appendSlice(arena, "test('");
    try quoted(arena, &out, name);
    try out.appendSlice(arena, "', async ({ request }) => {\n");
    if (verb) |call| {
        try out.appendSlice(arena, "  const r = await request.");
        try out.appendSlice(arena, call);
        try out.appendSlice(arena, "('");
        try quoted(arena, &out, url);
        try out.appendSlice(arena, "');\n");
    } else {
        // A verb with no shorthand on APIRequestContext goes through fetch, with the method spelled out.
        try out.appendSlice(arena, "  const r = await request.fetch('");
        try quoted(arena, &out, url);
        try out.appendSlice(arena, "', { method: '");
        try out.appendSlice(arena, method);
        try out.appendSlice(arena, "' });\n");
    }
    try out.appendSlice(arena, "  expect(r.ok()).toBeTruthy();\n});\n");
    return out.items;
}

// The APIRequestContext shorthand for a verb, or null when it has none.
fn verbOf(method: []const u8) ?[]const u8 {
    const verbs = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD" };
    const calls = [_][]const u8{ "get", "post", "put", "patch", "delete", "head" };
    for (verbs, calls) |verb, call| {
        if (std.ascii.eqlIgnoreCase(method, verb)) return call;
    }
    return null;
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

test "a generated request test is a test the parser finds again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const generated = try requestTest(arena, "it's ok", "GET", "http://127.0.0.1:8099/ok");
    const tests = try parse(arena, generated);
    try testing.expectEqual(@as(usize, 1), tests.len);
    try testing.expectEqualStrings("it's ok", tests[0].name);
    try testing.expect(std.mem.indexOf(u8, generated, "request.get('http://127.0.0.1:8099/ok')") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "expect(r.ok()).toBeTruthy()") != null);

    // A verb without a shorthand goes through fetch, and OPTIONS keeps its own spelling.
    const options = try requestTest(arena, "preflight", "OPTIONS", "https://api.test/a");
    try testing.expect(std.mem.indexOf(u8, options, "request.fetch('https://api.test/a', { method: 'OPTIONS' })") != null);
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
}
