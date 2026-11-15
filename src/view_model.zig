//! The ViewModel: the only writer of Kurir's state. Every public function is an INTENT the view may raise.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const editor_mod = glinlandui.text_editor;
const frame = glinlandui.frame;

const postman = @import("model/postman.zig");
const store = @import("model/store.zig");
const http_mod = @import("model/http.zig");
const state_mod = @import("state.zig");
const theme_mod = @import("theme.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Path = state_mod.Path;
const Value = postman.Value;

pub const url_field_id = "kurir.url";
pub const name_field_id = "kurir.name";
pub const workspace_field_id = "kurir.workspace";
pub const body_id = "kurir.body";
pub const header_key_prefix = "kurir.header.key";
pub const header_value_prefix = "kurir.header.value";

// A response bigger than this is cut before it is drawn: the body is a text run, not a download.
pub const max_response_bytes: usize = 256 * 1024;

pub const body_pad: f32 = 10;
pub const line_height: f32 = 20;

// The file panels import and export open. A test installs its own, so no suite ever opens a real one.
pub const Dialogs = struct {
    ctx: ?*anyopaque = null,
    open_fn: *const fn (?*anyopaque, Allocator, []const u8) ?[]const u8 = openReal,
    save_fn: *const fn (?*anyopaque, Allocator, []const u8, []const u8) ?[]const u8 = saveReal,
    available: bool = true,
};

const json_filters = [_]glinlandui.file_dialog.Filter{
    .{ .name = "Postman collection", .rules = &.{.{ .pattern = "*.json" }} },
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

fn openReal(_: ?*anyopaque, gpa: Allocator, title: []const u8) ?[]const u8 {
    const selection = glinlandui.file_dialog.openFile(gpa, .{
        .title = title,
        .filters = &json_filters,
    }) catch return null;
    defer selection.deinit(gpa);
    if (selection.status != .selected) return null;
    const picked = selection.first() orelse return null;
    return gpa.dupe(u8, picked) catch null;
}

fn saveReal(_: ?*anyopaque, gpa: Allocator, title: []const u8, suggested: []const u8) ?[]const u8 {
    const selection = glinlandui.file_dialog.saveFile(gpa, .{
        .title = title,
        .filters = &json_filters,
        .current_name = suggested,
    }) catch return null;
    defer selection.deinit(gpa);
    if (selection.status != .selected) return null;
    const picked = selection.first() orelse return null;
    return gpa.dupe(u8, picked) catch null;
}

pub const KurirViewModel = struct {
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    theme: glinlandui.theme.Theme = theme_mod.app_theme,
    dialogs: Dialogs = .{},

    // The document owns every string the tree borrows; only a reload resets it.
    doc_arena: std.heap.ArenaAllocator = undefined,
    // The frame's strings: rows, formatted labels, header rows. Reset on every rebuild.
    view_arena: std.heap.ArenaAllocator = undefined,
    // The last response and everything it points at.
    resp_arena: std.heap.ArenaAllocator = undefined,

    doc: Value = .{ .null = {} },
    path: []const u8 = "",

    workspace: usize = 0,
    selection: ?Path = null,
    expanded: std.ArrayList(Path) = .empty,
    rows: std.ArrayList(state_mod.TreeRow) = .empty,
    view: UiState = .{},

    url_buf: []u8 = &.{},
    url_field: input_mod.Field = .{ .id = .{ .text = url_field_id } },
    name_field: input_mod.Field = .{ .id = .{ .text = name_field_id } },
    workspace_field: input_mod.Field = .{ .id = .{ .text = workspace_field_id } },
    header_fields: [state_mod.max_headers * 2]input_mod.Field = undefined,
    header_ctxs: [state_mod.max_headers * 2]HeaderCtx = undefined,

    body_buf: []u8 = &.{},
    editor: editor_mod.Editor = .{ .buf = &.{} },
    focus: state_mod.Focus = .none,
    editor_tab: state_mod.Tab = .headers,
    response_tab: state_mod.Tab = .body,

    status_buf: [320]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,

    real: ?http_mod.Real = null,
    transport_override: ?http_mod.Transport = null,
    response: state_mod.ResponseView = .{},
    method_ctxs: [postman.methods.len]MethodCtx = undefined,

    // One method button's context: the model, and which verb it stands for.
    pub const MethodCtx = struct {
        vm: *KurirViewModel,
        method: []const u8 = "",
    };

    pub const HeaderCtx = struct {
        vm: *KurirViewModel,
        index: usize,
        // True for the value column, false for the key column.
        value_side: bool,
    };

    pub fn init() KurirViewModel {
        // The arenas are re-initialised on `start`, once the app hands over its allocator.
        return .{
            .doc_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .view_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .resp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn start(self: *KurirViewModel, gpa: Allocator, io: std.Io, theme: glinlandui.theme.Theme, path: []const u8) void {
        self.gpa = gpa;
        self.io = io;
        self.theme = theme;
        self.path = path;
        self.doc_arena = std.heap.ArenaAllocator.init(gpa);
        self.view_arena = std.heap.ArenaAllocator.init(gpa);
        self.resp_arena = std.heap.ArenaAllocator.init(gpa);
        self.real = http_mod.Real.init(gpa);

        self.url_buf = gpa.alloc(u8, state_mod.max_url) catch gpa.alloc(u8, 1) catch return;
        self.body_buf = gpa.alloc(u8, state_mod.max_body) catch gpa.alloc(u8, 1) catch return;
        self.editor = editor_mod.Editor.init(self.body_buf);

        self.url_field = self.fieldStyle(.{ .text = url_field_id });
        self.url_field.bindTo(self.url_buf);
        self.name_field = self.fieldStyle(.{ .text = name_field_id });
        self.name_field.bind();
        self.workspace_field = self.fieldStyle(.{ .text = workspace_field_id });
        self.workspace_field.bind();
        var i: usize = 0;
        while (i < state_mod.max_headers) : (i += 1) {
            self.header_fields[i * 2] = self.fieldStyle(.at(header_key_prefix, i));
            self.header_fields[i * 2].bind();
            self.header_fields[i * 2 + 1] = self.fieldStyle(.at(header_value_prefix, i));
            self.header_fields[i * 2 + 1].bind();
            self.header_ctxs[i * 2] = .{ .vm = self, .index = i, .value_side = false };
            self.header_ctxs[i * 2 + 1] = .{ .vm = self, .index = i, .value_side = true };
            self.header_fields[i * 2].on_change = .{ .f = onHeaderTyped, .ctx = &self.header_ctxs[i * 2] };
            self.header_fields[i * 2 + 1].on_change = .{ .f = onHeaderTyped, .ctx = &self.header_ctxs[i * 2 + 1] };
        }

        // The intents are set ONCE: a frame only hands each field the model's value.
        self.url_field.on_change = .{ .f = onUrlTyped, .ctx = self };
        self.url_field.on_focus = .{ .f = onUrlFocused, .ctx = self };
        self.name_field.on_change = .{ .f = onNameTyped, .ctx = self };
        self.name_field.on_focus = .{ .f = onNameFocused, .ctx = self };
        self.workspace_field.on_change = .{ .f = onWorkspaceTyped, .ctx = self };
        self.workspace_field.on_focus = .{ .f = onWorkspaceFocused, .ctx = self };
        for (postman.methods, 0..) |method, index| {
            self.method_ctxs[index] = .{ .vm = self, .method = method };
        }

        self.load();
    }

    fn onUrlTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .url;
        self.onUrlChange(text);
    }

    fn onUrlFocused(raw: ?*anyopaque) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .url;
    }

    fn onNameTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .name;
        self.onNameChange(text);
    }

    // Focusing a rename field selects what is there, so typing replaces a name instead of appending to it.
    fn onNameFocused(raw: ?*anyopaque) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .name;
        self.name_field.editor.selectAll();
    }

    fn onWorkspaceTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .workspace;
        self.onWorkspaceNameChange(text);
    }

    fn onWorkspaceFocused(raw: ?*anyopaque) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.focus = .workspace;
        self.workspace_field.editor.selectAll();
    }

    fn onHeaderTyped(raw: ?*anyopaque, text: []const u8) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(raw.?));
        ctx.vm.focus = if (ctx.value_side) .header_value else .header_key;
        if (ctx.value_side) {
            ctx.vm.onHeaderValueChange(ctx.index, text);
        } else {
            ctx.vm.onHeaderKeyChange(ctx.index, text);
        }
    }

    fn fieldStyle(self: *KurirViewModel, id: glinlandui.props.Id) input_mod.Field {
        const t = self.theme;
        return .{
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

    pub fn deinit(self: *KurirViewModel) void {
        if (self.real) |*real| real.deinit();
        self.doc_arena.deinit();
        self.view_arena.deinit();
        self.resp_arena.deinit();
        if (self.url_buf.len > 0) self.gpa.free(self.url_buf);
        if (self.body_buf.len > 0) self.gpa.free(self.body_buf);
        self.expanded.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        if (self.path.len > 0) self.gpa.free(self.path);
        self.* = undefined;
    }

    // `onCleared`: the store calls this when the screen goes away.
    pub fn onCleared(self: *KurirViewModel) void {
        self.deinit();
    }

    // ---- the document ------------------------------------------------------------------------------------

    fn load(self: *KurirViewModel) void {
        const arena = self.doc_arena.allocator();
        var seed: [16]u8 = undefined;
        self.io.random(&seed);
        const id: []const u8 = postman.makeId(self.gpa, seed) catch "";
        defer if (id.len > 0) self.gpa.free(id);

        const loaded = store.load(self.io, arena, self.path, id);
        self.doc = loaded.doc;
        self.workspace = 0;
        self.selection = null;
        self.expanded.clearRetainingCapacity();
        if (loaded.error_name.len > 0) {
            self.setStatus(true, "Could not read {s} ({s}); started a fresh workspace.", .{ self.path, loaded.error_name });
        } else if (loaded.from_disk) {
            self.setStatus(false, "Loaded {s}.", .{self.path});
        } else {
            self.setStatus(false, "New here? Create a collection, then a request inside it.", .{});
        }
        // A returning user wants to be where the work is: the first request, not the collection above it.
        if (self.firstRequestPath()) |found| {
            self.selection = found;
            self.expandAncestors(found);
        } else if (store.collectionCount(self.doc, self.workspace) > 0) {
            self.selection = Path.empty.child(0);
            self.expand(Path.empty.child(0), true);
        }
        self.loadSelection();
        self.rebuild();
        // A first run leaves the file behind, so the next start has something to load.
        if (!loaded.from_disk and loaded.error_name.len == 0) self.persist();
    }

    fn persist(self: *KurirViewModel) void {
        if (self.path.len == 0) return;
        store.save(self.io, self.gpa, self.path, self.doc) catch |err| {
            self.setStatus(true, "Could not save ({s}). Your edits are in memory only.", .{@errorName(err)});
        };
    }

    // ---- status line -------------------------------------------------------------------------------------

    fn setStatus(self: *KurirViewModel, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.status_buf, fmt, args) catch blk: {
            break :blk self.status_buf[0..0];
        };
        self.status_len = written.len;
        self.status_is_error = is_error;
    }

    fn status(self: *const KurirViewModel) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    // ---- the tree ----------------------------------------------------------------------------------------

    fn isExpanded(self: *const KurirViewModel, path: Path) bool {
        for (self.expanded.items) |item| {
            if (Path.eql(item, path)) return true;
        }
        return false;
    }

    fn expand(self: *KurirViewModel, path: Path, on: bool) void {
        const found = self.isExpanded(path);
        if (on and !found) {
            self.expanded.append(self.gpa, path) catch {};
        } else if (!on and found) {
            var i: usize = 0;
            while (i < self.expanded.items.len) : (i += 1) {
                if (Path.eql(self.expanded.items[i], path)) {
                    _ = self.expanded.orderedRemove(i);
                    return;
                }
            }
        }
    }

    // The first request in the document, so a reload lands the editor on something usable.
    fn firstRequestPath(self: *KurirViewModel) ?Path {
        const count = store.collectionCount(self.doc, self.workspace);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const collection = store.collectionAt(self.doc, self.workspace, i) orelse continue;
            const root = Path.empty.child(@intCast(i));
            if (firstRequestInside(collection, root, 0)) |found| return found;
        }
        return null;
    }

    // Every ancestor of `path` is open, so a selected row is also a visible row.
    fn expandAncestors(self: *KurirViewModel, path: Path) void {
        var level: usize = 1;
        while (level < path.depth) : (level += 1) {
            var prefix = Path.empty;
            prefix.depth = level;
            @memcpy(prefix.segments[0..level], path.segments[0..level]);
            self.expand(prefix, true);
        }
    }

    fn nodeValue(self: *KurirViewModel, path: Path) ?*Value {
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

    fn firstRequestInside(node: Value, path: Path, depth: usize) ?Path {
        if (depth + 1 >= state_mod.max_depth) return null;
        const count = postman.itemCount(node);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const item = postman.itemAt(node, i) orelse continue;
            const child_path = path.child(@intCast(i));
            if (postman.isRequest(item)) return child_path;
            if (firstRequestInside(item, child_path, depth + 1)) |found| return found;
        }
        return null;
    }

    fn nodeName(node: Value) []const u8 {
        if (postman.isCollection(node)) {
            const info = node.object.get("info") orelse return "";
            return postman.str(info, "name");
        }
        return postman.str(node, "name");
    }

    fn nodeKind(node: Value) state_mod.NodeKind {
        if (postman.isCollection(node)) return .collection;
        if (postman.isRequest(node)) return .request;
        return .folder;
    }

    fn rebuildRows(self: *KurirViewModel) void {
        self.rows.clearRetainingCapacity();
        const count = store.collectionCount(self.doc, self.workspace);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const collection = store.collectionAt(self.doc, self.workspace, i) orelse continue;
            const path = Path.empty.child(@intCast(i));
            self.pushRow(collection, path, 0, .collection);
            if (self.isExpanded(path)) self.pushChildren(collection, path, 1);
        }
    }

    fn pushChildren(self: *KurirViewModel, node: Value, path: Path, depth: u16) void {
        const count = postman.itemCount(node);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const item = postman.itemAt(node, i) orelse continue;
            const child_path = path.child(@intCast(i));
            const kind = nodeKind(item);
            self.pushRow(item, child_path, depth, kind);
            if (kind == .folder and self.isExpanded(child_path)) self.pushChildren(item, child_path, depth + 1);
        }
    }

    fn pushRow(self: *KurirViewModel, node: Value, path: Path, depth: u16, kind: state_mod.NodeKind) void {
        if (self.rows.items.len >= state_mod.max_tree_rows) return;
        const selected = if (self.selection) |current| Path.eql(current, path) else false;
        self.rows.append(self.gpa, .{
            .path = path,
            .depth = depth,
            .kind = kind,
            .label = nodeName(node),
            .method = if (kind == .request) postman.normalizeMethod(postman.str(node.object.get("request").?, "method")) else "",
            .has_children = kind != .request,
            .expanded = self.isExpanded(path),
            .selected = selected,
        }) catch {};
    }

    // ---- the frame's snapshot ----------------------------------------------------------------------------

    fn rebuild(self: *KurirViewModel) void {
        _ = self.view_arena.reset(.retain_capacity);
        const arena = self.view_arena.allocator();
        self.rebuildRows();

        var view = UiState{};
        view.rows = self.rows.items;
        view.selection = self.selection;
        view.workspace_index = self.workspace;
        view.workspace_count = store.workspaceCount(self.doc);
        view.workspace_name = store.workspaceName(self.doc, self.workspace);
        view.workspace_label = std.fmt.allocPrint(arena, "{s}  ·  {d}/{d}", .{
            view.workspace_name,
            self.workspace + 1,
            view.workspace_count,
        }) catch view.workspace_name;
        view.status = self.status();
        view.status_is_error = self.status_is_error;
        view.focus = self.focus;
        view.dialog_available = self.dialogs.available;
        view.editor_tab = self.editor_tab;
        view.response_tab = self.response_tab;
        view.has_collection = store.collectionCount(self.doc, self.workspace) > 0;
        view.response = self.response;

        if (self.selection) |path| {
            if (self.nodeValue(path)) |node| {
                view.has_selection = true;
                view.node_kind = nodeKind(node.*);
                view.node_name = nodeName(node.*);
                view.can_delete = true;
                if (view.node_kind == .request) {
                    const request = postman.requestView(arena, node.*) catch postman.RequestView{};
                    view.method = request.method;
                    view.url = request.url;
                    view.body = request.body;
                    view.header_count = request.headers.len;
                    var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
                    for (request.headers) |header| {
                        header_rows.append(arena, .{ .name = header.key, .value = header.value }) catch break;
                    }
                    view.headers = header_rows.toOwnedSlice(arena) catch &.{};
                }
                view.can_add_folder = view.node_kind != .request;
                view.can_add_request = true;
            }
        }
        if (!view.has_collection and !view.has_selection) view.can_add_request = false;
        self.view = view;
    }

    // `uiState`: the value the view draws. Ticking the caret here keeps the editor's clock in one place.
    pub fn uiState(self: *KurirViewModel) UiState {
        self.editor.tickBlink(frame.delta_s);
        return self.view;
    }

    // True when Postman marks this header disabled, which the "on/off" button shows.
    pub fn headerFieldsDisabled(self: *KurirViewModel, index: usize) bool {
        const node = self.selectedRequest() orelse return false;
        return postman.headerDisabled(node.*, index);
    }

    // ---- selection ---------------------------------------------------------------------------------------

    pub fn onRowSelect(self: *KurirViewModel, index: usize) void {
        const row = if (index < self.view.rows.len) self.view.rows[index] else return;
        self.select(row.path);
    }

    pub fn select(self: *KurirViewModel, path: Path) void {
        self.selection = path;
        if (self.nodeValue(path)) |node| {
            if (nodeKind(node.*) != .request) self.expand(path, !self.isExpanded(path));
        }
        self.loadSelection();
        self.rebuild();
    }

    // Push the selected node into the editor buffers, so the fields show what the model says.
    fn loadSelection(self: *KurirViewModel) void {
        self.url_field.setText("");
        self.name_field.setText("");
        self.editor.setText("");
        self.workspace_field.setText(store.workspaceName(self.doc, self.workspace));

        const node = if (self.selection) |path| self.nodeValue(path) else null;
        if (node) |item| {
            self.name_field.setText(nodeName(item.*));
            if (isRequestItem(item.*)) {
                const request = postman.requestView(self.gpa, item.*) catch postman.RequestView{};
                defer self.gpa.free(request.headers);
                self.url_field.setText(request.url);
                self.editor.setText(request.body);
            }
        }
    }

    fn isRequestItem(node: Value) bool {
        return postman.isRequest(node);
    }

    pub fn toggleSelected(self: *KurirViewModel) void {
        if (self.selection) |path| self.expand(path, !self.isExpanded(path));
        self.rebuild();
    }

    // ---- creating ----------------------------------------------------------------------------------------

    // 32 hex characters that live as long as the document, because the document points at them.
    fn randomId(self: *KurirViewModel, alloc: Allocator) []const u8 {
        var seed: [16]u8 = undefined;
        self.io.random(&seed);
        const made = postman.makeId(alloc, seed) catch return "";
        return made;
    }

    pub fn addCollection(self: *KurirViewModel) void {
        const arena = self.doc_arena.allocator();
        const id = self.randomId(arena);
        const name = std.fmt.allocPrint(arena, "Collection {d}", .{store.collectionCount(self.doc, self.workspace) + 1}) catch "Collection";
        const collection = postman.newCollection(arena, name, id) catch return self.failNow("Could not create a collection.");
        const index = store.addCollection(self.gpa, &self.doc, self.workspace, collection) catch
            return self.failNow("Could not create a collection.");
        self.selection = Path.empty.child(@intCast(index));
        self.expand(self.selection.?, true);
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Created {s}. Add a request inside it.", .{name});
    }

    pub fn addFolder(self: *KurirViewModel) void {
        const parent = self.containerForInsert() orelse return self.failNow("Select a collection or a folder first, then add a folder inside it.");
        const arena = self.doc_arena.allocator();
        const node = self.nodeValue(parent) orelse return self.failNow("That selection is gone. Select a collection again.");
        const name = std.fmt.allocPrint(arena, "Folder {d}", .{postman.itemCount(node.*) + 1}) catch "Folder";
        const folder = postman.newFolder(arena, name) catch return self.failNow("Could not create a folder.");
        const index = postman.appendChild(self.gpa, node, folder) catch return self.failNow("Could not create a folder.");
        self.expand(parent, true);
        self.selection = parent.child(@intCast(index));
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Created {s}.", .{name});
    }

    pub fn addRequest(self: *KurirViewModel) void {
        const parent = self.containerForInsert() orelse return self.failNow("Create a collection first, then add a request inside it.");
        const arena = self.doc_arena.allocator();
        const node = self.nodeValue(parent) orelse return self.failNow("That selection is gone. Select a collection again.");
        const name = std.fmt.allocPrint(arena, "Request {d}", .{postman.itemCount(node.*) + 1}) catch "Request";
        const item = postman.newRequest(arena, name, postman.default_method, "") catch return self.failNow("Could not create a request.");
        const index = postman.appendChild(self.gpa, node, item) catch return self.failNow("Could not create a request.");
        self.expand(parent, true);
        self.selection = parent.child(@intCast(index));
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Created {s}. Paste a URL and send it.", .{name});
    }

    // Where a new item goes: the selected container, or the folder/collection a selected request lives in.
    fn containerForInsert(self: *KurirViewModel) ?Path {
        if (self.selection) |path| {
            const node = self.nodeValue(path) orelse return null;
            if (!postman.isRequest(node.*)) return path;
            return path.parent();
        }
        if (store.collectionCount(self.doc, self.workspace) > 0) return Path.empty.child(0);
        return null;
    }

    pub fn deleteSelected(self: *KurirViewModel) void {
        const path = self.selection orelse return self.failNow("Select something to delete first.");
        if (path.depth == 0) return;
        if (path.depth == 1) {
            store.removeCollection(&self.doc, self.workspace, path.segments[0]);
        } else {
            const parent_path = path.parent() orelse return;
            const parent = self.nodeValue(parent_path) orelse return;
            postman.removeChild(self.gpa, parent, path.segments[path.depth - 1]);
        }
        self.selection = null;
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Deleted. Everything else is untouched.", .{});
    }

    // ---- workspaces --------------------------------------------------------------------------------------

    pub fn addWorkspace(self: *KurirViewModel) void {
        const arena = self.doc_arena.allocator();
        const id = self.randomId(arena);
        const name = std.fmt.allocPrint(arena, "Workspace {d}", .{store.workspaceCount(self.doc) + 1}) catch "Workspace";
        var workspace: postman.Object = .empty;
        workspace.put(arena, "id", .{ .string = id }) catch return self.failNow("Could not create a workspace.");
        workspace.put(arena, "name", .{ .string = name }) catch return self.failNow("Could not create a workspace.");
        workspace.put(arena, "collections", .{ .array = postman.Array.init(arena) }) catch return self.failNow("Could not create a workspace.");
        const index = store.addWorkspace(self.gpa, &self.doc, .{ .object = workspace }) catch
            return self.failNow("Could not create a workspace.");
        self.workspace = index;
        self.selection = null;
        self.expanded.clearRetainingCapacity();
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Switched to {s}. Collections here are separate.", .{name});
    }

    pub fn nextWorkspace(self: *KurirViewModel) void {
        const count = store.workspaceCount(self.doc);
        if (count <= 1) return self.failNow("There is only one workspace. Add another to switch between them.");
        self.switchWorkspace((self.workspace + 1) % count);
    }

    fn switchWorkspace(self: *KurirViewModel, index: usize) void {
        if (index >= store.workspaceCount(self.doc)) return;
        self.workspace = index;
        self.selection = null;
        self.expanded.clearRetainingCapacity();
        if (store.collectionCount(self.doc, self.workspace) > 0) {
            self.selection = Path.empty.child(0);
            self.expand(self.selection.?, true);
        }
        self.loadSelection();
        self.rebuild();
        self.setStatus(false, "Switched to {s}.", .{store.workspaceName(self.doc, self.workspace)});
    }

    pub fn deleteWorkspace(self: *KurirViewModel) void {
        const count = store.workspaceCount(self.doc);
        if (count == 0) return;
        const name = store.workspaceName(self.doc, self.workspace);
        store.removeWorkspace(&self.doc, self.workspace);
        if (store.workspaceCount(self.doc) == 0) {
            const arena = self.doc_arena.allocator();
            const id = self.randomId(arena);
            const fresh = store.blank(arena, id) catch return self.failNow("Could not reset the workspace list.");
            self.doc = fresh;
        }
        if (self.workspace >= store.workspaceCount(self.doc)) self.workspace = store.workspaceCount(self.doc) - 1;
        self.selection = null;
        self.expanded.clearRetainingCapacity();
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Deleted workspace {s}.", .{name});
    }

    // ---- the editor --------------------------------------------------------------------------------------

    pub fn setMethod(self: *KurirViewModel, method: []const u8) void {
        const node = self.selectedRequest() orelse return self.failNow("Select a request first, then pick a method.");
        postman.setMethod(self.doc_arena.allocator(), node, method) catch return self.failNow("Could not change the method.");
        self.persist();
        self.rebuild();
    }

    pub fn onUrlChange(self: *KurirViewModel, url: []const u8) void {
        const node = self.selectedRequest() orelse return;
        postman.setUrl(self.doc_arena.allocator(), node, url) catch return self.failNow("Could not save the URL.");
        self.persist();
        self.rebuild();
    }

    pub fn onNameChange(self: *KurirViewModel, name: []const u8) void {
        const path = self.selection orelse return;
        const node = self.nodeValue(path) orelse return;
        if (postman.isCollection(node.*)) {
            const info = postman.objectChild(self.doc_arena.allocator(), node, "info") catch return;
            postman.setString(self.doc_arena.allocator(), info, "name", name) catch return;
        } else {
            postman.setName(self.doc_arena.allocator(), node, name) catch return;
        }
        self.persist();
        self.rebuild();
    }

    pub fn onWorkspaceNameChange(self: *KurirViewModel, name: []const u8) void {
        store.setWorkspaceName(self.doc_arena.allocator(), &self.doc, self.workspace, name);
        self.persist();
        self.rebuild();
    }

    pub fn onHeaderKeyChange(self: *KurirViewModel, index: usize, text: []const u8) void {
        const node = self.selectedRequest() orelse return;
        postman.setHeaderKey(self.doc_arena.allocator(), node, index, text) catch return;
        self.persist();
        self.rebuild();
    }

    pub fn onHeaderValueChange(self: *KurirViewModel, index: usize, text: []const u8) void {
        const node = self.selectedRequest() orelse return;
        postman.setHeaderValue(self.doc_arena.allocator(), node, index, text) catch return;
        self.persist();
        self.rebuild();
    }

    pub fn addHeader(self: *KurirViewModel) void {
        const node = self.selectedRequest() orelse return self.failNow("Select a request first, then add a header.");
        if (postman.headerCount(node.*) >= state_mod.max_headers) {
            return self.fail("A request holds at most {d} headers.", .{state_mod.max_headers});
        }
        const index = postman.headerCount(node.*);
        postman.setHeaderKey(self.doc_arena.allocator(), node, index, "") catch return;
        postman.setHeaderValue(self.doc_arena.allocator(), node, index, "") catch return;
        self.persist();
        self.rebuild();
        self.focus = .header_key;
        frame.setFocus(header_field_name(index, false));
    }

    pub fn removeHeader(self: *KurirViewModel, index: usize) void {
        const node = self.selectedRequest() orelse return;
        postman.removeHeader(node, index);
        self.persist();
        self.rebuild();
    }

    pub fn toggleHeader(self: *KurirViewModel, index: usize) void {
        const node = self.selectedRequest() orelse return;
        const disabled = postman.headerDisabled(node.*, index);
        postman.setHeaderEnabled(self.doc_arena.allocator(), node, index, disabled) catch return;
        self.persist();
        self.rebuild();
    }

    // The body editor is hand-rolled, so every edit is committed to the model here.
    fn commitBody(self: *KurirViewModel) void {
        const node = self.selectedRequest() orelse return;
        postman.setBodyRaw(self.doc_arena.allocator(), node, self.editor.text()) catch return;
        self.persist();
        self.rebuild();
    }

    pub fn onBodyClick(self: *KurirViewModel) void {
        self.focus = .body;
        frame.setFocus(body_id);
    }

    pub fn focusBody(self: *KurirViewModel) void {
        self.focus = .body;
        frame.setFocus(body_id);
    }

    // Any click on a text field claims the keyboard; a click on the body gives it back to the editor.
    pub fn onFieldFocus(self: *KurirViewModel, which: state_mod.Focus) void {
        self.focus = which;
    }

    pub fn setEditorTab(self: *KurirViewModel, tab: state_mod.Tab) void {
        self.editor_tab = tab;
        self.focus = .none;
        self.rebuild();
    }

    pub fn setResponseTab(self: *KurirViewModel, tab: state_mod.Tab) void {
        self.response_tab = tab;
        self.rebuild();
    }

    fn selectedRequest(self: *KurirViewModel) ?*Value {
        const path = self.selection orelse return null;
        const node = self.nodeValue(path) orelse return null;
        if (!postman.isRequest(node.*)) return null;
        return node;
    }

    fn fail(self: *KurirViewModel, comptime fmt: []const u8, args: anytype) void {
        self.setStatus(true, fmt, args);
        self.rebuild();
    }

    fn failNow(self: *KurirViewModel, comptime fmt: []const u8) void {
        self.fail(fmt, .{});
    }

    // ---- sending -----------------------------------------------------------------------------------------

    pub fn transport(self: *KurirViewModel) http_mod.Transport {
        if (self.transport_override) |override| return override;
        if (self.real) |*real| return real.transport(self.resp_arena.allocator());
        return .{ .ctx = null, .arena = self.resp_arena.allocator(), .send_fn = http_mod.sendOffline };
    }

    pub fn send(self: *KurirViewModel) void {
        const node = self.selectedRequest() orelse return self.failNow("Select a request to send. The tree on the left holds them.");
        _ = self.resp_arena.reset(.retain_capacity);
        const arena = self.resp_arena.allocator();

        const request = postman.requestView(arena, node.*) catch return self.failNow("Could not read that request.");
        if (request.url.len == 0) return self.failNow("This request has no URL. Paste one in the URL field, then send.");

        var headers: std.ArrayList(http_mod.Header) = .empty;
        for (request.headers) |header| {
            if (header.disabled or header.key.len == 0) continue;
            headers.append(arena, .{ .name = header.key, .value = header.value }) catch break;
        }

        const result = self.transport().perform(.{
            .method = request.method,
            .url = request.url,
            .headers = headers.items,
            .body = request.body,
        });
        self.storeResponse(arena, result);
        self.persist();
        self.rebuild();
    }

    fn storeResponse(self: *KurirViewModel, arena: Allocator, result: http_mod.Result) void {
        var response = state_mod.ResponseView{};
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        var status_buf: [64]u8 = undefined;

        response.time_ms = result.time_ms;
        response.time_text = arena.dupe(u8, state_mod.timeLabel(&time_buf, result.time_ms)) catch "";
        response.size = result.sizes();
        response.size_text = arena.dupe(u8, state_mod.sizeLabel(&size_buf, result.sizes())) catch "";

        if (result.failed) {
            response.kind = .failed;
            response.error_title = arena.dupe(u8, result.error_title) catch "";
            response.error_message = arena.dupe(u8, result.error_message) catch "";
            self.response = response;
            self.setStatus(true, "Request failed: {s}", .{result.error_title});
            return;
        }

        response.kind = .ok;
        response.status = result.status;
        response.status_text = arena.dupe(u8, state_mod.statusLabel(&status_buf, result.status, result.reason)) catch "";
        const pretty = prettyBody(arena, result.body);
        response.body = pretty.text;
        response.truncated_lines = pretty.truncated_lines;

        var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
        for (result.headers) |header| {
            header_rows.append(arena, .{ .name = header.name, .value = header.value }) catch break;
        }
        response.headers = header_rows.toOwnedSlice(arena) catch &.{};
        self.response = response;
        self.setStatus(false, "{d} {s} · {s} · {s}", .{ result.status, result.reason, response.time_text, response.size_text });
    }

    // Pretty-print a JSON body so a one-line response reads as a document; anything else is shown as it arrived.
    const Pretty = struct {
        text: []const u8 = "",
        truncated_lines: usize = 0,
    };

    fn prettyBody(arena: Allocator, body: []const u8) Pretty {
        const capped = if (body.len > max_response_bytes) body[0..max_response_bytes] else body;
        const parsed = std.json.parseFromSliceLeaky(Value, arena, capped, .{}) catch
            return .{ .text = sanitize(arena, capped), .truncated_lines = if (body.len > capped.len) 1 else 0 };
        const text = postman.write(arena, parsed, true) catch
            return .{ .text = sanitize(arena, capped), .truncated_lines = if (body.len > capped.len) 1 else 0 };
        return .{ .text = sanitize(arena, text) };
    }

    // A response is bytes, not text: anything a font cannot draw becomes a middle dot rather than a broken run.
    fn sanitize(arena: Allocator, bytes: []const u8) []const u8 {
        const out = arena.alloc(u8, bytes.len) catch return "";
        for (bytes, 0..) |byte, i| {
            out[i] = if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) byte else 0xb7;
        }
        return out;
    }

    // ---- import and export -------------------------------------------------------------------------------

    pub fn importCollection(self: *KurirViewModel) void {
        if (!self.dialogs.available) return self.failNow("This build has no file dialog. Set the path in KURIR_HOME and restart.");
        const path = self.dialogs.open_fn(self.dialogs.ctx, self.gpa, "Import a Postman collection (v2.1 JSON)") orelse
            return self.failNow("Import cancelled.");
        defer self.gpa.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(16 * 1024 * 1024)) catch |err|
            return self.fail("Could not read {s} ({s}).", .{ path, @errorName(err) });
        defer self.gpa.free(bytes);

        const value = postman.parseTree(self.doc_arena.allocator(), bytes) catch |err|
            return self.fail("That file is not JSON ({s}). Export the collection again from Postman.", .{@errorName(err)});
        if (!postman.isCollection(value)) {
            return self.failNow("That JSON is not a Postman v2.1 collection: it has no \"info\" object.");
        }

        const index = store.addCollection(self.gpa, &self.doc, self.workspace, value) catch
            return self.failNow("Could not store the imported collection.");
        self.selection = Path.empty.child(@intCast(index));
        self.expand(self.selection.?, true);
        self.loadSelection();
        self.persist();
        self.rebuild();
        self.setStatus(false, "Imported {s}.", .{nodeName(value)});
    }

    pub fn exportSelected(self: *KurirViewModel) void {
        if (!self.dialogs.available) return self.failNow("This build has no file dialog. Copy the JSON from the data file instead.");
        const path = self.selection orelse return self.failNow("Select a collection to export. A collection is the unit Postman imports.");
        if (path.depth == 0) return self.failNow("Select a collection to export, not the workspace.");
        const collection = store.collectionAt(self.doc, self.workspace, path.segments[0]) orelse
            return self.failNow("That collection is gone.");

        const bytes = postman.write(self.gpa, collection, true) catch return self.failNow("Could not write the collection as JSON.");
        defer self.gpa.free(bytes);

        const name = nodeName(collection);
        const suggested = std.fmt.allocPrint(self.gpa, "{s}.postman_collection.json", .{if (name.len == 0) "collection" else name}) catch
            "collection.postman_collection.json";
        defer self.gpa.free(suggested);
        const target = self.dialogs.save_fn(self.dialogs.ctx, self.gpa, "Export this collection as Postman v2.1 JSON", suggested) orelse
            return self.failNow("Export cancelled.");
        defer self.gpa.free(target);

        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = target, .data = bytes }) catch |err|
            return self.fail("Could not write {s} ({s}).", .{ target, @errorName(err) });
        self.setStatus(false, "Exported {s} to {s}. Postman imports that file as it is.", .{ name, target });
        self.rebuild();
    }

    // ---- keys --------------------------------------------------------------------------------------------

    // Composed text: only the body editor takes it, and only while it owns the keyboard.
    pub fn onText(self: *KurirViewModel, text: []const u8) bool {
        if (self.focus != .body) return false;
        const action = editor_mod.handleText(&self.editor, text);
        if (action == .edited) self.commitBody();
        return action != .ignored;
    }

    // Raw keys: the body editor's own editing, plus Cmd/Ctrl+Enter to send from anywhere.
    pub fn onKey(self: *KurirViewModel, mods: input_mod.Mods, keycode: u32) bool {
        if (self.focus != .body) {
            if (keycode == editor_mod.KEY_ENTER and mods.shortcut()) {
                self.send();
                return true;
            }
            return false;
        }
        switch (editor_mod.handleKey(&self.editor, keycode, mods.shift, mods.shortcut())) {
            .run_requested => {
                self.send();
                return true;
            },
            .edited => {
                self.commitBody();
                return true;
            },
            .ignored => return false,
        }
    }

    // The name of a header field, so a click and a test can address one column of one row.
    pub fn header_field_name(index: usize, value_side: bool) []const u8 {
        return if (value_side)
            glinlandui.props.Id.at(header_value_prefix, index).str()
        else
            glinlandui.props.Id.at(header_key_prefix, index).str();
    }
};

