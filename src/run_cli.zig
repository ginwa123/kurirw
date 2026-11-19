//! `kurirw run` — the same runner the page drives, with no window: a build can run a collection or a saved flow.
const std = @import("std");

const postman = @import("data/model/postman.zig");
const store_mod = @import("data/local/workspace_store.zig");
const env_store = @import("data/local/env_store.zig");
const http_mod = @import("data/remote/http_client.zig");
const env_mod = @import("domain/env.zig");
const runner = @import("domain/runner.zig");
const data_file = @import("domain/data_file.zig");
const run_collection = @import("domain/usecase/run_collection.zig");
const pw_run = @import("data/local/pw_run.zig");

const Allocator = std.mem.Allocator;

// What one command line asks for; the descriptor file fills the same fields.
const Options = struct {
    collection: []const u8 = "",
    // A saved code runner, by name (or by its 1-based index among runners): its flow IS the plan.
    runner: []const u8 = "",
    path: []const u8 = "",
    workspace: []const u8 = "",
    environment: []const u8 = "",
    data: []const u8 = "",
    report: []const u8 = "",
    home: []const u8 = "",
    iterations: usize = 0,
    delay_ms: u32 = 0,
};

// The words the CLI accepts, so a typo is a sentence instead of a silent default.
const usage =
    \\usage: kurirw run [options]
    \\  --collection NAME   run every request of a collection
    \\  --runner NAME       run a saved code runner's program (its own flow, step by step)
    \\  --path 1.2          a folder inside the collection, by index, to run only that subtree
    \\  --workspace NAME    which workspace (default: the first)
    \\  --environment NAME  which environment (default: the workspace's active one)
    \\  --iterations N      how many times, when no data file is given (default 1)
    \\  --delay MS          wait this long between requests (default 0)
    \\  --data FILE         a CSV or JSON array of objects, one row per iteration
    \\  --report FILE       write the JSON report here (default: stdout)
    \\  --file FILE         read these options from a kurir/run@1 descriptor
    \\  --home DIR          the store's directory (default: KURIR_HOME, else ~/.kurir)
    \\
;

// Run the collection the command line names. 0 = every request passed, 1 = one failed, 2 = could not run.
pub fn run(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var opts = Options{};
    var descriptor: []const u8 = "";
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
        defer it.deinit();
        _ = it.skip();
        _ = it.next();
        while (it.next()) |arg| {
            const next = struct {
                fn value(iter: *std.process.Args.Iterator, alloc: Allocator) ?[]const u8 {
                    const taken = iter.next() orelse return null;
                    return alloc.dupe(u8, taken) catch null;
                }
            }.value;
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return report(arena, io, usage, .{});
            if (std.mem.eql(u8, arg, "--collection")) opts.collection = next(&it, arena) orelse return bad(arena, io, "--collection needs a name");
            if (std.mem.eql(u8, arg, "--runner")) opts.runner = next(&it, arena) orelse return bad(arena, io, "--runner needs a name");
            if (std.mem.eql(u8, arg, "--path")) opts.path = next(&it, arena) orelse return bad(arena, io, "--path needs an index path");
            if (std.mem.eql(u8, arg, "--workspace")) opts.workspace = next(&it, arena) orelse return bad(arena, io, "--workspace needs a name");
            if (std.mem.eql(u8, arg, "--environment")) opts.environment = next(&it, arena) orelse return bad(arena, io, "--environment needs a name");
            if (std.mem.eql(u8, arg, "--data")) opts.data = next(&it, arena) orelse return bad(arena, io, "--data needs a file");
            if (std.mem.eql(u8, arg, "--report")) opts.report = next(&it, arena) orelse return bad(arena, io, "--report needs a file");
            if (std.mem.eql(u8, arg, "--home")) opts.home = next(&it, arena) orelse return bad(arena, io, "--home needs a directory");
            if (std.mem.eql(u8, arg, "--file")) descriptor = next(&it, arena) orelse return bad(arena, io, "--file needs a path");
            if (std.mem.eql(u8, arg, "--iterations")) opts.iterations = parseNumber(next(&it, arena) orelse return bad(arena, io, "--iterations needs a number"));
            if (std.mem.eql(u8, arg, "--delay")) opts.delay_ms = @intCast(parseNumber(next(&it, arena) orelse return bad(arena, io, "--delay needs a number")));
        }
    }
    if (descriptor.len > 0) try readDescriptor(arena, io, descriptor, &opts);
    if (opts.collection.len == 0 and opts.runner.len == 0) return bad(arena, io, "name a collection with --collection or a runner with --runner, or put one in --file");

    // The store's directory: --home wins, then the environment, then the default the app uses.
    const document_path = try store_mod.defaultPath(arena, init.environ_map);
    const env_path = try env_store.pathFor(arena, document_path);
    const home_override = opts.home.len > 0;
    const doc_file = if (home_override) try std.fs.path.join(arena, &.{ opts.home, store_mod.file_name }) else document_path;
    const env_file = if (home_override) try env_store.pathFor(arena, doc_file) else env_path;

    const loaded = store_mod.load(io, arena, doc_file, "");
    if (loaded.error_name.len > 0) return bad(arena, io, "the store at this path could not be read");

    const workspace = findWorkspace(loaded.doc, opts.workspace) orelse return bad(arena, io, "no workspace matched --workspace");

    var vars = run_collection.Vars{};
    try loadEnvironment(arena, io, env_file, workspace_id(loaded.doc, workspace), opts.environment, &vars);

    // A saved runner is a Playwright spec, so it runs through Playwright instead of a collection walk.
    if (opts.runner.len > 0) return runSavedRunner(arena, io, init.environ_map, loaded.doc, workspace, opts, doc_file, &vars);

    var data = data_file.Data{};
    if (opts.data.len > 0) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, opts.data, arena, .limited(8 * 1024 * 1024)) catch
            return bad(arena, io, "the data file could not be read");
        data = try data_file.parse(arena, bytes);
        if (data.failure) |failure| {
            const line = try std.fmt.allocPrint(arena, "{s} (line {d})", .{ failure.message, failure.line });
            return bad(arena, io, line);
        }
    }

    var real = http_mod.Real.init(init.gpa);
    defer real.deinit();

    const collection = findCollection(loaded.doc, workspace, opts.collection) orelse return bad(arena, io, "no collection matched --collection");
    const base = runner.Address{ .depth = 1, .segments = splatSegment(0, @intCast(collection.index)) };
    const node = if (opts.path.len > 0) descend(collection.node, opts.path) orelse return bad(arena, io, "--path does not address a folder in this collection") else collection.node;
    const address = if (opts.path.len > 0) try addressOf(arena, base, opts.path) else base;
    const raw_name = postman.str(collection.node, "name");
    const target_name = if (raw_name.len > 0) raw_name else if (collection.node == .object) postman.str(collection.node.object.get("info") orelse .{ .null = {} }, "name") else "";

    const report_out = run_collection.run(arena, real.transport(arena), node, address, &vars, .{
        .io = io,
        .data = data,
        .iterations = if (opts.iterations == 0) 1 else opts.iterations,
        .delay_ms = opts.delay_ms,
    });
    if (report_out.failure.len > 0) return bad(arena, io, report_out.failure);
    const json = try run_collection.reportJson(arena, target_name, report_out);

    // The summary goes to stderr, so `kurirw run … | jq` still reads one JSON document.
    var line: [200]u8 = undefined;
    const summary = std.fmt.bufPrint(&line, "{s}: {d} requests, {d} ok, {d} failed, {d} ms{s}\n", .{
        target_name,
        report_out.requests,
        report_out.ok,
        report_out.failed,
        report_out.duration_ms,
        if (report_out.stopped) " (stopped)" else "",
    }) catch "";
    std.Io.File.stderr().writeStreamingAll(io, summary) catch {};

    return writeReport(arena, io, opts.report, json, report_out.failed == 0);
}

