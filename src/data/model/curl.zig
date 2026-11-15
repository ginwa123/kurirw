//! A `curl` command line and a request are the same thing said two ways: this file says it both ways.
const std = @import("std");

const postman = @import("postman.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ Empty, NotCurl, MissingUrl, TooLong, OutOfMemory };

pub const max_command: usize = 64 * 1024;
pub const max_headers: usize = 32;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// What a pasted command means: the five things a request is made of, all borrowed from the caller's arena.
pub const Request = struct {
    method: []const u8 = postman.default_method,
    url: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

// Options that consume the next token and that a request cannot carry: swallowing the value keeps it from being read as the URL.
const ignored_with_value = [_][]const u8{
    "--output",      "-o",            "--cookie-jar",      "-c",
    "--proxy",       "-x",            "--proxy-user",      "-U",
    "--max-time",    "-m",            "--connect-timeout", "--write-out",
    "-w",            "--form",        "-F",                "--form-string",
    "--upload-file", "-T",            "--cert",            "-E",
    "--cacert",      "--capath",      "--config",          "-K",
    "--dump-header", "-D",            "--retry",           "--retry-delay",
    "--range",       "-r",            "--resolve",         "--interface",
    "--limit-rate",  "--time-cond",   "-z",                "--oauth2-bearer",
    "--aws-sigv4",   "--header-file", "--data-file",       "--trace",
    "--trace-ascii", "--stderr",      "--output-dir",      "--json-file",
};

// Flags that change nothing a request stores: `-s` quiet, `-L` follow, `-k` insecure, and friends.
const ignored_flags = [_][]const u8{
    "-s",        "--silent",           "-S",                      "--show-error", "-k",                  "--insecure",
    "-L",        "--location",         "-i",                      "--include",    "-v",                  "--verbose",
    "-f",        "--fail",             "--fail-with-body",        "--compressed", "-g",                  "--globoff",
    "--http1.1", "--http2",            "--http2-prior-knowledge", "--http3",      "--no-progress-meter", "--progress-bar",
    "-#",        "--no-buffer",        "-N",                      "--tlsv1.2",    "--tlsv1.3",           "--ssl-no-revoke",
    "--no-alpn", "--location-trusted",
};

fn listHas(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn isIgnoreWithValue(token: []const u8) bool {
    if (listHas(&ignored_with_value, token)) return true;
    // `--max-time=5` and `--proxy=http://…` carry their value inline, so nothing extra to swallow.
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    return listHas(&ignored_with_value, token[0..eq]);
}

fn isIgnoredFlag(token: []const u8) bool {
    if (listHas(&ignored_flags, token)) return true;
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    return listHas(&ignored_flags, token[0..eq]);
}

// A line continuation is a backslash (or a cmd.exe caret) followed by a newline: one command, many lines.
fn joinContinuations(arena: Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null and std.mem.indexOfScalar(u8, text, '^') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        const next = if (i + 1 < text.len) text[i + 1] else 0;
        const doubled = (ch == '\\' or ch == '^') and (next == '\n' or next == '\r');
        if (doubled) {
            i += if (next == '\r' and i + 2 < text.len and text[i + 2] == '\n') 3 else 2;
            try out.append(arena, ' ');
            continue;
        }
        try out.append(arena, ch);
        i += 1;
    }
    return out.items;
}

// Shell word splitting for the shapes curl commands are pasted in: bare words, 'single', "double", and backslash escapes.
fn tokenize(arena: Allocator, text: []const u8) Error!std.ArrayList([]const u8) {
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
        if (i >= text.len) break;
        var word: std.ArrayList(u8) = .empty;
        while (i < text.len) {
            const ch = text[i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break;
            if (ch == '\'') {
                i += 1;
                while (i < text.len and text[i] != '\'') : (i += 1) try word.append(arena, text[i]);
                i += 1;
                continue;
            }
            if (ch == '"') {
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) {
                        const esc = text[i + 1];
                        if (esc == '"' or esc == '\\' or esc == '$' or esc == '`') {
                            try word.append(arena, esc);
                            i += 1;
                            continue;
                        }
                    }
                    try word.append(arena, text[i]);
                }
                i += 1;
                continue;
            }
            if (ch == '\\' and i + 1 < text.len) {
                try word.append(arena, text[i + 1]);
                i += 2;
                continue;
            }
            try word.append(arena, ch);
            i += 1;
        }
        try tokens.append(arena, try word.toOwnedSlice(arena));
    }
    return tokens;
}