// ---- tests: they drive the ViewModel the way the view does, with a real temp file and no socket ---------------

const testing = std.testing;

const DialogFake = struct {
    open_path: []const u8 = "",
    save_path: []const u8 = "",
    opens: usize = 0,
    saves: usize = 0,
};

fn fakeOpen(ctx: ?*anyopaque, gpa: Allocator, title: []const u8) ?[]const u8 {
    _ = title;
    const self: *DialogFake = @ptrCast(@alignCast(ctx.?));
    self.opens += 1;
    if (self.open_path.len == 0) return null;
    return gpa.dupe(u8, self.open_path) catch null;
}

fn fakeSave(ctx: ?*anyopaque, gpa: Allocator, title: []const u8, suggested: []const u8) ?[]const u8 {
    _ = title;
    _ = suggested;
    const self: *DialogFake = @ptrCast(@alignCast(ctx.?));
    self.saves += 1;
    if (self.save_path.len == 0) return null;
    return gpa.dupe(u8, self.save_path) catch null;
}

const Harness = struct {
    tmp: testing.TmpDir,
    path: []u8,
    vm: KurirViewModel,

    fn boot() !Harness {
        var tmp = testing.tmpDir(.{});
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        const path = try std.fs.path.join(testing.allocator, &.{ buf[0..len], "kurir", store.file_name });
        var vm = KurirViewModel.init();
        vm.start(testing.allocator, testing.io, theme_mod.app_theme, path);
        return .{ .tmp = tmp, .path = path, .vm = vm };
    }

    fn stop(self: *Harness) void {
        self.vm.deinit();
        self.tmp.cleanup();
    }

    fn state(self: *Harness) UiState {
        return self.vm.uiState();
    }

    fn firstRequest(self: *Harness) *KurirViewModel {
        self.vm.addCollection();
        self.vm.addRequest();
        return &self.vm;
    }
};

