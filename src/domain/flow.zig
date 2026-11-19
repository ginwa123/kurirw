//! A flow: the program a run executes — parsed from its script, written back as that script, expanded into steps.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

// The most a flow may send in one run: a program longer than this is a build script, not a page.
pub const max_steps: usize = 512;

// One item of the program. The UI edits this shape; the script is written from it, and parsed back into it.
pub const Node = union(enum) {
    // `send "collection/name"`: run a saved request, and let the next lines read its answer.
    send: Send,
    // `delay 250`: wait this long after the step above it.
    delay: u32,
    // `repeat N do ... end`
    repeat: Loop,
    // `for row in data do ... end`: one pass per data row.
    each_row: Loop,
    // Any other line: a statement for the script engine (`test(...)`, `pm.environment.set(...)`, `local ...`).
    script: []const u8,
};

pub const Send = struct {
    request: []const u8 = "",
    // The line of the script the send was written on, so a failure points at the program.
    line: usize = 1,
};

pub const Loop = struct {
    count: usize = 1,
    body: []Node = &.{},
};

pub const Diagnostic = struct {
    line: usize = 1,
    message: []const u8 = "",
};

pub const Flow = struct {
    nodes: []const Node = &.{},
    // Set when the script could not be read; `nodes` then holds what parsed before it.
    failure: ?Diagnostic = null,
};

// What the runner executes: one `send` with the statements that run before it and after its answer.
pub const Step = struct {
    request: []const u8 = "",
    line: usize = 1,
    // Wait this long after the step completes (a `delay` written under it).
    delay_ms: u32 = 0,
    // Which data row this copy of the block runs with, when the flow loops over the data file.
    data_row: ?usize = null,
    // Statements between the previous send and this one: they run before it, with no answer to read.
    pre: []const u8 = "",
    // Statements after it: `test(...)` and `pm.environment.set(...)` read this step's answer.
    post: []const u8 = "",
};

// ---- parsing ----------------------------------------------------------------------------------------------

// Read `source` into the program it describes. A one-line diagnostic when a line makes no sense.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!Flow {
    var parser = Parser{ .arena = arena, .lines = try splitLines(arena, source) };
    const nodes = parser.block(0) catch {
        return .{ .nodes = &.{}, .failure = parser.failure };
    };
    return .{ .nodes = nodes, .failure = parser.failure };
}

// One line at a time, so the parser reads a program the way a person does.
fn splitLines(arena: Allocator, source: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| try out.append(arena, std.mem.trimEnd(u8, raw, "\r"));
    return out.items;
}

const ParseError = error{ OutOfMemory, Bad };

const Parser = struct {
    arena: Allocator,
    lines: []const []const u8 = &.{},
    cursor: usize = 0,
    line: usize = 0,
    failure: ?Diagnostic = null,

    fn block(self: *Parser, depth: usize) ParseError![]Node {
        var nodes: std.ArrayList(Node) = .empty;
        while (self.nextLine()) |raw| {
            const text = std.mem.trim(u8, raw, " \t");
            if (text.len == 0 or std.mem.startsWith(u8, text, "--")) continue;
            if (std.mem.eql(u8, text, "end")) {
                if (depth == 0) return self.bad("'end' closes nothing");
                return nodes.items;
            }
            if (std.mem.startsWith(u8, text, "send ")) {
                const name = self.quoted(text[5..]) orelse return self.bad("send takes a quoted request name");
                try nodes.append(self.arena, .{ .send = .{ .request = name, .line = self.line } });
                continue;
            }
            if (std.mem.startsWith(u8, text, "delay ")) {
                const digits = std.mem.trim(u8, text[6..], " \t");
                const value = std.fmt.parseInt(u32, digits, 10) catch return self.bad("delay takes milliseconds");
                try nodes.append(self.arena, .{ .delay = value });
                continue;
            }
            if (std.mem.startsWith(u8, text, "repeat ")) {
                const rest = std.mem.trim(u8, text[7..], " \t");
                if (!std.mem.endsWith(u8, rest, " do")) return self.bad("write it as: repeat N do ... end");
                const digits = std.mem.trim(u8, rest[0 .. rest.len - 3], " \t");
                const count = std.fmt.parseInt(usize, digits, 10) catch return self.bad("repeat takes a count");
                try nodes.append(self.arena, .{ .repeat = .{ .count = count, .body = try self.block(depth + 1) } });
                continue;
            }
            if (std.mem.eql(u8, text, "for row in data do")) {
                try nodes.append(self.arena, .{ .each_row = .{ .body = try self.block(depth + 1) } });
                continue;
            }
            if (std.mem.startsWith(u8, text, "for ")) return self.bad("the only loop is: for row in data do ... end");
            try nodes.append(self.arena, .{ .script = try self.arena.dupe(u8, text) });
        }
        if (depth > 0) return self.bad("this block is not closed with 'end'");
        return nodes.items;
    }

    fn quoted(self: *Parser, raw: []const u8) ?[]const u8 {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return null;
        return self.arena.dupe(u8, text[1 .. text.len - 1]) catch null;
    }

    fn nextLine(self: *Parser) ?[]const u8 {
        if (self.cursor >= self.lines.len) return null;
        const line = self.lines[self.cursor];
        self.cursor += 1;
        self.line = self.cursor;
        return line;
    }

    fn bad(self: *Parser, message: []const u8) ParseError {
        self.failure = .{ .line = self.line, .message = message };
        return error.Bad;
    }
};

