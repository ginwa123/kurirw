//! Postman Collection v2.1, kept as a JSON value tree so a round trip keeps every field Kurir does not model.
const std = @import("std");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;
pub const Array = std.json.Array;
pub const Allocator = std.mem.Allocator;

pub const schema_url = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json";

// The verbs the editor offers, in the order the method bar draws them.
pub const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

pub const default_method = "GET";
pub const max_method_len: usize = 8;

// ---- reading -------------------------------------------------------------------------------------------------

// A collection is the object Postman puts `info` on; that is the only thing that tells it apart from a folder.
pub fn isCollection(v: Value) bool {
    if (v != .object) return false;
    const info = v.object.get("info") orelse return false;
    return info == .object;
}

// An item that holds requests is a folder; one that holds a request is a request.
pub fn isRequest(v: Value) bool {
    if (v != .object) return false;
    return v.object.get("request") != null;
}

pub fn isFolder(v: Value) bool {
    if (v != .object) return false;
    if (isRequest(v)) return false;
    return v.object.get("item") != null;
}

pub fn str(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const child_value = v.object.get(key) orelse return "";
    return if (child_value == .string) child_value.string else "";
}

pub fn boolean(v: Value, key: []const u8) bool {
    if (v != .object) return false;
    const child_value = v.object.get(key) orelse return false;
    return if (child_value == .bool) child_value.bool else false;
}

pub fn child(v: *Value, key: []const u8) ?*Value {
    if (v.* != .object) return null;
    return v.object.getPtr(key);
}

pub fn itemCount(v: Value) usize {
    if (v != .object) return 0;
    const items = v.object.get("item") orelse return 0;
    if (items != .array) return 0;
    return items.array.items.len;
}

pub fn itemAt(v: Value, index: usize) ?Value {
    if (v != .object) return null;
    const items = v.object.get("item") orelse return null;
    if (items != .array) return null;
    if (index >= items.array.items.len) return null;
    return items.array.items[index];
}

// The method exactly as the tree and the method bar should show it: one of `methods`, or the default.
pub fn normalizeMethod(raw: []const u8) []const u8 {
    for (methods) |m| {
        if (std.ascii.eqlIgnoreCase(raw, m)) return m;
    }
    return default_method;
}

pub fn urlRaw(request: Value) []const u8 {
    if (request != .object) return "";
    const url = request.object.get("url") orelse return "";
    if (url == .string) return url.string;
    if (url == .object) return str(url, "raw");
    return "";
}

pub fn headerCount(item: Value) usize {
    if (item != .object) return 0;
    const request = item.object.get("request") orelse return 0;
    if (request != .object) return 0;
    const headers = request.object.get("header") orelse return 0;
    if (headers != .array) return 0;
    return headers.array.items.len;
}

pub const HeaderView = struct {
    key: []const u8 = "",
    value: []const u8 = "",
    disabled: bool = false,
};

pub const RequestView = struct {
    method: []const u8 = default_method,
    url: []const u8 = "",
    body: []const u8 = "",
    body_mode: []const u8 = "",
    headers: []const HeaderView = &.{},
};

// Everything the editor draws for one request item. The strings are borrowed from the document arena.
pub fn requestView(alloc: Allocator, item: Value) !RequestView {
    var out = RequestView{};
    if (item != .object) return out;
    const request = item.object.get("request") orelse return out;
    if (request == .string) {
        out.url = request.string;
        return out;
    }
    if (request != .object) return out;

    out.method = normalizeMethod(str(request, "method"));
    out.url = urlRaw(request);

    var list: std.ArrayList(HeaderView) = .empty;
    if (request.object.get("header")) |headers| {
        if (headers == .array) {
            for (headers.array.items) |h| {
                if (h != .object) continue;
                try list.append(alloc, .{
                    .key = str(h, "key"),
                    .value = str(h, "value"),
                    .disabled = boolean(h, "disabled"),
                });
            }
        }
    }
    out.headers = try list.toOwnedSlice(alloc);

    if (request.object.get("body")) |body| {
        if (body == .object) {
            out.body_mode = str(body, "mode");
            if (std.mem.eql(u8, out.body_mode, "raw")) out.body = str(body, "raw");
        }
    }
    return out;
}

// ---- writing: the primitives every mutation goes through -----------------------------------------------------

