// A small Lua-flavoured script for a request's Pre-req and Post-res: `local`, `if`, `..`, and the `pm.*` calls a Postman paste needs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// The longest script a field accepts: a paste bigger than this belongs in a file of its own.
pub const max_bytes: usize = 32 * 1024;

// One response header as the script reads it; the caller maps its own type into this one.
pub const Header = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

// What a post-response script can read. A pre-request script is handed null.
pub const Response = struct {
    status: u16 = 0,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

// The only two things a script can do to the app: read a variable and write one.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    get_fn: ?*const fn (?*anyopaque, name: []const u8) ?[]const u8 = null,
    set_fn: ?*const fn (?*anyopaque, name: []const u8, value: []const u8) bool = null,
};

// Where a script went wrong: the line the person can see in the field, and a sentence that says what to do.
pub const Diagnostic = struct {
    line: u32 = 1,
    message: []const u8 = "",
};

pub const Result = struct {
    // Every `print` line, in order, newline-terminated.
    logs: []const u8 = "",
    // Null when the script ran to its end.
    failure: ?Diagnostic = null,
    // How many variables the script wrote, which is what the status line reports.
    sets: usize = 0,
    // Every `test(...)` the script made, in order; the caller decides what a failed one means.
    tests: []const Test = &.{},
};

// One assertion a script made: what it calls itself, and whether the condition held.
pub const Test = struct {
    name: []const u8 = "",
    passed: bool = false,
};

// A value a script can hold: the five Lua primitives plus a node of the response's JSON.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    json: std.json.Value,
};

// ---- the tokens -------------------------------------------------------------------------------------------

const Token = struct {
    tag: Tag = .eof,
    text: []const u8 = "",
    number: f64 = 0,
    line: u32 = 1,

    const Tag = enum { eof, name, number, string, symbol };

    fn isSymbol(t: Token, text: []const u8) bool {
        return t.tag == .symbol and std.mem.eql(u8, t.text, text);
    }

    fn isName(t: Token, text: []const u8) bool {
        return t.tag == .name and std.mem.eql(u8, t.text, text);
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNamePart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// The two-character symbols, longest first, so `..` is never read as two dots.
const two_char_symbols = [_][]const u8{ "==", "~=", "<=", ">=", ".." };

const Lexer = struct {
    source: []const u8,
    arena: Allocator,
    pos: usize = 0,
    line: u32 = 1,

    fn next(self: *Lexer) ScriptError!Token {
        try self.skipSpace();
        if (self.pos >= self.source.len) return .{ .line = self.line };
        const start = self.pos;
        const line = self.line;
        const c = self.source[self.pos];
        if (isNameStart(c)) {
            self.pos += 1;
            while (self.pos < self.source.len and isNamePart(self.source[self.pos])) self.pos += 1;
            return .{ .tag = .name, .text = self.source[start..self.pos], .line = line };
        }
        if (std.ascii.isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1]))) {
            self.pos += 1;
            while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.')) self.pos += 1;
            const text = self.source[start..self.pos];
            const number = std.fmt.parseFloat(f64, text) catch return error.Script;
            return .{ .tag = .number, .text = text, .number = number, .line = line };
        }
        if (c == '"' or c == '\'') return self.stringLiteral(c, line);
        if (self.pos + 1 < self.source.len) {
            const pair = self.source[self.pos .. self.pos + 2];
            for (two_char_symbols) |symbol| {
                if (!std.mem.eql(u8, pair, symbol)) continue;
                self.pos += 2;
                return .{ .tag = .symbol, .text = symbol, .line = line };
            }
        }
        self.pos += 1;
        return .{ .tag = .symbol, .text = self.source[start..self.pos], .line = line };
    }

    // A quoted run with the four escapes a script needs; a plain run is returned as it stands.
    fn stringLiteral(self: *Lexer, quote: u8, line: u32) ScriptError!Token {
        self.pos += 1;
        const start = self.pos;
        var escaped = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                escaped = true;
                self.pos += 2;
                continue;
            }
            if (c == quote) break;
            if (c == '\n') self.line += 1;
            self.pos += 1;
        }
        if (self.pos >= self.source.len) return error.Unterminated;
        const raw = self.source[start..self.pos];
        self.pos += 1;
        if (!escaped) return .{ .tag = .string, .text = raw, .line = line };
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\' or i + 1 >= raw.len) {
                try out.append(self.arena, raw[i]);
                continue;
            }
            i += 1;
            const decoded: u8 = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => raw[i],
            };
            try out.append(self.arena, decoded);
        }
        return .{ .tag = .string, .text = try out.toOwnedSlice(self.arena), .line = line };
    }

    // Whitespace, `--` line comments and `--[[ ]]` block comments: none of them reaches the parser.
    fn skipSpace(self: *Lexer) ScriptError!void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n') {
                self.line += 1;
                self.pos += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
                continue;
            }
            if (c != '-' or self.pos + 1 >= self.source.len or self.source[self.pos + 1] != '-') return;
            self.pos += 2;
            if (self.pos + 1 < self.source.len and self.source[self.pos] == '[' and self.source[self.pos + 1] == '[') {
                self.pos += 2;
                while (self.pos + 1 < self.source.len) {
                    if (self.source[self.pos] == ']' and self.source[self.pos + 1] == ']') {
                        self.pos += 2;
                        break;
                    }
                    if (self.source[self.pos] == '\n') self.line += 1;
                    self.pos += 1;
                }
                continue;
            }
            while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
        }
    }
};