// ---- writing ---------------------------------------------------------------------------------------------

// The script a program is written as: two spaces a level, one statement a line.
pub fn write(arena: Allocator, flow: Flow) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeNodes(arena, &out, flow.nodes, 0);
    return out.items;
}

fn writeNodes(arena: Allocator, out: *std.ArrayList(u8), nodes: []const Node, depth: usize) Allocator.Error!void {
    for (nodes) |node| {
        // A loop gets air above it, so the eye finds the block.
        if (node == .repeat or node == .each_row) {
            if (out.items.len > 0) try out.append(arena, '\n');
        }
        switch (node) {
            .send => |send| {
                try indent(arena, out, depth);
                try out.appendSlice(arena, "send \"");
                try out.appendSlice(arena, send.request);
                try out.appendSlice(arena, "\"\n");
            },
            .delay => |ms| {
                try indent(arena, out, depth);
                try out.print(arena, "delay {d}\n", .{ms});
            },
            .script => |text| {
                try indent(arena, out, depth);
                try out.appendSlice(arena, text);
                try out.append(arena, '\n');
            },
            .repeat => |loop| {
                try indent(arena, out, depth);
                try out.print(arena, "repeat {d} do\n", .{loop.count});
                try writeNodes(arena, out, loop.body, depth + 1);
                try indent(arena, out, depth);
                try out.appendSlice(arena, "end\n");
            },
            .each_row => |loop| {
                try indent(arena, out, depth);
                try out.appendSlice(arena, "for row in data do\n");
                try writeNodes(arena, out, loop.body, depth + 1);
                try indent(arena, out, depth);
                try out.appendSlice(arena, "end\n");
            },
        }
    }
}

fn indent(arena: Allocator, out: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(arena, "  ");
}

// ---- expanding into steps ---------------------------------------------------------------------------------

// The steps a run executes: loops are unrolled here, so execution stays one request at a time.
pub fn expand(arena: Allocator, flow: Flow, rows: usize) Allocator.Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    var walker = Walker{ .arena = arena, .steps = &steps, .rows = rows };
    try walker.walk(flow.nodes, null);
    walker.flush();
    return steps.items;
}

const Walker = struct {
    arena: Allocator,
    steps: *std.ArrayList(Step),
    rows: usize,
    current: ?Step = null,
    pre: std.ArrayList(u8) = .empty,
    post: std.ArrayList(u8) = .empty,

    fn walk(self: *Walker, nodes: []const Node, row: ?usize) Allocator.Error!void {
        for (nodes) |node| {
            if (self.steps.items.len >= max_steps) return;
            switch (node) {
                .send => |item| try self.startStep(item, row),
                .script => |text| {
                    // A statement belongs to the send it stands under: before the next one, or after the last.
                    const sink = if (self.current == null) &self.pre else &self.post;
                    try sink.appendSlice(self.arena, text);
                    try sink.append(self.arena, '\n');
                },
                .delay => |ms| {
                    if (self.current) |*step| step.delay_ms = ms;
                },
                .repeat => |loop| {
                    var i: usize = 0;
                    while (i < loop.count) : (i += 1) try self.walk(loop.body, row);
                },
                .each_row => |loop| {
                    // With no data file the body runs once, so a flow is usable before it has rows.
                    const count = if (self.rows == 0) 1 else self.rows;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try self.walk(loop.body, if (self.rows == 0) null else i);
                    }
                },
            }
        }
    }

    fn startStep(self: *Walker, node: Send, row: ?usize) Allocator.Error!void {
        self.flush();
        self.current = .{ .request = node.request, .line = node.line, .data_row = row };
    }

    fn flush(self: *Walker) void {
        const step = self.current orelse return;
        var out = step;
        out.pre = self.pre.toOwnedSlice(self.arena) catch "";
        out.post = self.post.toOwnedSlice(self.arena) catch "";
        self.steps.append(self.arena, out) catch {};
        self.pre = .empty;
        self.post = .empty;
        self.current = null;
    }
};