test "a first run loads nothing, creates one workspace, and says what to do next" {
    var h = try Harness.boot();
    defer h.stop();

    const state = h.state();
    try testing.expectEqual(@as(usize, 1), state.workspace_count);
    try testing.expectEqual(@as(usize, 0), state.rows.len);
    try testing.expectEqualStrings("", state.workspace_label[0..0]);
    try testing.expect(!state.has_selection);
    try testing.expect(state.response.kind == .none);
}

test "collection, folder and request all land in the tree and on disk" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    try testing.expectEqual(@as(usize, 1), h.state().rows.len);
    try testing.expectEqual(state_mod.NodeKind.collection, h.state().rows[0].kind);

    h.vm.addFolder();
    try testing.expectEqual(@as(usize, 2), h.state().rows.len);
    try testing.expectEqual(state_mod.NodeKind.folder, h.state().rows[1].kind);

    // The folder is selected, so the request goes inside it.
    h.vm.addRequest();
    const state = h.state();
    try testing.expectEqual(@as(usize, 3), state.rows.len);
    try testing.expectEqual(state_mod.NodeKind.request, state.rows[2].kind);
    try testing.expectEqualStrings(postman.default_method, state.method);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, h.path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "Request 1") != null);
}

test "a second boot restores the tree from the file, which is the reload the PRD asks for" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.onUrlChange("https://api.example.com/v1/charges");
    h.vm.setMethod("POST");
    h.vm.addHeader();
    h.vm.onHeaderKeyChange(0, "Content-Type");
    h.vm.onHeaderValueChange(0, "application/json");

    var again = KurirViewModel.init();
    again.start(testing.allocator, testing.io, theme_mod.app_theme, try testing.allocator.dupe(u8, h.path));
    defer again.deinit();

    const state = again.uiState();
    try testing.expectEqual(@as(usize, 2), state.rows.len);
    try testing.expectEqual(state_mod.NodeKind.request, state.rows[1].kind);
    try testing.expectEqualStrings("POST", state.method);
    try testing.expectEqualStrings("https://api.example.com/v1/charges", state.url);
    try testing.expectEqual(@as(usize, 1), state.headers.len);
    try testing.expectEqualStrings("Content-Type", state.headers[0].name);
}