// A saved runner, run by Playwright with no window: the same report shape the page draws.
fn runSavedRunner(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    doc: postman.Value,
    workspace: usize,
    opts: Options,
    doc_file: []const u8,
    vars: *run_collection.Vars,
) !u8 {
    const found = findRunner(doc, workspace, opts.runner) orelse return bad(arena, io, "no runner matched --runner");
    const install = playwrightInstall(arena, io, environ, doc_file) orelse
        return bad(arena, io, "Playwright is not installed: run `npm i -D @playwright/test` in the runner folder beside the store, or point KURIR_PLAYWRIGHT_DIR at a project that has it");

    // The active environment reaches the spec as `process.env`, so a test can read a token it was given.
    var pairs: std.ArrayList(pw_run.Pair) = .empty;
    for (vars.items.items) |variable| {
        if (variable.name.len == 0) continue;
        pairs.append(arena, .{ .name = variable.name, .value = env_mod.value(variable) }) catch break;
    }
    const report_out = pw_run.runNow(arena, io, install, postman.flowOf(found.node), baseUrlOf(vars.items.items), environ, pairs.items);
    if (report_out.failure.len > 0) return bad(arena, io, report_out.failure);
    const json = try pw_run.reportJson(arena, found.name, report_out);

    var line: [200]u8 = undefined;
    const summary = std.fmt.bufPrint(&line, "{s}: {d} tests, {d} passed, {d} failed, {d} ms{s}\n", .{
        found.name,
        report_out.rows.len,
        report_out.expected,
        report_out.unexpected,
        report_out.duration_ms,
        if (report_out.stopped) " (stopped)" else "",
    }) catch "";
    std.Io.File.stderr().writeStreamingAll(io, summary) catch {};
    return writeReport(arena, io, opts.report, json, report_out.unexpected == 0);
}