const testing = std.testing;

// The shape the human drew: one login, then a loop over the data file.
const sample =
    \\-- login dulu, lalu tiga booking dari data file
    \\send "AccessToken/create"
    \\test "token is there", pm.response.json().access_token ~= nil
    \\pm.environment.set("token", pm.response.json().access_token)
    \\
    \\for row in data do
    \\  send "billing/create incentive"
    \\  test "created", pm.response.code == 201
    \\  delay 250
    \\end
;

test "a flow is a send, the statements under it, and a loop over the data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flow = try parse(arena, sample);
    try testing.expect(flow.failure == null);
    try testing.expectEqual(@as(usize, 4), flow.nodes.len);
    try testing.expectEqualStrings("AccessToken/create", flow.nodes[0].send.request);
    try testing.expect(flow.nodes[1] == .script);
    try testing.expect(flow.nodes[2] == .script);
    try testing.expectEqual(@as(usize, 3), flow.nodes[3].each_row.body.len);
}

test "the script is written back from the program, canonically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flow = try parse(arena, sample);
    const text = try write(arena, flow);
    try testing.expectEqualStrings(
        \\send "AccessToken/create"
        \\test "token is there", pm.response.json().access_token ~= nil
        \\pm.environment.set("token", pm.response.json().access_token)
        \\
        \\for row in data do
        \\  send "billing/create incentive"
        \\  test "created", pm.response.code == 201
        \\  delay 250
        \\end
        \\
    , text);

    // Written text parses back to the same shape: the two views cannot drift.
    const again = try parse(arena, text);
    try testing.expectEqual(flow.nodes.len, again.nodes.len);
}

test "the steps unroll the loop, one per data row, each with its own scripts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flow = try parse(arena, sample);
    const steps = try expand(arena, flow, 3);
    // The login, then the booking once per row.
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("AccessToken/create", steps[0].request);
    try testing.expectEqual(@as(?usize, null), steps[0].data_row);
    try testing.expect(std.mem.indexOf(u8, steps[0].post, "test \"token is there\"") != null);
    try testing.expect(std.mem.indexOf(u8, steps[0].post, "pm.environment.set") != null);

    try testing.expectEqualStrings("billing/create incentive", steps[1].request);
    try testing.expectEqual(@as(?usize, 0), steps[1].data_row);
    try testing.expectEqual(@as(?usize, 1), steps[2].data_row.?);
    // `delay 250` under a send is that send's own wait.
    try testing.expectEqual(@as(u32, 250), steps[1].delay_ms);
    try testing.expect(std.mem.indexOf(u8, steps[1].post, "test \"created\"") != null);
}

test "repeat copies a block, and a delay written above the first send belongs to it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\delay 100
        \\repeat 2 do
        \\  send "a"
        \\  send "b"
        \\end
    ;
    const flow = try parse(arena, source);
    try testing.expect(flow.failure == null);
    const steps = try expand(arena, flow, 0);
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("a", steps[0].request);
    try testing.expectEqualStrings("b", steps[1].request);
    try testing.expectEqualStrings("a", steps[2].request);
}

test "a broken program says which line, and still keeps what parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const missing_end = try parse(arena, "for row in data do\n  send \"a\"\n");
    try testing.expect(missing_end.failure != null);
    try testing.expect(std.mem.indexOf(u8, missing_end.failure.?.message, "not closed") != null);

    const bad_send = try parse(arena, "send a\n");
    try testing.expect(bad_send.failure != null);
    try testing.expectEqual(@as(usize, 1), bad_send.failure.?.line);

    const stray_end = try parse(arena, "end\n");
    try testing.expect(stray_end.failure != null);
}

test "a statement before any send waits for the first one, and nothing is lost" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flow = try parse(arena, "local base = pm.environment.get(\"base\")\nsend \"a\"\ntest \"ok\", true\n");
    try testing.expect(flow.failure == null);
    const steps = try expand(arena, flow, 0);
    try testing.expectEqual(@as(usize, 1), steps.len);
    try testing.expect(std.mem.indexOf(u8, steps[0].pre, "local base") != null);
    try testing.expect(std.mem.indexOf(u8, steps[0].post, "test \"ok\"") != null);
}