// A `name: value` header, split on the first colon and trimmed the way curl trims it.
fn parseHeader(line: []const u8) ?Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    if (name.len == 0) return null;
    return .{ .name = name, .value = std.mem.trimStart(u8, line[colon + 1 ..], " \t") };
}

fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

fn withScheme(arena: Allocator, url: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, url, "://") != null) return url;
    return std.fmt.allocPrint(arena, "http://{s}", .{url});
}

fn appendQuery(arena: Allocator, url: []const u8, query: []const u8) Error![]const u8 {
    if (query.len == 0) return url;
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, url, '?') != null) "&" else "?";
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ url, sep, query });
}

// ── parse ──────────────────────────────────────────────────────────────────────────────────────────────

pub fn parse(arena: Allocator, command: []const u8) Error!Request {
    const text = std.mem.trim(u8, command, " \t\r\n");
    if (text.len == 0) return error.Empty;
    if (text.len > max_command) return error.TooLong;

    const tokens = try tokenize(arena, try joinContinuations(arena, text));
    const words = tokens.items;
    if (words.len == 0) return error.Empty;

    var start: usize = 0;
    // A pasted prompt (`$ curl …`, `PS> curl …`) and the platform's `curl.exe` are the same command.
    while (start < words.len and (std.mem.eql(u8, words[start], "$") or std.mem.eql(u8, words[start], ">"))) start += 1;
    if (start >= words.len) return error.Empty;
    const program = std.fs.path.basename(words[start]);
    if (!std.mem.startsWith(u8, program, "curl")) return error.NotCurl;
    start += 1;

    var method: []const u8 = "";
    var url: []const u8 = "";
    var body: []const u8 = "";
    var wants_head = false;
    var wants_get = false;
    var headers: std.ArrayList(Header) = .empty;

    var i = start;
    while (i < words.len) : (i += 1) {
        const word = words[i];
        const value_next: ?[]const u8 = if (i + 1 < words.len) words[i + 1] else null;

        if (std.mem.eql(u8, word, "-X") or std.mem.eql(u8, word, "--request")) {
            if (value_next) |v| {
                method = v;
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-H") or std.mem.eql(u8, word, "--header")) {
            if (value_next) |v| {
                if (parseHeader(v)) |h| {
                    if (headers.items.len < max_headers) try headers.append(arena, h);
                }
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "--url")) {
            if (value_next) |v| {
                url = v;
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-d") or std.mem.eql(u8, word, "--data") or
            std.mem.eql(u8, word, "--data-raw") or std.mem.eql(u8, word, "--data-binary") or
            std.mem.eql(u8, word, "--data-ascii") or std.mem.eql(u8, word, "--data-urlencode") or
            std.mem.eql(u8, word, "--json"))
        {
            if (value_next) |v| {
                body = if (body.len == 0) v else try std.fmt.allocPrint(arena, "{s}&{s}", .{ body, v });
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-u") or std.mem.eql(u8, word, "--user")) {
            if (value_next) |v| {
                try addBasicAuth(arena, &headers, v);
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-b") or std.mem.eql(u8, word, "--cookie")) {
            if (value_next) |v| {
                try headers.append(arena, .{ .name = "Cookie", .value = v });
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-A") or std.mem.eql(u8, word, "--user-agent")) {
            if (value_next) |v| {
                try headers.append(arena, .{ .name = "User-Agent", .value = v });
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-e") or std.mem.eql(u8, word, "--referer")) {
            if (value_next) |v| {
                try headers.append(arena, .{ .name = "Referer", .value = v });
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, word, "-I") or std.mem.eql(u8, word, "--head")) {
            wants_head = true;
            continue;
        }
        if (std.mem.eql(u8, word, "-G") or std.mem.eql(u8, word, "--get")) {
            wants_get = true;
            continue;
        }
        if (isIgnoreWithValue(word)) {
            if (std.mem.indexOfScalar(u8, word, '=') == null) i += 1;
            continue;
        }
        if (isIgnoredFlag(word)) continue;
        if (word.len > 0 and word[0] == '-') continue;
        if (url.len == 0) url = word;
    }

    if (url.len == 0) return error.MissingUrl;

    var final_url = try withScheme(arena, url);
    if (wants_get) {
        final_url = try appendQuery(arena, final_url, body);
        body = "";
    }

    const final_method: []const u8 = if (method.len > 0)
        postman.normalizeMethod(method)
    else if (wants_head)
        "HEAD"
    else if (wants_get)
        "GET"
    else if (body.len > 0)
        "POST"
    else
        postman.default_method;

    if (body.len > 0 and !hasHeader(headers.items, "content-type")) {
        const looks_json = std.mem.startsWith(u8, std.mem.trimStart(u8, body, " \t\r\n"), "{") or
            std.mem.startsWith(u8, std.mem.trimStart(u8, body, " \t\r\n"), "[");
        try headers.append(arena, .{
            .name = "content-type",
            .value = if (looks_json) "application/json" else "application/x-www-form-urlencoded",
        });
    }

    return .{
        .method = final_method,
        .url = final_url,
        .headers = headers.items,
        .body = body,
    };
}

fn addBasicAuth(arena: Allocator, headers: *std.ArrayList(Header), pair: []const u8) Error!void {
    const encoded_len = std.base64.standard.Encoder.calcSize(pair.len);
    const buf = try arena.alloc(u8, encoded_len);
    const encoded = std.base64.standard.Encoder.encode(buf, pair);
    try headers.append(arena, .{
        .name = "Authorization",
        .value = try std.fmt.allocPrint(arena, "Basic {s}", .{encoded}),
    });
}

// ── format ────────────────────────────────────────────────────────────────────────────────────────────

// One shell word: single quotes keep every byte literal, and a quote inside becomes the four-byte dance.
fn quote(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice(arena, "'\\''");
            continue;
        }
        try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

pub fn format(arena: Allocator, request: Request) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "curl");
    // curl already defaults to GET, so only a non-GET method is worth a flag.
    if (!std.ascii.eqlIgnoreCase(request.method, postman.default_method)) {
        try out.appendSlice(arena, " -X ");
        try out.appendSlice(arena, request.method);
    }
    for (request.headers) |h| {
        try out.appendSlice(arena, " \\\n  -H ");
        try out.appendSlice(arena, try quote(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value })));
    }
    try out.appendSlice(arena, " \\\n  ");
    try out.appendSlice(arena, try quote(arena, request.url));
    if (request.body.len > 0) {
        try out.appendSlice(arena, " \\\n  --data-raw ");
        try out.appendSlice(arena, try quote(arena, request.body));
    }
    return out.items;
}

// ── tests ─────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseWithArena(arena: Allocator, text: []const u8) !Request {
    return parse(arena, text);
}

test "a plain GET keeps its URL and gets a default method" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl https://api.example.com/v1/items");
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("https://api.example.com/v1/items", req.url);
    try testing.expectEqual(@as(usize, 0), req.headers.len);
    try testing.expectEqualStrings("", req.body);
}