// The child at `key`, created when it is missing, and always an object afterwards.
pub fn objectChild(alloc: Allocator, parent: *Value, key: []const u8) !*Value {
    if (parent.* != .object) parent.* = .{ .object = .empty };
    if (parent.object.getPtr(key)) |found| {
        if (found.* != .object) found.* = .{ .object = .empty };
        return found;
    }
    try parent.object.put(alloc, key, .{ .object = .empty });
    return parent.object.getPtr(key).?;
}

// The child at `key`, created when it is missing, and always an array afterwards.
pub fn arrayChild(alloc: Allocator, parent: *Value, key: []const u8) !*Array {
    if (parent.* != .object) parent.* = .{ .object = .empty };
    if (parent.object.getPtr(key)) |found| {
        if (found.* != .array) found.* = .{ .array = Array.init(alloc) };
        return &found.array;
    }
    try parent.object.put(alloc, key, .{ .array = Array.init(alloc) });
    return &parent.object.getPtr(key).?.array;
}

// Every string the document holds is a copy: the caller's buffer (a field, a slice of a file) does not outlive it.
fn own(alloc: Allocator, text: []const u8) ![]const u8 {
    return alloc.dupe(u8, text);
}

pub fn setString(alloc: Allocator, parent: *Value, key: []const u8, text: []const u8) !void {
    const slot = try objectChild(alloc, parent, key);
    slot.* = .{ .string = try own(alloc, text) };
}

pub fn setBool(alloc: Allocator, parent: *Value, key: []const u8, on: bool) !void {
    if (parent.* != .object) parent.* = .{ .object = .empty };
    try parent.object.put(alloc, key, .{ .bool = on });
}

// ---- writing: collections, folders, requests -----------------------------------------------------------------

// 32 lowercase hex characters from 16 random bytes. The caller supplies the bytes, so this module stays io-free.
pub fn makeId(alloc: Allocator, raw: [16]u8) ![]u8 {
    const bytes = try alloc.alloc(u8, 32);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        bytes[i * 2] = hex[b >> 4];
        bytes[i * 2 + 1] = hex[b & 0x0f];
    }
    return bytes;
}

pub fn newCollection(alloc: Allocator, name: []const u8, postman_id: []const u8) !Value {
    var info: Object = .empty;
    try info.put(alloc, "_postman_id", .{ .string = try own(alloc, postman_id) });
    try info.put(alloc, "name", .{ .string = try own(alloc, name) });
    try info.put(alloc, "schema", .{ .string = schema_url });

    var collection: Object = .empty;
    try collection.put(alloc, "info", .{ .object = info });
    try collection.put(alloc, "item", .{ .array = Array.init(alloc) });
    return .{ .object = collection };
}

pub fn newFolder(alloc: Allocator, name: []const u8) !Value {
    var folder: Object = .empty;
    try folder.put(alloc, "name", .{ .string = try own(alloc, name) });
    try folder.put(alloc, "item", .{ .array = Array.init(alloc) });
    return .{ .object = folder };
}

pub fn newRequest(alloc: Allocator, name: []const u8, method: []const u8, url: []const u8) !Value {
    var request: Object = .empty;
    try request.put(alloc, "method", .{ .string = try own(alloc, normalizeMethod(method)) });
    try request.put(alloc, "header", .{ .array = Array.init(alloc) });
    try request.put(alloc, "url", try urlValue(alloc, url));
    try request.put(alloc, "body", try rawBody(alloc, ""));

    var item: Object = .empty;
    try item.put(alloc, "name", .{ .string = try own(alloc, name) });
    try item.put(alloc, "request", .{ .object = request });
    try item.put(alloc, "response", .{ .array = Array.init(alloc) });
    return .{ .object = item };
}

// `{ mode: "raw", raw: "", options: { raw: { language: "json" } } }`, the shape the PRD pins.
pub fn rawBody(alloc: Allocator, raw: []const u8) !Value {
    var language: Object = .empty;
    try language.put(alloc, "language", .{ .string = "json" });
    var options: Object = .empty;
    try options.put(alloc, "raw", .{ .object = language });

    var body: Object = .empty;
    try body.put(alloc, "mode", .{ .string = "raw" });
    try body.put(alloc, "raw", .{ .string = try own(alloc, raw) });
    try body.put(alloc, "options", .{ .object = options });
    return .{ .object = body };
}

// ---- the URL object ------------------------------------------------------------------------------------------