// The report goes where the caller asked, or to stdout where a pipe can read it.
fn writeReport(arena: Allocator, io: std.Io, path: []const u8, json: []const u8, ok: bool) !u8 {
    if (path.len > 0) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch
            return bad(arena, io, "the report file could not be written");
    } else {
        std.Io.File.stdout().writeStreamingAll(io, json) catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
    }
    return if (ok) 0 else 1;
}

// Playwright lives in the env var first, then in the runner folder beside the store.
fn playwrightInstall(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, doc_file: []const u8) ?pw_run.Install {
    var roots: std.ArrayList([]const u8) = .empty;
    if (environ.get("KURIR_PLAYWRIGHT_DIR")) |dir| {
        if (dir.len > 0) roots.append(arena, dir) catch {};
    }
    const store_dir = std.fs.path.dirname(doc_file) orelse ".";
    roots.append(arena, std.fs.path.join(arena, &.{ store_dir, "runner" }) catch "") catch {};
    return pw_run.locate(arena, io, roots.items) catch null;
}

// The variable an environment uses to say what relative URLs resolve against.
fn baseUrlOf(items: []const env_mod.Variable) []const u8 {
    const names = [_][]const u8{ "baseUrl", "base_url", "baseURL" };
    for (items) |variable| {
        for (names) |name| {
            if (!std.ascii.eqlIgnoreCase(variable.name, name)) continue;
            const value = env_mod.value(variable);
            if (value.len > 0) return value;
        }
    }
    return "";
}

// One line telling the caller what to fix, on stderr, and the usage code.
fn bad(arena: Allocator, io: std.Io, message: []const u8) !u8 {
    const line = try std.fmt.allocPrint(arena, "kurirw run: {s}\n\n{s}", .{ message, usage });
    _ = report(arena, io, line, .{}) catch {};
    return 2;
}

fn report(_: Allocator, io: std.Io, text: []const u8, _: struct {}) !u8 {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    return 2;
}

fn parseNumber(text: []const u8) usize {
    return std.fmt.parseInt(usize, text, 10) catch 0;
}

fn splatSegment(index: usize, value: u16) [runner.max_depth]u16 {
    var segments: [runner.max_depth]u16 = @splat(0);
    if (index < segments.len) segments[index] = value;
    return segments;
}

const Found = struct { node: postman.Value, index: usize };

// A workspace by name, or the first one when no name was given.
fn findWorkspace(doc: postman.Value, wanted: []const u8) ?usize {
    const count = store_mod.workspaceCount(doc);
    if (count == 0) return null;
    if (wanted.len == 0) return 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(store_mod.workspaceName(doc, index), wanted)) return index;
    }
    return null;
}

fn workspace_id(doc: postman.Value, index: usize) []const u8 {
    const workspace = store_mod.workspaceAt(doc, index) orelse return "";
    return postman.str(workspace, "id");
}

// A collection by name, or by its 1-based index among the collections, which is not the same as its root index.
fn findCollection(doc: postman.Value, workspace: usize, wanted: []const u8) ?Found {
    const count = store_mod.collectionCount(doc, workspace);
    if (count == 0) return null;
    if (std.fmt.parseInt(usize, wanted, 10)) |number| {
        if (number >= 1 and number <= count) {
            const root = store_mod.collectionRoot(doc, workspace, number - 1) orelse return null;
            return .{ .node = store_mod.rootAt(doc, workspace, root) orelse return null, .index = root };
        }
    } else |_| {}
    var nth: usize = 0;
    while (nth < count) : (nth += 1) {
        const index = store_mod.collectionRoot(doc, workspace, nth) orelse continue;
        const node = store_mod.rootAt(doc, workspace, index) orelse continue;
        const name = if (node == .object) postman.str(node.object.get("info") orelse .{ .null = {} }, "name") else "";
        if (std.ascii.eqlIgnoreCase(name, wanted)) return .{ .node = node, .index = index };
    }
    return null;
}