// ---- the interpreter ---------------------------------------------------------------------------------------

const Local = struct {
    name: []const u8,
    value: Value,
};

const ScriptError = error{ Script, OutOfMemory, Unterminated };

// The calls a script may make, by the name it writes: a chain is joined with dots and looked up whole.
const builtin_heads = [_][]const u8{ "pm", "print", "console", "test" };

// No loops, so the only thing this bounds is a pathological paste.
const max_steps: usize = 10_000;

const Interp = struct {
    arena: Allocator,
    lexer: Lexer,
    tok: Token = .{},
    response: ?Response = null,
    host: Host = .{},
    locals: std.ArrayList(Local) = .empty,
    logs: std.ArrayList(u8) = .empty,
    json_root: ?std.json.Value = null,
    sets: usize = 0,
    tests: std.ArrayList(Test) = .empty,
    steps: usize = 0,
    call_line: u32 = 1,
    failure: ?Diagnostic = null,

    fn execute(self: *Interp) ScriptError!void {
        try self.advance();
        while (self.tok.tag != .eof) try self.statement(true);
    }

    fn advance(self: *Interp) ScriptError!void {
        self.tok = self.lexer.next() catch |err| switch (err) {
            error.Unterminated => return self.failAt(self.lexer.line, "unterminated string: close the quote", .{}),
            error.Script => return self.failAtt("a number here is not a number", .{}),
            else => return error.OutOfMemory,
        };
    }

    // A failure carries the message in the run's own arena, so it outlives this frame.
    fn failAt(self: *Interp, line: u32, comptime fmt: []const u8, args: anytype) ScriptError {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch "the script could not run";
        if (self.failure == null) self.failure = .{ .line = line, .message = message };
        return error.Script;
    }

    fn failAtt(self: *Interp, comptime fmt: []const u8, args: anytype) ScriptError {
        return self.failAt(self.tok.line, fmt, args);
    }

    // The line of the call being made: a call reports its own line, not the one the next statement starts on.
    fn failCall(self: *Interp, comptime fmt: []const u8, args: anytype) ScriptError {
        return self.failAt(self.call_line, fmt, args);
    }

    // ---- statements ----

    fn statement(self: *Interp, exec: bool) ScriptError!void {
        self.steps += 1;
        if (self.steps > max_steps) return self.failAtt("this script is too long to run; split it", .{});
        if (self.tok.isSymbol(";")) return self.advance();
        if (self.tok.isName("local")) return self.localStatement(exec);
        if (self.tok.isName("if")) return self.ifStatement(exec);
        if (self.tok.isName("for") or self.tok.isName("while") or self.tok.isName("function")) {
            return self.failAtt("'{s}' is not part of this script language: use straight lines and if/else", .{self.tok.text});
        }
        if (self.tok.tag == .name) {
            if (isBuiltinHead(self.tok.text)) {
                _ = try self.builtinChain(exec);
                return;
            }
            return self.assignment(exec);
        }
        return self.failAtt("expected a statement: local NAME = value, or a pm.* call", .{});
    }

    fn localStatement(self: *Interp, exec: bool) ScriptError!void {
        try self.advance();
        if (self.tok.tag != .name) return self.failAtt("expected a name after 'local'", .{});
        const name = self.tok.text;
        try self.advance();
        if (!self.tok.isSymbol("=")) return self.failAtt("expected '=' after 'local {s}'", .{name});
        try self.advance();
        const value = try self.expr(exec);
        if (!exec) return;
        if (self.locals.items.len >= 256) return self.failAtt("too many variables; a script this big belongs in an app", .{});
        try self.locals.append(self.arena, .{ .name = name, .value = value });
    }

    fn assignment(self: *Interp, exec: bool) ScriptError!void {
        const name = self.tok.text;
        const line = self.tok.line;
        try self.advance();
        if (!self.tok.isSymbol("=")) return self.failAtt("expected '=' after '{s}'; only a local can be assigned", .{name});
        try self.advance();
        const value = try self.expr(exec);
        if (!exec) return;
        for (self.locals.items) |*local| {
            if (!std.mem.eql(u8, local.name, name)) continue;
            local.value = value;
            return;
        }
        return self.failAt(line, "unknown variable '{s}'; declare it with local", .{name});
    }

    fn ifStatement(self: *Interp, exec: bool) ScriptError!void {
        try self.advance();
        const condition = try self.expr(exec);
        if (!self.tok.isName("then")) return self.failAtt("expected 'then' after the condition", .{});
        try self.advance();
        var done = exec and truthy(condition);
        try self.block(done);
        while (self.tok.isName("elseif")) {
            try self.advance();
            const other = try self.expr(exec);
            if (!self.tok.isName("then")) return self.failAtt("expected 'then' after the condition", .{});
            try self.advance();
            const branch = exec and !done and truthy(other);
            try self.block(branch);
            done = done or branch;
        }
        if (self.tok.isName("else")) {
            try self.advance();
            try self.block(exec and !done);
        }
        if (!self.tok.isName("end")) return self.failAtt("expected 'end' to close the if", .{});
        try self.advance();
    }

    fn block(self: *Interp, exec: bool) ScriptError!void {
        while (self.tok.tag != .eof and !self.tok.isName("end") and !self.tok.isName("else") and !self.tok.isName("elseif")) {
            try self.statement(exec);
        }
    }

    // ---- expressions ----

    fn expr(self: *Interp, exec: bool) ScriptError!Value {
        return self.comparison(exec);
    }

    fn comparison(self: *Interp, exec: bool) ScriptError!Value {
        const left = try self.concat(exec);
        const op = self.tok;
        const known = op.isSymbol("==") or op.isSymbol("~=") or op.isSymbol("<") or
            op.isSymbol("<=") or op.isSymbol(">") or op.isSymbol(">=");
        if (!known) return left;
        try self.advance();
        const right = try self.concat(exec);
        if (!exec) return .nil;
        return .{ .boolean = try self.compare(op.text, left, right) };
    }

    fn compare(self: *Interp, op: []const u8, left: Value, right: Value) ScriptError!bool {
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "~=")) {
            const same = try self.equal(left, right);
            return if (std.mem.eql(u8, op, "==")) same else !same;
        }
        if (left == .number and right == .number) {
            const a = left.number;
            const b = right.number;
            if (std.mem.eql(u8, op, "<")) return a < b;
            if (std.mem.eql(u8, op, "<=")) return a <= b;
            if (std.mem.eql(u8, op, ">")) return a > b;
            return a >= b;
        }
        if (left == .string and right == .string) {
            const order = std.mem.order(u8, left.string, right.string);
            if (std.mem.eql(u8, op, "<")) return order == .lt;
            if (std.mem.eql(u8, op, "<=")) return order != .gt;
            if (std.mem.eql(u8, op, ">")) return order == .gt;
            return order != .lt;
        }
        return self.failAtt("'{s}' compares two numbers or two strings, and this is {s} and {s}", .{ op, typeName(left), typeName(right) });
    }

    fn equal(self: *Interp, left: Value, right: Value) ScriptError!bool {
        if (left == .number and right == .number) return left.number == right.number;
        if (left == .boolean and right == .boolean) return left.boolean == right.boolean;
        if (left == .nil and right == .nil) return true;
        if (left == .nil or right == .nil) return false;
        return std.mem.eql(u8, try self.toText(left), try self.toText(right));
    }

    fn concat(self: *Interp, exec: bool) ScriptError!Value {
        const left = try self.additive(exec);
        if (!self.tok.isSymbol("..")) return left;
        try self.advance();
        const right = try self.concat(exec);
        if (!exec) return .nil;
        const text = std.fmt.allocPrint(self.arena, "{s}{s}", .{ try self.toText(left), try self.toText(right) });
        return .{ .string = text catch return error.OutOfMemory };
    }

    fn additive(self: *Interp, exec: bool) ScriptError!Value {
        var left = try self.multiply(exec);
        while (self.tok.isSymbol("+") or self.tok.isSymbol("-")) {
            const op = self.tok.text;
            try self.advance();
            const right = try self.multiply(exec);
            if (!exec) continue;
            left = .{ .number = try self.arithmetic(op, left, right) };
        }
        return left;
    }

    fn multiply(self: *Interp, exec: bool) ScriptError!Value {
        var left = try self.unary(exec);
        while (self.tok.isSymbol("*") or self.tok.isSymbol("/")) {
            const op = self.tok.text;
            try self.advance();
            const right = try self.unary(exec);
            if (!exec) continue;
            left = .{ .number = try self.arithmetic(op, left, right) };
        }
        return left;
    }

    fn arithmetic(self: *Interp, op: []const u8, left: Value, right: Value) ScriptError!f64 {
        if (left != .number or right != .number) {
            return self.failAtt("'{s}' works on numbers, and this is {s} and {s}", .{ op, typeName(left), typeName(right) });
        }
        if (std.mem.eql(u8, op, "+")) return left.number + right.number;
        if (std.mem.eql(u8, op, "-")) return left.number - right.number;
        if (std.mem.eql(u8, op, "*")) return left.number * right.number;
        if (right.number == 0) return self.failAtt("dividing by zero", .{});
        return left.number / right.number;
    }

    fn unary(self: *Interp, exec: bool) ScriptError!Value {
        if (self.tok.isName("not")) return self.failAtt("'not' is not part of this script language yet", .{});
        if (!self.tok.isSymbol("-")) return self.primary(exec);
        try self.advance();
        const inner = try self.unary(exec);
        if (!exec) return .nil;
        if (inner != .number) return self.failAtt("'-' works on a number, and this is {s}", .{typeName(inner)});
        return .{ .number = -inner.number };
    }

    fn primary(self: *Interp, exec: bool) ScriptError!Value {
        const tok = self.tok;
        if (tok.tag == .number) {
            try self.advance();
            return if (exec) .{ .number = tok.number } else .nil;
        }
        if (tok.tag == .string) {
            try self.advance();
            return if (exec) .{ .string = tok.text } else .nil;
        }
        if (tok.tag == .name) {
            // A call's result is a value too, so `pm.response.json().token` reads a field of the answer.
            if (isBuiltinHead(tok.text)) return self.postfix(exec, try self.builtinChain(exec));
            if (tok.isName("true") or tok.isName("false") or tok.isName("nil")) {
                try self.advance();
                if (!exec) return .nil;
                if (tok.isName("nil")) return .nil;
                return .{ .boolean = tok.isName("true") };
            }
            try self.advance();
            const value: Value = if (exec)
                self.lookup(tok.text) orelse return self.failAt(tok.line, "unknown variable '{s}'; declare it with local", .{tok.text})
            else
                .nil;
            return self.postfix(exec, value);
        }
        if (tok.isSymbol("(")) {
            try self.advance();
            const value = try self.expr(exec);
            if (!self.tok.isSymbol(")")) return self.failAtt("expected ')'", .{});
            try self.advance();
            return self.postfix(exec, value);
        }
        if (tok.tag == .symbol and (tok.isSymbol("+") or tok.isSymbol("*") or tok.isSymbol("/"))) {
            return self.failAtt("'{s}' needs a value on its left", .{tok.text});
        }
        return self.failAtt("expected a value: a string, a number, true/false/nil, or a name", .{});
    }

    // `a.b`, `a["b"]` and `a[0]`: the only way into the response's JSON.
    fn postfix(self: *Interp, exec: bool, base: Value) ScriptError!Value {
        var value = base;
        while (true) {
            if (self.tok.isSymbol(".")) {
                try self.advance();
                if (self.tok.tag != .name) return self.failAtt("expected a field name after '.'", .{});
                const field = self.tok.text;
                try self.advance();
                if (self.tok.isSymbol("(")) return self.failAtt("'{s}' is not a call; only pm.*, print and test can be called", .{field});
                if (exec) value = try self.fieldOf(value, field);
                continue;
            }
            if (self.tok.isSymbol("[")) {
                try self.advance();
                const index = try self.expr(exec);
                if (!self.tok.isSymbol("]")) return self.failAtt("expected ']'", .{});
                try self.advance();
                if (exec) value = try self.indexOf(value, index);
                continue;
            }
            return value;
        }
    }

    fn fieldOf(self: *Interp, base: Value, field: []const u8) ScriptError!Value {
        switch (base) {
            .json => |node| return switch (node) {
                .object => |object| if (object.get(field)) |child| Value{ .json = child } else .nil,
                .array => |list| if (parseIndex(field)) |index| arrayItem(list, index) else .nil,
                else => .nil,
            },
            .nil => return self.failAtt("'{s}' is nil: the value it comes from is missing", .{field}),
            else => return self.failAtt("'{s}' has no fields; it is {s}", .{ field, typeName(base) }),
        }
    }

    fn indexOf(self: *Interp, base: Value, index: Value) ScriptError!Value {
        if (base == .string) {
            if (index != .number) return self.failAtt("a string is indexed by a number", .{});
            const at: usize = if (index.number < 0) 0 else @intFromFloat(index.number);
            if (at >= base.string.len) return .nil;
            return .{ .string = base.string[at .. at + 1] };
        }
        if (base != .json) return self.failAtt("this {s} cannot be indexed", .{typeName(base)});
        return switch (base.json) {
            .object => |object| switch (index) {
                .string => |key| if (object.get(key)) |child| Value{ .json = child } else .nil,
                else => self.failAtt("an object is indexed by a string key", .{}),
            },
            .array => |list| switch (index) {
                .number => |n| arrayItem(list, if (n < 0) 0 else @as(usize, @intFromFloat(n))),
                else => self.failAtt("an array is indexed by a number, 0-based like the JSON", .{}),
            },
            else => self.failAtt("this value holds no fields to index", .{}),
        };
    }

    fn lookup(self: *Interp, name: []const u8) ?Value {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i].value;
        }
        return null;
    }

    // ---- the pm.* calls ----

    fn builtinChain(self: *Interp, exec: bool) ScriptError!Value {
        const line = self.tok.line;
        var parts: [6][]const u8 = undefined;
        var count: usize = 0;
        parts[count] = self.tok.text;
        count += 1;
        try self.advance();
        while (self.tok.isSymbol(".")) {
            if (count == parts.len) return self.failAtt("this chain is too deep", .{});
            try self.advance();
            if (self.tok.tag != .name) return self.failAtt("expected a name after '.'", .{});
            parts[count] = self.tok.text;
            count += 1;
            try self.advance();
        }
        const name = try joinChain(self.arena, parts[0..count]);
        self.call_line = line;
        if (self.tok.isSymbol("(")) {
            try self.advance();
            var args: std.ArrayList(Value) = .empty;
            if (!self.tok.isSymbol(")")) {
                while (true) {
                    const arg = try self.expr(exec);
                    try args.append(self.arena, arg);
                    if (!self.tok.isSymbol(",")) break;
                    try self.advance();
                }
            }
            if (!self.tok.isSymbol(")")) return self.failAtt("expected ')' to close the call", .{});
            try self.advance();
            if (!exec) return .nil;
            return self.call(name, args.items);
        }
        if (!exec) return .nil;
        return self.property(name);
    }

    fn property(self: *Interp, name: []const u8) ScriptError!Value {
        if (std.mem.eql(u8, name, "pm.response.code")) {
            const response = self.response orelse return self.failCall("pm.response is only available in a post-response script", .{});
            return .{ .number = @floatFromInt(response.status) };
        }
        if (std.mem.eql(u8, name, "pm.response.status")) return self.failCall("use pm.response.code for the status number", .{});
        return self.failCall("'{s}' is not a value; add () to call it, or use pm.response.code", .{name});
    }

    fn call(self: *Interp, name: []const u8, args: []const Value) ScriptError!Value {
        if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "console.log")) return self.print(args);
        if (std.mem.eql(u8, name, "test")) return self.recordTest(args);
        if (std.mem.eql(u8, name, "pm.response.json")) {
            if (args.len != 0) return self.failCall("pm.response.json() takes no arguments", .{});
            return self.responseJson();
        }
        if (std.mem.eql(u8, name, "pm.response.text")) {
            if (args.len != 0) return self.failCall("pm.response.text() takes no arguments", .{});
            const response = self.response orelse return self.failCall("pm.response is only available in a post-response script", .{});
            return .{ .string = response.body };
        }
        if (std.mem.eql(u8, name, "pm.response.headers.get")) return self.responseHeader(args);
        if (isGetter(name)) {
            if (args.len != 1) return self.failCall("{s} takes the variable name", .{name});
            const variable = try self.toText(args[0]);
            const found = self.host.get_fn orelse return .nil;
            const text = found(self.host.ctx, variable) orelse return .nil;
            return .{ .string = try self.arena.dupe(u8, text) };
        }
        if (std.mem.eql(u8, name, "pm.environment.set") or std.mem.eql(u8, name, "pm.globals.set")) {
            if (args.len != 2) return self.failCall("{s} takes a name and a value", .{name});
            const variable = try self.toText(args[0]);
            const value = try self.toText(args[1]);
            const setter = self.host.set_fn orelse return self.failCall("this app cannot store variables", .{});
            if (!setter(self.host.ctx, variable, value)) return self.failCall("no environment is active to store '{s}' in", .{variable});
            self.sets += 1;
            return .nil;
        }
        if (std.mem.eql(u8, name, "pm.environment.unset")) return self.failCall("pm.environment.unset is not part of this script language yet", .{});
        return self.failCall("'{s}' is not available in a script; see the hint under the field", .{name});
    }

    fn print(self: *Interp, args: []const Value) ScriptError!Value {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (i > 0) try self.logs.append(self.arena, '\t');
            try self.logs.appendSlice(self.arena, try self.toText(args[i]));
        }
        try self.logs.append(self.arena, '\n');
        return .nil;
    }

    // `test("status is 200", pm.response.code == 200)`: one assertion, kept so a run can be judged by it.
    fn recordTest(self: *Interp, args: []const Value) ScriptError!Value {
        if (args.len != 2) return self.failCall("test takes a name and a condition", .{});
        const label = try self.toText(args[0]);
        try self.tests.append(self.arena, .{ .name = label, .passed = truthy(args[1]) });
        return .nil;
    }

    fn responseHeader(self: *Interp, args: []const Value) ScriptError!Value {
        if (args.len != 1) return self.failCall("pm.response.headers.get takes the header name", .{});
        const name = try self.toText(args[0]);
        const response = self.response orelse return self.failCall("pm.response is only available in a post-response script", .{});
        for (response.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
            return .{ .string = header.value };
        }
        return .nil;
    }

    // The body parsed once and kept: every later field read walks the same tree.
    fn responseJson(self: *Interp) ScriptError!Value {
        const response = self.response orelse return self.failCall("pm.response is only available in a post-response script", .{});
        if (self.json_root) |root| return .{ .json = root };
        if (response.body.len == 0) return self.failCall("pm.response.json(): the response body is empty", .{});
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, response.body, .{}) catch
            return self.failCall("pm.response.json(): the response body is not JSON", .{});
        self.json_root = root;
        return .{ .json = root };
    }

    // ---- values ----

    fn toText(self: *Interp, value: Value) ScriptError![]const u8 {
        return switch (value) {
            .nil => "",
            .boolean => |on| if (on) "true" else "false",
            .number => |number| try std.fmt.allocPrint(self.arena, "{d}", .{number}),
            .string => |text| text,
            .json => |node| try self.jsonText(node),
        };
    }

    fn jsonText(self: *Interp, node: std.json.Value) ScriptError![]const u8 {
        return switch (node) {
            .string => |text| text,
            .integer => |number| try std.fmt.allocPrint(self.arena, "{d}", .{number}),
            .float => |number| try std.fmt.allocPrint(self.arena, "{d}", .{number}),
            .number_string => |text| text,
            .bool => |on| if (on) "true" else "false",
            .null => "",
            else => try std.fmt.allocPrint(self.arena, "{f}", .{std.json.fmt(node, .{})}),
        };
    }
};