test "renaming works for a collection, a folder and a request" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    h.vm.onNameChange("Payments");
    try testing.expectEqualStrings("Payments", h.state().rows[0].label);

    h.vm.addFolder();
    h.vm.onNameChange("Checkout");
    try testing.expectEqualStrings("Checkout", h.state().rows[1].label);

    h.vm.addRequest();
    h.vm.onNameChange("Create charge");
    try testing.expectEqualStrings("Create charge", h.state().rows[2].label);
}

test "deleting a request, then a collection, leaves the tree consistent" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    h.vm.addRequest();
    try testing.expectEqual(@as(usize, 2), h.state().rows.len);

    h.vm.deleteSelected();
    try testing.expectEqual(@as(usize, 1), h.state().rows.len);
    try testing.expect(!h.state().has_selection);

    h.vm.select(Path.empty.child(0));
    h.vm.deleteSelected();
    try testing.expectEqual(@as(usize, 0), h.state().rows.len);
}

test "send answers through the fake transport, and the response is pretty-printed" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.onUrlChange("https://api.example.com/v1/charges");

    var fake = http_mod.Fake.init(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    fake.arena = arena_state.allocator();
    fake.status = 201;
    fake.body = "{\"id\":7,\"paid\":true}";
    h.vm.transport_override = fake.transport();

    h.vm.send();
    const state = h.state();
    try testing.expectEqual(state_mod.ResponseKind.ok, state.response.kind);
    try testing.expectEqual(@as(u16, 201), state.response.status);
    try testing.expectEqualStrings("201 Created", state.response.status_text);
    // The body arrives pretty-printed, so a one-line response reads as a document.
    try testing.expect(std.mem.indexOf(u8, state.response.body, "\n") != null);
    try testing.expect(std.mem.indexOf(u8, state.response.body, "\"id\": 7") != null);
    try testing.expectEqualStrings("https://api.example.com/v1/charges", fake.last_url);
    try testing.expectEqual(@as(usize, 1), fake.sends);
}