// Split a raw URL into the parts Postman keeps beside it. Anything unparsable keeps only `raw`.
pub fn urlValue(alloc: Allocator, raw: []const u8) !Value {
    var url: Object = .empty;
    try url.put(alloc, "raw", .{ .string = try own(alloc, raw) });
    if (raw.len == 0) return .{ .object = url };

    const uri = std.Uri.parse(raw) catch return .{ .object = url };

    try url.put(alloc, "protocol", .{ .string = try own(alloc, uri.scheme) });
    if (uri.host) |host| {
        var host_array: Array = .init(alloc);
        var labels = std.mem.splitScalar(u8, host.percent_encoded, '.');
        while (labels.next()) |label| try host_array.append(.{ .string = try own(alloc, label) });
        try url.put(alloc, "host", .{ .array = host_array });
    }
    if (uri.port) |port| {
        const port_text = try std.fmt.allocPrint(alloc, "{d}", .{port});
        try url.put(alloc, "port", .{ .string = port_text });
    }
    var path_array: Array = .init(alloc);
    var segments = std.mem.splitScalar(u8, uri.path.percent_encoded, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        try path_array.append(.{ .string = try own(alloc, segment) });
    }
    try url.put(alloc, "path", .{ .array = path_array });
    if (uri.query) |query| {
        var query_array: Array = .init(alloc);
        var pairs = std.mem.splitScalar(u8, query.percent_encoded, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            var entry: Object = .empty;
            try entry.put(alloc, "key", .{ .string = try own(alloc, pair[0..eq]) });
            try entry.put(alloc, "value", .{ .string = try own(alloc, if (eq < pair.len) pair[eq + 1 ..] else "") });
            try query_array.append(.{ .object = entry });
        }
        if (query_array.items.len > 0) try url.put(alloc, "query", .{ .array = query_array });
    }
    return .{ .object = url };
}

// The URL a transport should actually fetch: a bare host gets a scheme, because every client wants one.
pub fn effectiveUrl(buffer: []u8, raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.mem.indexOf(u8, trimmed, "://") != null) return trimmed;
    return std.fmt.bufPrint(buffer, "http://{s}", .{trimmed}) catch trimmed;
}

// ---- writing: the editor's mutations ------------------------------------------------------------------------

// The request object of an item, created when the item is a bare `{ name }`.
fn requestChild(alloc: Allocator, item: *Value) !*Value {
    return objectChild(alloc, item, "request");
}

pub fn setName(alloc: Allocator, item: *Value, name: []const u8) !void {
    try setString(alloc, item, "name", name);
}

pub fn setMethod(alloc: Allocator, item: *Value, method: []const u8) !void {
    const request = try requestChild(alloc, item);
    try setString(alloc, request, "method", normalizeMethod(method));
}

pub fn setUrl(alloc: Allocator, item: *Value, raw: []const u8) !void {
    const request = try requestChild(alloc, item);
    if (request.* != .object) request.* = .{ .object = .empty };
    try request.object.put(alloc, "url", try urlValue(alloc, raw));
}

pub fn setBodyRaw(alloc: Allocator, item: *Value, raw: []const u8) !void {
    const request = try requestChild(alloc, item);
    const body = try objectChild(alloc, request, "body");
    try setString(alloc, body, "mode", "raw");
    try setString(alloc, body, "raw", raw);
    const options = try objectChild(alloc, body, "options");
    const raw_options = try objectChild(alloc, options, "raw");
    if (str(raw_options.*, "language").len == 0) try setString(alloc, raw_options, "language", "json");
}

pub fn setHeaderEnabled(alloc: Allocator, item: *Value, index: usize, enabled: bool) !void {
    const headers = try arrayChild(alloc, try requestChild(alloc, item), "header");
    if (index >= headers.items.len) return;
    if (headers.items[index] != .object) headers.items[index] = .{ .object = .empty };
    try setBool(alloc, &headers.items[index], "disabled", !enabled);
}

// True when Postman marked this header disabled, which means "keep it, do not send it".
pub fn headerDisabled(item: Value, index: usize) bool {
    if (item != .object) return false;
    const request = item.object.get("request") orelse return false;
    if (request != .object) return false;
    const headers = request.object.get("header") orelse return false;
    if (headers != .array) return false;
    if (index >= headers.array.items.len) return false;
    return boolean(headers.array.items[index], "disabled");
}