fn isBuiltinHead(name: []const u8) bool {
    for (builtin_heads) |head| {
        if (std.mem.eql(u8, name, head)) return true;
    }
    return false;
}

fn isGetter(name: []const u8) bool {
    return std.mem.eql(u8, name, "pm.environment.get") or
        std.mem.eql(u8, name, "pm.globals.get") or
        std.mem.eql(u8, name, "pm.variables.get");
}

fn truthy(value: Value) bool {
    return switch (value) {
        .nil => false,
        .boolean => |on| on,
        .number => |number| number != 0,
        .string => |text| text.len > 0,
        .json => |node| switch (node) {
            .null => false,
            .bool => |on| on,
            else => true,
        },
    };
}

fn typeName(value: Value) []const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => "a boolean",
        .number => "a number",
        .string => "a string",
        .json => "a response value",
    };
}

fn joinChain(arena: Allocator, parts: []const []const u8) ScriptError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, index| {
        if (index > 0) try out.append(arena, '.');
        try out.appendSlice(arena, part);
    }
    return out.toOwnedSlice(arena);
}

fn parseIndex(text: []const u8) ?usize {
    if (text.len == 0) return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

fn arrayItem(list: std.json.Array, index: usize) Value {
    if (index >= list.items.len) return .nil;
    return .{ .json = list.items[index] };
}

// Run `source` with `response` (null in a Pre-req) and `host`, allocating everything from `arena`.
pub fn run(arena: Allocator, source: []const u8, response: ?Response, host: Host) Result {
    if (source.len > max_bytes) {
        return .{ .failure = .{ .line = 1, .message = "this script is longer than 32 KB" } };
    }
    var interp = Interp{
        .arena = arena,
        .lexer = .{ .source = source, .arena = arena },
        .response = response,
        .host = host,
    };
    interp.execute() catch |err| {
        const failure: Diagnostic = interp.failure orelse .{
            .line = interp.tok.line,
            .message = if (err == error.OutOfMemory) "not enough memory to run this script" else "the script could not run",
        };
        return .{ .logs = interp.logs.items, .failure = failure, .sets = interp.sets, .tests = interp.tests.items };
    };
    return .{ .logs = interp.logs.items, .sets = interp.sets, .tests = interp.tests.items };
}

// What a caller prints under the field: one line a person can act on.
pub fn describe(arena: Allocator, failure: Diagnostic) []const u8 {
    return std.fmt.allocPrint(arena, "line {d}: {s}", .{ failure.line, failure.message }) catch failure.message;
}

// ---- tests -------------------------------------------------------------------------------------------------

const Fake = struct {
    arena: Allocator,
    sets: std.ArrayList(Pair) = .empty,
    vars: std.ArrayList(Pair) = .empty,

    const Pair = struct { name: []const u8, value: []const u8 };

    fn add(self: *Fake, name: []const u8, value: []const u8) !void {
        try self.vars.append(self.arena, .{ .name = name, .value = value });
    }

    fn host(self: *Fake) Host {
        return .{ .ctx = self, .get_fn = getVar, .set_fn = setVar };
    }

    fn getVar(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        for (self.vars.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }

    fn setVar(ctx: ?*anyopaque, name: []const u8, value: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.sets.append(self.arena, .{ .name = name, .value = value }) catch return false;
        return true;
    }
};

const body_with_token = "{\"access_token\":\"abc123\",\"expires_in\":3600}";

test "the Postman snippet reads the token out of the answer and sets it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\local jsonData = pm.response.json()
        \\-- Set the token as a variable
        \\pm.globals.set("token", jsonData.access_token)
        \\print("Access Token: " .. jsonData.access_token)
    ;
    const result = run(arena, source, .{ .status = 200, .body = body_with_token }, fake.host());

    try testing.expect(result.failure == null);
    try testing.expectEqual(@as(usize, 1), result.sets);
    try testing.expectEqualStrings("token", fake.sets.items[0].name);
    try testing.expectEqualStrings("abc123", fake.sets.items[0].value);
    try testing.expectEqualStrings("Access Token: abc123\n", result.logs);
}

test "a script with no output is a script that ran" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\-- nothing to do yet
        \\--[[ a block comment
        \\     spans two lines ]]
    ;
    const result = run(arena, source, null, fake.host());
    try testing.expect(result.failure == null);
    try testing.expectEqual(@as(usize, 0), result.sets);
    try testing.expectEqualStrings("", result.logs);
}