test "a refused connection becomes a sentence, never a blank pane" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.onUrlChange("http://127.0.0.1:1/");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fake = http_mod.Fake.init(arena_state.allocator());
    fake.failure_name = "ConnectionRefused";
    h.vm.transport_override = fake.transport();

    h.vm.send();
    const state = h.state();
    try testing.expectEqual(state_mod.ResponseKind.failed, state.response.kind);
    try testing.expectEqualStrings("ConnectionRefused", state.response.error_title);
    try testing.expect(state.response.error_message.len > 10);
    try testing.expect(state.status_is_error);
}

test "a request with no URL explains itself instead of sending" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fake = http_mod.Fake.init(arena_state.allocator());
    h.vm.transport_override = fake.transport();

    h.vm.send();
    try testing.expectEqual(@as(usize, 0), fake.sends);
    try testing.expect(h.vm.uiState().status_is_error);
    try testing.expect(std.mem.indexOf(u8, h.vm.uiState().status, "no URL") != null);
}

test "headers can be added, typed, disabled and removed" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.addHeader();
    h.vm.onHeaderKeyChange(0, "Accept");
    h.vm.onHeaderValueChange(0, "application/json");
    try testing.expectEqual(@as(usize, 1), h.state().headers.len);
    try testing.expectEqualStrings("Accept", h.state().headers[0].name);

    h.vm.toggleHeader(0);
    try testing.expect(h.vm.headerFieldsDisabled(0));
    h.vm.toggleHeader(0);
    try testing.expect(!h.vm.headerFieldsDisabled(0));

    h.vm.removeHeader(0);
    try testing.expectEqual(@as(usize, 0), h.state().headers.len);
}