// Grow the header array so `index` exists, then return that entry as an object.
pub fn ensureHeader(alloc: Allocator, item: *Value, index: usize) !*Value {
    const headers = try arrayChild(alloc, try requestChild(alloc, item), "header");
    while (headers.items.len <= index) try headers.append(.{ .object = .empty });
    if (headers.items[index] != .object) headers.items[index] = .{ .object = .empty };
    return &headers.items[index];
}

pub fn setHeaderKey(alloc: Allocator, item: *Value, index: usize, key: []const u8) !void {
    const entry = try ensureHeader(alloc, item, index);
    try setString(alloc, entry, "key", key);
}

pub fn setHeaderValue(alloc: Allocator, item: *Value, index: usize, value: []const u8) !void {
    const entry = try ensureHeader(alloc, item, index);
    try setString(alloc, entry, "value", value);
}

pub fn removeHeader(item: *Value, index: usize) void {
    if (item.* != .object) return;
    const request = item.object.getPtr("request") orelse return;
    if (request.* != .object) return;
    const found = request.object.getPtr("header") orelse return;
    if (found.* != .array) return;
    if (index >= found.array.items.len) return;
    _ = found.array.orderedRemove(index);
}

// ---- writing: the tree --------------------------------------------------------------------------------------

pub fn appendChild(alloc: Allocator, parent: *Value, child_value: Value) !usize {
    const items = try arrayChild(alloc, parent, "item");
    try items.append(child_value);
    return items.items.len - 1;
}

pub fn removeChild(alloc: Allocator, parent: *Value, index: usize) void {
    const items = arrayChild(alloc, parent, "item") catch return;
    if (index >= items.items.len) return;
    _ = items.orderedRemove(index);
}

// ---- serializing ---------------------------------------------------------------------------------------------

pub fn write(alloc: Allocator, value: Value, pretty: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = if (pretty) .indent_2 else .minified }, &out.writer);
    return out.toOwnedSlice();
}

pub fn parseTree(alloc: Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, alloc, bytes, .{ .duplicate_field_behavior = .use_last });
}

// ---- tests ---------------------------------------------------------------------------------------------------

const fixture =
    \\{
    \\  "info": {
    \\    "_postman_id": "3f1c8f0e-1111-4a2b-9c3d-000000000001",
    \\    "name": "Payments",
    \\    "description": "Vendor field we must keep",
    \\    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
    \\  },
    \\  "auth": { "type": "bearer", "bearer": [ { "key": "token", "value": "{{token}}" } ] },
    \\  "event": [ { "listen": "prerequest", "script": { "exec": ["console.log(1)"], "type": "text/javascript" } } ],
    \\  "item": [
    \\    {
    \\      "name": "Checkout",
    \\      "item": [
    \\        {
    \\          "name": "Create charge",
    \\          "request": {
    \\            "method": "POST",
    \\            "header": [ { "key": "Content-Type", "value": "application/json" } ],
    \\            "body": { "mode": "raw", "raw": "{\"amount\":100}", "options": { "raw": { "language": "json" } } },
    \\            "url": {
    \\              "raw": "https://api.example.com/v1/charges?expand=customer",
    \\              "protocol": "https",
    \\              "host": ["api", "example", "com"],
    \\              "path": ["v1", "charges"],
    \\              "query": [ { "key": "expand", "value": "customer" } ]
    \\            }
    \\          },
    \\          "response": [],
    \\          "protocolProfileBehavior": { "disableBodyPruning": true }
    \\        }
    \\      ]
    \\    },
    \\    { "name": "Health", "request": { "method": "GET", "url": "https://api.example.com/health" } }
    \\  ],
    \\  "variable": [ { "key": "base_url", "value": "https://api.example.com" } ]
    \\}
;

fn loadFixture(arena: Allocator) !Value {
    return parseTree(arena, fixture);
}

fn firstRequest(doc: *Value) !*Value {
    const items = doc.object.getPtr("item") orelse return error.NoItems;
    const folder = &items.array.items[0];
    const inner = folder.object.getPtr("item") orelse return error.NoItems;
    return &inner.array.items[0];
}