test "if/else runs the branch the status chose, and only that one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\if pm.response.code == 200 then
        \\  pm.environment.set("state", "ok")
        \\else
        \\  pm.environment.set("state", "bad")
        \\end
    ;
    const ok = run(arena, source, .{ .status = 200, .body = "{}" }, fake.host());
    try testing.expect(ok.failure == null);
    try testing.expectEqual(@as(usize, 1), fake.sets.items.len);
    try testing.expectEqualStrings("ok", fake.sets.items[0].value);

    fake.sets.clearRetainingCapacity();
    const bad = run(arena, source, .{ .status = 500, .body = "{}" }, fake.host());
    try testing.expect(bad.failure == null);
    try testing.expectEqual(@as(usize, 1), fake.sets.items.len);
    try testing.expectEqualStrings("bad", fake.sets.items[0].value);
}

test "text, code and a header are all readable, and a header name ignores case" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const headers = [_]Header{.{ .name = "Content-Type", .value = "application/json" }};
    const source =
        \\pm.environment.set("ct", pm.response.headers.get("content-type"))
        \\pm.environment.set("code", pm.response.code)
        \\pm.environment.set("raw", pm.response.text())
    ;
    const result = run(arena, source, .{ .status = 204, .headers = &headers, .body = "hello" }, fake.host());
    try testing.expect(result.failure == null);
    try testing.expectEqualStrings("application/json", fake.sets.items[0].value);
    try testing.expectEqualStrings("204", fake.sets.items[1].value);
    try testing.expectEqualStrings("hello", fake.sets.items[2].value);
}