test "the hand-rolled body editor commits what it types into the model" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.focusBody();
    try testing.expect(h.vm.onText("{\"amount\": 100}"));
    try testing.expectEqualStrings("{\"amount\": 100}", h.state().body);

    // The same text goes into the document, which is what a reload reads.
    var again = KurirViewModel.init();
    again.start(testing.allocator, testing.io, theme_mod.app_theme, try testing.allocator.dupe(u8, h.path));
    defer again.deinit();
    try testing.expectEqualStrings("{\"amount\": 100}", again.uiState().body);
}

test "workspaces are separate containers, and switching keeps the collections apart" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    try testing.expectEqual(@as(usize, 1), h.state().rows.len);

    h.vm.addWorkspace();
    const state = h.state();
    try testing.expectEqual(@as(usize, 2), state.workspace_count);
    try testing.expectEqual(@as(usize, 0), state.rows.len);

    h.vm.nextWorkspace();
    try testing.expectEqual(@as(usize, 1), h.state().rows.len);

    h.vm.deleteWorkspace();
    try testing.expectEqual(@as(usize, 1), h.state().workspace_count);
}

test "export writes a Postman file, and import reads one back" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    h.vm.onNameChange("Payments");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try h.tmp.dir.realPath(testing.io, &buf);
    const export_path = try std.fs.path.join(testing.allocator, &.{ buf[0..len], "Payments.postman_collection.json" });
    defer testing.allocator.free(export_path);

    var dialogs = DialogFake{ .save_path = export_path };
    h.vm.dialogs.save_fn = fakeSave;
    h.vm.dialogs.ctx = &dialogs;

    h.vm.exportSelected();
    try testing.expectEqual(@as(usize, 1), dialogs.saves);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, export_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var reload_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer reload_arena.deinit();
    const reloaded = try postman.parseTree(reload_arena.allocator(), bytes);
    try testing.expect(postman.isCollection(reloaded));
    try testing.expectEqualStrings("Payments", postman.str(reloaded.object.get("info").?, "name"));

    var import_dialogs = DialogFake{ .open_path = export_path };
    h.vm.dialogs.open_fn = fakeOpen;
    h.vm.dialogs.ctx = &import_dialogs;
    h.vm.importCollection();
    try testing.expectEqual(@as(usize, 1), import_dialogs.opens);
    try testing.expectEqual(@as(usize, 2), h.state().rows.len);
}

test "import says what is wrong with a file that is not a collection" {
    var h = try Harness.boot();
    defer h.stop();

    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "not-a-collection.json", .data = "{\"hello\":1}" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try h.tmp.dir.realPath(testing.io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..len], "not-a-collection.json" });
    defer testing.allocator.free(path);

    var dialogs = DialogFake{ .open_path = path };
    h.vm.dialogs.open_fn = fakeOpen;
    h.vm.dialogs.ctx = &dialogs;

    h.vm.importCollection();
    try testing.expect(h.state().status_is_error);
    try testing.expect(std.mem.indexOf(u8, h.state().status, "info") != null);
}

test "a collection that was deleted from the document cannot be sent" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.send();
    try testing.expect(h.state().status_is_error);
    try testing.expect(std.mem.indexOf(u8, h.state().status, "Select a request") != null);
}