test "a collection is recognised, and a request is not a folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try loadFixture(arena);
    try std.testing.expect(isCollection(doc));
    try std.testing.expectEqual(@as(usize, 2), itemCount(doc));

    const folder = itemAt(doc, 0).?;
    try std.testing.expect(isFolder(folder));
    try std.testing.expect(!isRequest(folder));

    const request = itemAt(doc, 1).?;
    try std.testing.expect(isRequest(request));
    try std.testing.expect(!isFolder(request));
}

test "a request reads back as the editor needs it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try loadFixture(arena);
    const item = itemAt(itemAt(doc, 0).?, 0).?;
    const view = try requestView(arena, item);

    try std.testing.expectEqualStrings("POST", view.method);
    try std.testing.expectEqualStrings("https://api.example.com/v1/charges?expand=customer", view.url);
    try std.testing.expectEqualStrings("{\"amount\":100}", view.body);
    try std.testing.expectEqual(@as(usize, 1), view.headers.len);
    try std.testing.expectEqualStrings("Content-Type", view.headers[0].key);
    try std.testing.expect(!view.headers[0].disabled);
}

test "a plain-string url, a missing request and an unknown method all read safely" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parseTree(arena,
        \\{ "info": { "name": "x" }, "item": [
        \\  { "name": "Health", "request": { "method": "GET", "url": "https://api.example.com/health" } },
        \\  { "name": "Weird", "request": { "method": "TRACE" } },
        \\  { "name": "Folder", "item": [] }
        \\] }
    );

    const health = try requestView(arena, itemAt(doc, 0).?);
    try std.testing.expectEqualStrings("https://api.example.com/health", health.url);
    try std.testing.expectEqual(@as(usize, 0), health.headers.len);

    const weird = try requestView(arena, itemAt(doc, 1).?);
    try std.testing.expectEqualStrings(default_method, weird.method);
    try std.testing.expectEqualStrings("", weird.url);

    const folder = itemAt(doc, 2).?;
    try std.testing.expect(isFolder(folder));
    const folder_view = try requestView(arena, folder);
    try std.testing.expectEqual(@as(usize, 0), folder_view.headers.len);
}

test "the url object splits into protocol, host, path and query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try urlValue(arena, "https://api.example.com:8443/v1/charges?expand=customer&limit=10");
    try std.testing.expectEqualStrings("https", str(url, "protocol"));
    try std.testing.expectEqualStrings("8443", str(url, "port"));
    try std.testing.expectEqualStrings("https://api.example.com:8443/v1/charges?expand=customer&limit=10", str(url, "raw"));

    const host = url.object.get("host").?;
    try std.testing.expectEqual(@as(usize, 3), host.array.items.len);
    try std.testing.expectEqualStrings("api", host.array.items[0].string);

    const path = url.object.get("path").?;
    try std.testing.expectEqual(@as(usize, 2), path.array.items.len);
    try std.testing.expectEqualStrings("charges", path.array.items[1].string);

    const query = url.object.get("query").?;
    try std.testing.expectEqual(@as(usize, 2), query.array.items.len);
    try std.testing.expectEqualStrings("limit", query.array.items[1].object.get("key").?.string);
    try std.testing.expectEqualStrings("10", query.array.items[1].object.get("value").?.string);
}

test "an unparsable url keeps its raw text and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try urlValue(arena, "api.example.com/charges");
    try std.testing.expectEqualStrings("api.example.com/charges", str(url, "raw"));
    try std.testing.expect(url.object.get("host") == null);

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("http://api.example.com/charges", effectiveUrl(&buffer, "api.example.com/charges"));
    try std.testing.expectEqualStrings("https://a.b", effectiveUrl(&buffer, " https://a.b "));
    try std.testing.expectEqualStrings("", effectiveUrl(&buffer, "   "));
}