test "a curl.exe invocation from a PowerShell prompt is the same command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl.exe 'https://example.com/a b'");
    try testing.expectEqualStrings("https://example.com/a b", req.url);
}

test "a URL with no scheme is read the way curl reads it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl example.com:8080/health");
    try testing.expectEqualStrings("http://example.com:8080/health", req.url);
}

test "method, headers, body and the JSON content type all come across" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const command =
        "curl -X POST https://api.example.com/items \\\n" ++
        "  -H 'content-type: application/json' \\\n" ++
        "  -H \"x-trace: abc\" \\\n" ++
        "  -d '{\"name\":\"widget\"}'";
    const req = try parseWithArena(arena_state.allocator(), command);
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("{\"name\":\"widget\"}", req.body);
    try testing.expectEqual(@as(usize, 2), req.headers.len);
    try testing.expectEqualStrings("content-type", req.headers[0].name);
    try testing.expectEqualStrings("application/json", req.headers[0].value);
    try testing.expectEqualStrings("x-trace", req.headers[1].name);
}

test "data without a method is a POST, and a body without a content type gets one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl https://x.test/q -d 'a=1'");
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("a=1", req.body);
    try testing.expectEqualStrings("application/x-www-form-urlencoded", req.headers[0].value);
}

test "repeated --data joins with an ampersand the way curl does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl https://x.test -d a=1 -d b=2");
    try testing.expectEqualStrings("a=1&b=2", req.body);
}