// A saved runner by name, or by its 1-based index among the workspace's runners.
const RunnerFound = struct { node: postman.Value, name: []const u8 };

fn findRunner(doc: postman.Value, workspace: usize, wanted: []const u8) ?RunnerFound {
    const number = std.fmt.parseInt(usize, wanted, 10) catch 0;
    var nth: usize = 0;
    var index: usize = 0;
    const count = store_mod.rootCount(doc, workspace);
    while (index < count) : (index += 1) {
        const root = store_mod.rootAt(doc, workspace, index) orelse continue;
        // A runner is a root of the workspace, never an item inside a collection.
        if (!postman.isFlow(root)) continue;
        nth += 1;
        const name = postman.str(root, "name");
        if (number == nth or std.ascii.eqlIgnoreCase(name, wanted)) return .{ .node = root, .name = name };
    }
    return null;
}

// `1.2` walks `item[1]` then `item[2]`; the indices are the zero-based ones the tree uses.
fn descend(node: postman.Value, path: []const u8) ?postman.Value {
    var current = node;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        const index = std.fmt.parseInt(usize, part, 10) catch return null;
        current = postman.itemAt(current, index) orelse return null;
    }
    return current;
}

fn addressOf(arena: Allocator, base: runner.Address, path: []const u8) !runner.Address {
    _ = arena;
    var address = base;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        const index = std.fmt.parseInt(u16, part, 10) catch return address;
        address = address.child(index);
    }
    return address;
}

// The named environment (or the workspace's active one) becomes the run's writable variables.
fn loadEnvironment(arena: Allocator, io: std.Io, path: []const u8, id: []const u8, wanted: []const u8, vars: *run_collection.Vars) !void {
    const restored = env_store.load(arena, io, path);
    for (restored.groups) |group| {
        if (id.len > 0 and !std.mem.eql(u8, group.workspace_id, id)) continue;
        const chosen = if (wanted.len > 0) blk: {
            for (group.environments) |environment| {
                if (std.ascii.eqlIgnoreCase(environment.name, wanted)) break :blk environment;
            }
            break :blk null;
        } else blk: {
            for (group.environments) |environment| {
                if (std.mem.eql(u8, environment.name, group.active)) break :blk environment;
            }
            break :blk null;
        };
        const environment = chosen orelse return;
        const items = try arena.alloc(env_mod.Variable, environment.vars.len);
        @memcpy(items, environment.vars);
        vars.items = .fromOwnedSlice(items);
        return;
    }
}

// A `kurir/run@1` descriptor: the same options, in a file a repository can commit next to its collection.
fn readDescriptor(arena: Allocator, io: std.Io, path: []const u8, opts: *Options) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch return;
    const root = postman.parseTree(arena, bytes) catch return;
    if (root != .object) return;
    assign(&opts.collection, root, "collection");
    assign(&opts.runner, root, "runner");
    assign(&opts.path, root, "folder");
    assign(&opts.workspace, root, "workspace");
    assign(&opts.environment, root, "environment");
    assign(&opts.data, root, "data");
    assign(&opts.report, root, "report");
    if (root.object.get("iterations")) |value| {
        if (value == .integer and value.integer > 0) opts.iterations = @intCast(value.integer);
    }
    if (root.object.get("delay_ms")) |value| {
        if (value == .integer and value.integer >= 0) opts.delay_ms = @intCast(value.integer);
    }
}

// One string field of the descriptor, left alone when the file does not name it.
fn assign(field: *[]const u8, root: postman.Value, key: []const u8) void {
    const value = root.object.get(key) orelse return;
    if (value == .string) field.* = value.string;
}

// True when the command line starts with `run`, which is what main branches on.
pub fn wants(args: std.process.Args, gpa: Allocator) bool {
    var it = std.process.Args.Iterator.initAllocator(args, gpa) catch return false;
    defer it.deinit();
    _ = it.skip();
    const first = it.next() orelse return false;
    return std.mem.eql(u8, first, "run");
}