test "a variable the environment holds is readable, and a missing one is nil" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };
    try fake.add("base", "https://api.test");

    const source =
        \\local base = pm.environment.get("base")
        \\local missing = pm.variables.get("nope")
        \\pm.environment.set("url", base .. "/v1/charges")
        \\pm.environment.set("empty", "[" .. missing .. "]")
    ;
    const result = run(arena, source, .{ .status = 200, .body = "{}" }, fake.host());
    try testing.expect(result.failure == null);
    try testing.expectEqualStrings("https://api.test/v1/charges", fake.sets.items[0].value);
    try testing.expectEqualStrings("[]", fake.sets.items[1].value);
}

test "numbers flow through arithmetic into a value a variable can hold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\local a = 1 + 2 * 3
        \\a = a + 1
        \\pm.environment.set("a", a)
        \\pm.environment.set("half", 9 / 2)
        \\pm.environment.set("negative", -4)
    ;
    const result = run(arena, source, null, fake.host());
    try testing.expect(result.failure == null);
    try testing.expectEqualStrings("8", fake.sets.items[0].value);
    try testing.expectEqualStrings("4.5", fake.sets.items[1].value);
    try testing.expectEqualStrings("-4", fake.sets.items[2].value);
}

test "a body that is not JSON names the line that asked for it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\local ok = pm.response.text()
        \\local data = pm.response.json()
        \\pm.environment.set("token", data.token)
    ;
    const result = run(arena, source, .{ .status = 200, .body = "<html>not json</html>" }, fake.host());
    const failure = result.failure orelse return error.TestExpectedDiagnostic;
    try testing.expectEqual(@as(u32, 2), failure.line);
    try testing.expectEqualStrings("pm.response.json(): the response body is not JSON", failure.message);
    try testing.expectEqual(@as(usize, 0), result.sets);
}

