//! Environments and the variables a request resolves against. Pure: no window, no file, no network.
const std = @import("std");

const Allocator = std.mem.Allocator;

// One environment variable. `initial` is the value the file keeps for sharing, `current` this machine's.
pub const Variable = struct {
    name: []const u8 = "",
    initial: []const u8 = "",
    current: []const u8 = "",
    secret: bool = false,
};

// What a variable sends: the current value when it has one, else the initial value it was created with.
pub fn value(v: Variable) []const u8 {
    return if (v.current.len > 0) v.current else v.initial;
}

// One named environment — Dev, Staging, Production — and the variables it holds.
pub const Environment = struct {
    name: []const u8 = "",
    vars: []const Variable = &.{},
};

// A name and the value it stands for: what a request or a collection carries.
pub const Pair = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

// What `{{name}}` resolves against, first match wins: the request's own variables, the active environment, its collection.
pub const Scope = struct {
    request: []const Pair = &.{},
    environment: []const Variable = &.{},
    collection: []const Pair = &.{},
};

fn pairValue(pairs: []const Pair, name: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.name, name)) return pair.value;
    }
    return null;
}

fn envValue(vars: []const Variable, name: []const u8) ?[]const u8 {
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, name)) return value(v);
    }
    return null;
}

// The value `name` stands for, or null when nothing defines it.
pub fn lookup(scope: Scope, name: []const u8) ?[]const u8 {
    if (pairValue(scope.request, name)) |value_found| return value_found;
    if (envValue(scope.environment, name)) |value_found| return value_found;
    return pairValue(scope.collection, name);
}

// The environment with that name, or null when the workspace has none.
pub fn named(environments: []const Environment, name: []const u8) ?Environment {
    for (environments) |environment| {
        if (std.mem.eql(u8, environment.name, name)) return environment;
    }
    return null;
}

// Replace every `{{name}}` that has a value. An unknown name, an empty name and an unclosed brace stay as typed.
pub fn expand(alloc: Allocator, text: []const u8, scope: Scope) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            if (std.mem.indexOfPos(u8, text, i + 2, "}}")) |end| {
                const name = std.mem.trim(u8, text[i + 2 .. end], " \t");
                if (name.len > 0) {
                    if (lookup(scope, name)) |replacement| {
                        try out.appendSlice(alloc, replacement);
                    } else {
                        try out.appendSlice(alloc, text[i .. end + 2]);
                    }
                } else {
                    try out.appendSlice(alloc, text[i .. end + 2]);
                }
                i = end + 2;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "a known name is replaced everywhere it appears" {
    const vars = [_]Variable{.{ .name = "token", .current = "abc123" }};
    const got = try expand(testing.allocator, "{{token}}/{{token}}", .{ .environment = &vars });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abc123/abc123", got);
}

test "the current value is what sends, and the initial value is the fallback" {
    const vars = [_]Variable{
        .{ .name = "token", .initial = "shared", .current = "mine" },
        .{ .name = "base", .initial = "https://dev.example.com" },
    };
    const got = try expand(testing.allocator, "{{token}} {{base}}", .{ .environment = &vars });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("mine https://dev.example.com", got);
}

test "the request wins over the environment, which wins over the collection" {
    const request = [_]Pair{.{ .name = "id", .value = "from-request" }};
    const environment = [_]Variable{
        .{ .name = "id", .current = "from-environment" },
        .{ .name = "tenant", .current = "from-environment" },
    };
    const collection = [_]Pair{
        .{ .name = "id", .value = "from-collection" },
        .{ .name = "tenant", .value = "from-collection" },
        .{ .name = "region", .value = "from-collection" },
    };
    const scope = Scope{ .request = &request, .environment = &environment, .collection = &collection };
    try testing.expectEqualStrings("from-request", lookup(scope, "id").?);
    try testing.expectEqualStrings("from-environment", lookup(scope, "tenant").?);
    try testing.expectEqualStrings("from-collection", lookup(scope, "region").?);
    try testing.expectEqual(@as(?[]const u8, null), lookup(scope, "nobody"));
}

test "an unknown name, an empty name and an unclosed brace stay as typed" {
    const vars = [_]Variable{.{ .name = "token", .current = "abc" }};
    const got = try expand(testing.allocator, "{{other}} {{}} {{token", .{ .environment = &vars });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{{other}} {{}} {{token", got);
}

test "spaces inside the braces are ignored and a value is not expanded again" {
    const vars = [_]Variable{
        .{ .name = "a", .current = "{{b}}" },
        .{ .name = "b", .current = "deep" },
    };
    const got = try expand(testing.allocator, "{{ a }}", .{ .environment = &vars });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{{b}}", got);
}

test "a secret is a normal value to the send rule: only the screen hides it" {
    const vars = [_]Variable{.{ .name = "token", .current = "s3cret", .secret = true }};
    const got = try expand(testing.allocator, "Bearer {{token}}", .{ .environment = &vars });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Bearer s3cret", got);
}

test "no environment means no value of its own, and the request still expands its own" {
    const request = [_]Pair{.{ .name = "id", .value = "7" }};
    const got = try expand(testing.allocator, "/items/{{id}}", .{ .request = &request });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/items/7", got);
    // A workspace with no environments has nothing to activate.
    const none = [_]Environment{};
    try testing.expectEqual(@as(?Environment, null), named(&none, "Dev"));
}
