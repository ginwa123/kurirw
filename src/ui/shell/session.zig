//! The document session: the tree every panel reads, the arenas behind it, and the selection and status.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Field = glinlandui.components.input.Field;

const postman = @import("../../data/model/postman.zig");
const store = @import("../../data/local/workspace_store.zig");
const session_store = @import("../../data/local/session_store.zig");
const domain = @import("../../domain/repository/workspace.zig");
const env_mod = @import("../../domain/env.zig");
const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");

pub const Allocator = std.mem.Allocator;
pub const Value = postman.Value;
pub const Path = state_mod.Path;
pub const Focus = state_mod.Focus;

// A path as the session file spells it: "0.2.1", the same index chain the tree addresses a row by.
fn parsePath(text: []const u8) ?Path {
    if (text.len == 0) return null;
    var path = Path.empty;
    var segments = std.mem.splitScalar(u8, text, '.');
    while (segments.next()) |segment| {
        const index = std.fmt.parseInt(u16, segment, 10) catch return null;
        path = path.child(index);
    }
    if (path.depth == 0) return null;
    return path;
}

// What a first `load` found, so the shell can persist a document that did not exist yet.
pub const Loaded = domain.Loaded;

pub const Session = struct {
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    theme: glinlandui.theme.Theme = theme_mod.app_theme,

    // The document owns every string the tree borrows; only a reload resets it.
    doc_arena: std.heap.ArenaAllocator = undefined,
    // The frame's strings: rows, formatted labels, header rows. Reset on every snapshot.
    view_arena: std.heap.ArenaAllocator = undefined,

    // Where the document is read from and written to. The session never learns it is a file.
    repo: domain.Workspace = undefined,
    doc: Value = .{ .null = {} },
    path: []const u8 = "",
    // The working session beside the document: the tabs that were open, and edits nobody has saved.
    session_path: []const u8 = "",
    // The global variables, borrowed from the Env panel: the send rule and every text field read them here.
    env_vars: []const env_mod.Variable = &.{},
    // What the previous run left open, so the first frame can put it back.
    restored_tabs: [state_mod.max_tabs]Path = undefined,
    restored_tab_count: usize = 0,
    restored_active: ?Path = null,
    workspace: usize = 0,
    selection: ?Path = null,
    // Which field holds the keyboard. Both panels set it, the shell draws it.
    focus: Focus = .none,

    status_buf: [320]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,

    // The paths whose edits are not on disk yet. A list, not a flag: the tree marks the endpoint, not the file.
    dirty_paths: [state_mod.max_dirty]Path = undefined,
    dirty_count: usize = 0,
    // More edits than the list holds: the document is unsaved even though no row can be marked.
    dirty_overflow: bool = false,

    // Set by every intent; the shell rebuilds its snapshot once per frame while it is on.
    dirty: bool = true,

    pub fn start(self: *Session, gpa: Allocator, io: std.Io, theme: glinlandui.theme.Theme, path: []const u8, session_path: []const u8, repo: domain.Workspace) void {
        self.gpa = gpa;
        self.io = io;
        self.theme = theme;
        self.path = path;
        self.session_path = session_path;
        self.repo = repo;
        self.doc_arena = std.heap.ArenaAllocator.init(gpa);
        self.view_arena = std.heap.ArenaAllocator.init(gpa);
        self.dirty = true;
    }

    pub fn deinit(self: *Session) void {
        self.doc_arena.deinit();
        self.view_arena.deinit();
        // `path` is borrowed from the container, which owns the bytes and frees them.
        self.* = undefined;
    }

    pub fn docArena(self: *Session) Allocator {
        return self.doc_arena.allocator();
    }

    // ---- persistence ------------------------------------------------------------------------------------

    pub fn load(self: *Session) Loaded {
        const arena = self.docArena();
        var seed: [16]u8 = undefined;
        self.io.random(&seed);
        const id: []const u8 = postman.makeId(self.gpa, seed) catch "";
        defer if (id.len > 0) self.gpa.free(id);

        const loaded = self.repo.load(arena, id);
        self.doc = loaded.doc;
        self.workspace = 0;
        self.selection = null;
        self.dirty = true;
        if (loaded.error_name.len > 0) {
            self.setStatus(true, "Could not read {s} ({s}); started a fresh workspace.", .{ self.path, loaded.error_name });
        } else if (loaded.from_disk) {
            self.setStatus(false, "Loaded {s}.", .{self.path});
        } else {
            self.setStatus(false, "New here? Create a collection, then a request inside it.", .{});
        }
        // The working session beside the document wins: it is what was on screen when the window closed.
        self.restoreSession(arena);
        return .{ .from_disk = loaded.from_disk, .error_name = loaded.error_name };
    }

    // Read the session file beside the document: the document it showed, the tabs, and the dots.
    fn restoreSession(self: *Session, arena: Allocator) void {
        if (self.session_path.len == 0) return;
        const restored = session_store.load(arena, self.io, self.session_path) orelse return;
        const doc = restored.doc orelse return;
        self.doc = doc;
        const workspaces = store.workspaceCount(doc);
        self.workspace = if (workspaces == 0) 0 else @min(restored.workspace, workspaces - 1);

        self.restored_tab_count = 0;
        for (restored.tabs) |text| {
            if (self.restored_tab_count >= state_mod.max_tabs) break;
            const path = parsePath(text) orelse continue;
            if (self.nodeAt(path) == null) continue;
            self.restored_tabs[self.restored_tab_count] = path;
            self.restored_tab_count += 1;
        }
        self.restored_active = if (parsePath(restored.active)) |active| (if (self.nodeAt(active) != null) active else null) else null;

        self.dirty_count = 0;
        self.dirty_overflow = false;
        for (restored.dirty) |text| {
            const path = parsePath(text) orelse continue;
            self.markDirty(path);
        }
        self.setStatus(false, "Restored what was open last time.", .{});
    }

    // Write the working session: the document as it stands, the tabs, and which of them are not on disk.
    pub fn persistSession(self: *Session, tabs: []const Path, active: ?Path) void {
        if (self.session_path.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var tab_text: std.ArrayList([]const u8) = .empty;
        for (tabs) |open| {
            var buffer: [64]u8 = undefined;
            tab_text.append(arena, arena.dupe(u8, open.format(&buffer)) catch break) catch break;
        }
        var dirty_text: std.ArrayList([]const u8) = .empty;
        for (self.dirty_paths[0..self.dirty_count]) |path| {
            var buffer: [64]u8 = undefined;
            dirty_text.append(arena, arena.dupe(u8, path.format(&buffer)) catch break) catch break;
        }
        var active_buffer: [64]u8 = undefined;
        const active_text = if (active) |path| path.format(&active_buffer) else "";
        session_store.save(arena, self.io, self.session_path, self.doc, self.workspace, active_text, tab_text.items, dirty_text.items) catch {
            self.setStatus(true, "Could not keep the session beside the document.", .{});
        };
    }

    // The document changed: write it, and let the shell rebuild its snapshot.
    pub fn commit(self: *Session) void {
        // Nothing is written here: an edit is unsaved until the person asks for it (Ctrl/Cmd+S).
        self.markDirty(self.selection);
    }

    // An edit landed: this path is not on disk until `persist`. A null path marks the document unsaved, no row.
    pub fn markDirty(self: *Session, path: ?Path) void {
        self.dirty = true;
        const target = path orelse {
            self.dirty_overflow = true;
            return;
        };
        for (self.dirty_paths[0..self.dirty_count]) |known| {
            if (Path.eql(known, target)) return;
        }
        if (self.dirty_count >= state_mod.max_dirty) {
            self.dirty_overflow = true;
            return;
        }
        self.dirty_paths[self.dirty_count] = target;
        self.dirty_count += 1;
    }

    pub fn isDirty(self: *const Session, path: Path) bool {
        for (self.dirty_paths[0..self.dirty_count]) |known| {
            if (Path.eql(known, path)) return true;
        }
        return false;
    }

    // True while any edit is not on disk, which is what asks the window a question before it closes.
    pub fn hasUnsaved(self: *const Session) bool {
        return self.dirty_count > 0 or self.dirty_overflow;
    }

    // The document is on disk: every dot goes with it.
    pub fn clearDirty(self: *Session) void {
        self.dirty_count = 0;
        self.dirty_overflow = false;
        self.dirty = true;
    }

    // Only the view changed (a selection, a tab, a panel width): no file write, but the snapshot is stale.
    pub fn touch(self: *Session) void {
        self.dirty = true;
    }

    pub fn persist(self: *Session) void {
        if (self.path.len == 0) return;
        self.repo.save(self.gpa, self.doc) catch |err| {
            self.setStatus(true, "Could not save ({s}). Your edits are in memory only.", .{@errorName(err)});
        };
    }

    // ---- status line ------------------------------------------------------------------------------------

    pub fn setStatus(self: *Session, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.status_buf, fmt, args) catch blk: {
            break :blk self.status_buf[0..0];
        };
        self.status_len = written.len;
        self.status_is_error = is_error;
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn fail(self: *Session, comptime fmt: []const u8, args: anytype) void {
        self.setStatus(true, fmt, args);
        self.dirty = true;
    }

    pub fn failNow(self: *Session, comptime fmt: []const u8) void {
        self.fail(fmt, .{});
    }

    // ---- the tree, as a value ---------------------------------------------------------------------------

    pub fn nodeAt(self: *Session, path: Path) ?*Value {
        if (path.depth == 0) return null;
        const collection_index = path.segments[0];
        var current = store.collectionPtr(&self.doc, self.workspace, collection_index) orelse return null;
        var level: usize = 1;
        while (level < path.depth) : (level += 1) {
            if (current.* != .object) return null;
            const items = current.object.getPtr("item") orelse return null;
            if (items.* != .array) return null;
            const index = path.segments[level];
            if (index >= items.array.items.len) return null;
            current = &items.array.items[index];
        }
        return current;
    }

    pub fn selectedNode(self: *Session) ?*Value {
        const path = self.selection orelse return null;
        return self.nodeAt(path);
    }

    pub fn selectedRequest(self: *Session) ?*Value {
        const node = self.selectedNode() orelse return null;
        if (!postman.isRequest(node.*)) return null;
        return node;
    }

    // The saved request a flow names: its own name, or `collection/name` when two collections share one.
    pub fn findRequest(self: *Session, wanted_name: []const u8) ?Path {
        const slash = std.mem.indexOfScalar(u8, wanted_name, '/');
        const wanted_collection = if (slash) |at| wanted_name[0..at] else "";
        const wanted = if (slash) |at| wanted_name[at + 1 ..] else wanted_name;
        const count = store.collectionCount(self.doc, self.workspace);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const collection = store.collectionAt(self.doc, self.workspace, index) orelse continue;
            if (wanted_collection.len > 0) {
                const info = collection.object.get("info") orelse continue;
                if (!std.ascii.eqlIgnoreCase(postman.str(info, "name"), wanted_collection)) continue;
            }
            if (findIn(collection, Path.empty.child(@intCast(index)), wanted)) |found| return found;
        }
        return null;
    }

    // A depth-first walk for one request name, which is how a flow's `send "…"` becomes a path.
    fn findIn(node: Value, base: Path, wanted: []const u8) ?Path {
        var index: usize = 0;
        while (index < postman.itemCount(node)) : (index += 1) {
            const item = postman.itemAt(node, index) orelse continue;
            const path = base.child(@intCast(index));
            if (postman.isRequest(item)) {
                if (std.ascii.eqlIgnoreCase(postman.str(item, "name"), wanted)) return path;
                continue;
            }
            if (findIn(item, path, wanted)) |found| return found;
        }
        return null;
    }

    // The workspace on screen, by its own id: the key the global variables are filed under.
    pub fn workspaceId(self: *const Session) []const u8 {
        const workspace = store.workspaceAt(self.doc, self.workspace) orelse return "";
        return postman.str(workspace, "id");
    }

    pub fn workspaceName(self: *const Session) []const u8 {
        return store.workspaceName(self.doc, self.workspace);
    }

    // ---- what `{{name}}` resolves against -------------------------------------------------------------------

    // Everything a request's braces can mean, walked in order: its own variables, the active environment, its collection.
    pub fn variableScope(self: *Session, arena: Allocator) env_mod.Scope {
        return .{
            .request = self.requestVars(arena),
            .environment = self.env_vars,
            .collection = self.collectionVars(arena),
        };
    }

    pub fn requestVars(self: *Session, arena: Allocator) []const env_mod.Pair {
        const node = self.selectedNode() orelse return &.{};
        return pairsOf(node.*, arena);
    }

    pub fn collectionVars(self: *Session, arena: Allocator) []const env_mod.Pair {
        const path = self.selection orelse return &.{};
        if (path.depth == 0) return &.{};
        const collection = store.collectionAt(self.doc, self.workspace, path.segments[0]) orelse return &.{};
        return pairsOf(collection, arena);
    }

    fn pairsOf(item: postman.Value, arena: Allocator) []const env_mod.Pair {
        var out: std.ArrayList(env_mod.Pair) = .empty;
        var index: usize = 0;
        while (index < postman.varCount(item)) : (index += 1) {
            const pair = postman.varAt(item, index);
            if (pair.name.len == 0) continue;
            out.append(arena, .{ .name = pair.name, .value = pair.value }) catch break;
        }
        return out.toOwnedSlice(arena) catch &.{};
    }

    pub fn name(node: Value) []const u8 {
        if (postman.isCollection(node)) {
            const info = node.object.get("info") orelse return "";
            return postman.str(info, "name");
        }
        return postman.str(node, "name");
    }

    pub fn kind(node: Value) state_mod.NodeKind {
        if (postman.isCollection(node)) return .collection;
        if (postman.isRequest(node)) return .request;
        return .folder;
    }

    pub fn isRequest(node: Value) bool {
        return postman.isRequest(node);
    }

    // 32 hex characters that live as long as the document, because the document points at them.
    pub fn randomId(self: *Session, alloc: Allocator) []const u8 {
        var seed: [16]u8 = undefined;
        self.io.random(&seed);
        return postman.makeId(alloc, seed) catch "";
    }

    // The style both panels create a field with, so a field looks the same wherever it lives.
    pub fn fieldStyle(self: *Session, id: glinlandui.props.Id, src: std.builtin.SourceLocation) Field {
        const t = self.theme;
        return .{
            // The devtool shows where the app declared this field, not only where the component lives.
            .src = src,
            .id = id,
            .font_size = t.type_scale.body,
            .bg = t.colors.surface,
            .fg = t.colors.text,
            .sel_bg = theme_mod.select_bg,
            .sel_fg = theme_mod.select_fg,
            .caret_fg = t.colors.primary,
            .radius = glinlandui.props.Radius.all(6),
            .pad = glinlandui.props.Pad.axes(7, 9),
            .border = .all(1, t.colors.divider),
            .h = .{ .fixed = 30 },
        };
    }
};