test "the response is not available before the send" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const result = run(arena, "local data = pm.response.json()", null, fake.host());
    const failure = result.failure orelse return error.TestExpectedDiagnostic;
    try testing.expectEqualStrings("pm.response is only available in a post-response script", failure.message);
}

test "a call outside the language says so, with its line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\local data = pm.response.json()
        \\pm.sendRequest("https://example.com")
    ;
    const result = run(arena, source, .{ .status = 200, .body = "{}" }, fake.host());
    const failure = result.failure orelse return error.TestExpectedDiagnostic;
    try testing.expectEqual(@as(u32, 2), failure.line);
    try testing.expect(std.mem.indexOf(u8, failure.message, "not available in a script") != null);
}

test "loops and function definitions are refused, not misread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const loop = run(arena, "for i = 1, 3 do print(i) end", null, fake.host());
    try testing.expect(loop.failure != null);
    try testing.expect(std.mem.indexOf(u8, loop.failure.?.message, "'for'") != null);

    const call = run(arena, "local f = function() end", null, fake.host());
    try testing.expect(call.failure != null);
}

test "an unknown variable and an unterminated string are both a line and a sentence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const unknown = run(arena, "pm.environment.set(\"x\", nothing)", null, fake.host());
    try testing.expect(unknown.failure != null);
    try testing.expectEqual(@as(u32, 1), unknown.failure.?.line);
    try testing.expect(std.mem.indexOf(u8, unknown.failure.?.message, "unknown variable 'nothing'") != null);

    const unterminated = run(arena, "local a = 1\nlocal b = \"oops", null, fake.host());
    try testing.expect(unterminated.failure != null);
    try testing.expect(std.mem.indexOf(u8, unterminated.failure.?.message, "unterminated string") != null);
}

test "a whole JSON object lands in a variable as JSON text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .arena = arena };

    const source =
        \\local data = pm.response.json()
        \\pm.environment.set("user", data.user)
        \\pm.environment.set("first", data.roles[0])
    ;
    const result = run(arena, source, .{ .status = 200, .body = "{\"user\":{\"id\":7},\"roles\":[\"admin\",\"dev\"]}" }, fake.host());
    try testing.expect(result.failure == null);
    try testing.expectEqualStrings("{\"id\":7}", fake.sets.items[0].value);
    try testing.expectEqualStrings("admin", fake.sets.items[1].value);
}

test "describe turns a diagnostic into the line a person reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = describe(arena, .{ .line = 4, .message = "expected 'end'" });
    try testing.expectEqualStrings("line 4: expected 'end'", text);
}
