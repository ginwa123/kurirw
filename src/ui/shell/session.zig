//! The document session: the tree every panel reads, the arenas behind it, and the selection and status.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;

const postman = @import("../../data/model/postman.zig");
const store = @import("../../data/local/workspace_store.zig");
const domain = @import("../../domain/repository/workspace.zig");
const state_mod = @import("../../state.zig");
const theme_mod = @import("../theme/theme.zig");

pub const Allocator = std.mem.Allocator;
pub const Value = postman.Value;
pub const Path = state_mod.Path;
pub const Focus = state_mod.Focus;

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
    workspace: usize = 0,
    selection: ?Path = null,
    // Which field holds the keyboard. Both panels set it, the shell draws it.
    focus: Focus = .none,

    status_buf: [320]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,

    // Set by every intent; the shell rebuilds its snapshot once per frame while it is on.
    dirty: bool = true,

    pub fn start(self: *Session, gpa: Allocator, io: std.Io, theme: glinlandui.theme.Theme, path: []const u8, repo: domain.Workspace) void {
        self.gpa = gpa;
        self.io = io;
        self.theme = theme;
        self.path = path;
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
        return .{ .from_disk = loaded.from_disk, .error_name = loaded.error_name };
    }

    // The document changed under everyone: write it, and let the shell rebuild its snapshot.
    pub fn commit(self: *Session) void {
        self.persist();
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
    pub fn fieldStyle(self: *Session, id: glinlandui.props.Id, src: std.builtin.SourceLocation) input_mod.Field {
        const t = self.theme;
        return .{
            // The devtool shows where the app declared this field, not only where the component lives.
            .src = src,
            .id = id,
            .font_size = t.type_scale.body,
            .bg = t.colors.surface,
            .fg = t.colors.text,
            .sel_bg = t.colors.surface_variant,
            .sel_fg = t.colors.text,
            .caret_fg = t.colors.primary,
            .radius = glinlandui.props.Radius.all(6),
            .pad = glinlandui.props.Pad.axes(7, 9),
            .border = .{ .width = 1, .color = t.colors.divider },
            .h = .{ .fixed = 30 },
        };
    }
};