test "a new collection, folder and request have the v2.1 shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var collection = try newCollection(arena, "Payments", try makeId(arena, @splat(0xab)));
    try std.testing.expect(isCollection(collection));
    const info = collection.object.get("info").?;
    try std.testing.expectEqualStrings("Payments", str(info, "name"));
    try std.testing.expectEqualStrings(schema_url, str(info, "schema"));
    try std.testing.expectEqualStrings("abababababababababababababababab", str(info, "_postman_id"));

    const folder = try newFolder(arena, "Checkout");
    try std.testing.expect(isFolder(folder));
    _ = try appendChild(arena, &collection, folder);
    try std.testing.expectEqual(@as(usize, 1), itemCount(collection));

    const new_item = try newRequest(arena, "Create charge", "post", "https://api.example.com/v1/charges");
    _ = try appendChild(arena, &collection, new_item);
    try std.testing.expectEqual(@as(usize, 2), itemCount(collection));

    const created = try requestView(arena, itemAt(collection, 1).?);
    try std.testing.expectEqualStrings("POST", created.method);
    try std.testing.expectEqualStrings("https://api.example.com/v1/charges", created.url);
    try std.testing.expectEqual(@as(usize, 0), created.headers.len);

    // A new request always carries the raw-JSON body the PRD pins, empty until the user types.
    const body = itemAt(collection, 1).?.object.get("request").?.object.get("body").?;
    try std.testing.expectEqualStrings("raw", str(body, "mode"));
    try std.testing.expectEqualStrings("json", str(body.object.get("options").?.object.get("raw").?, "language"));
}

test "mutations write through and leave every unknown field alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try loadFixture(arena);
    const item = try firstRequest(&doc);

    try setName(arena, item, "Create charge (v2)");
    try setMethod(arena, item, "patch");
    try setUrl(arena, item, "https://api.example.com/v2/charges");
    try setBodyRaw(arena, item, "{\"amount\":250}");
    try setHeaderKey(arena, item, 0, "X-Idempotency-Key");
    try setHeaderValue(arena, item, 0, "abc");
    try setHeaderKey(arena, item, 1, "Accept");
    try setHeaderValue(arena, item, 1, "application/json");
    try setHeaderEnabled(arena, item, 1, false);

    const bytes = try write(arena, doc, true);
    const reloaded = try parseTree(arena, bytes);

    const request_item = itemAt(itemAt(reloaded, 0).?, 0).?;
    const view = try requestView(arena, request_item);
    try std.testing.expectEqualStrings("Create charge (v2)", str(request_item, "name"));
    try std.testing.expectEqualStrings("PATCH", view.method);
    try std.testing.expectEqualStrings("https://api.example.com/v2/charges", view.url);
    try std.testing.expectEqualStrings("{\"amount\":250}", view.body);
    try std.testing.expectEqual(@as(usize, 2), view.headers.len);
    try std.testing.expectEqualStrings("X-Idempotency-Key", view.headers[0].key);
    try std.testing.expect(view.headers[1].disabled);

    // The fields Kurir never reads are still there after a full round trip.
    try std.testing.expectEqualStrings("Vendor field we must keep", str(reloaded.object.get("info").?, "description"));
    try std.testing.expect(reloaded.object.get("auth") != null);
    try std.testing.expect(reloaded.object.get("event") != null);
    try std.testing.expect(reloaded.object.get("variable") != null);
    try std.testing.expect(request_item.object.get("protocolProfileBehavior") != null);
}

test "removing a header and an item closes the gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try loadFixture(arena);
    const item = try firstRequest(&doc);

    try setHeaderKey(arena, item, 1, "Accept");
    try setHeaderValue(arena, item, 1, "*/*");
    try std.testing.expectEqual(@as(usize, 2), headerCount(item.*));
    removeHeader(item, 0);
    try std.testing.expectEqual(@as(usize, 1), headerCount(item.*));
    try std.testing.expectEqualStrings("Accept", (try requestView(arena, item.*)).headers[0].key);

    try std.testing.expectEqual(@as(usize, 2), itemCount(doc));
    removeChild(arena, &doc, 0);
    try std.testing.expectEqual(@as(usize, 1), itemCount(doc));
    try std.testing.expectEqualStrings("Health", str(itemAt(doc, 0).?, "name"));
}

test "a body and a url survive being set on an item that had neither" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try parseTree(arena, "{\"info\":{\"name\":\"x\"},\"item\":[{\"name\":\"Bare\"}]}");
    const item = &doc.object.getPtr("item").?.array.items[0];

    try setMethod(arena, item, "POST");
    try setUrl(arena, item, "https://api.example.com/x");
    try setBodyRaw(arena, item, "{\"a\":1}");

    const view = try requestView(arena, item.*);
    try std.testing.expectEqualStrings("POST", view.method);
    try std.testing.expectEqualStrings("https://api.example.com/x", view.url);
    try std.testing.expectEqualStrings("{\"a\":1}", view.body);
    const body = item.object.get("request").?.object.get("body").?;
    try std.testing.expectEqualStrings("json", str(body.object.get("options").?.object.get("raw").?, "language"));
}