test "-I is HEAD and -G moves the body into the query string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const head = try parseWithArena(arena_state.allocator(), "curl -I https://x.test/");
    try testing.expectEqualStrings("HEAD", head.method);

    const get = try parseWithArena(arena_state.allocator(), "curl -G https://x.test/s?page=1 -d 'q=two words'");
    try testing.expectEqualStrings("GET", get.method);
    try testing.expectEqualStrings("", get.body);
    try testing.expectEqualStrings("https://x.test/s?page=1&q=two words", get.url);
}

test "-u becomes a Basic Authorization header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "curl -u user:pass https://x.test/");
    try testing.expectEqual(@as(usize, 1), req.headers.len);
    try testing.expectEqualStrings("Authorization", req.headers[0].name);
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", req.headers[0].value);
}

test "options that carry a value are swallowed, not read as the URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const command = "curl -sSL -o out.json --max-time 10 --retry 2 https://x.test/real";
    const req = try parseWithArena(arena_state.allocator(), command);
    try testing.expectEqualStrings("https://x.test/real", req.url);
}

test "a command from a shell prompt with a leading $ still parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const req = try parseWithArena(arena_state.allocator(), "$ curl 'https://x.test/a'");
    try testing.expectEqualStrings("https://x.test/a", req.url);
}

test "the things that are not a curl command are refused, not guessed at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(error.Empty, parse(arena_state.allocator(), "   "));
    try testing.expectError(error.NotCurl, parse(arena_state.allocator(), "wget https://x.test/"));
    try testing.expectError(error.MissingUrl, parse(arena_state.allocator(), "curl -X POST"));
}

test "format writes a command that parses back to the same request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = Request{
        .method = "POST",
        .url = "https://api.example.com/items?page=2",
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-it's", .value = "a 'quoted' value" },
        },
        .body = "{\"name\":\"widget's\"}",
    };
    const text = try format(arena, original);
    const back = try parse(arena, text);

    try testing.expectEqualStrings(original.method, back.method);
    try testing.expectEqualStrings(original.url, back.url);
    try testing.expectEqualStrings(original.body, back.body);
    try testing.expectEqual(@as(usize, 2), back.headers.len);
    try testing.expectEqualStrings(original.headers[1].value, back.headers[1].value);
}

test "a GET command carries no -X flag, because that is already what curl does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try format(arena, .{ .method = "GET", .url = "https://x.test/" });
    try testing.expect(!std.mem.startsWith(u8, text, "curl -X"));
    try testing.expect(std.mem.indexOf(u8, text, "-X") == null);
}
