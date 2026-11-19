//! The left panel's ViewModel: the rows, which folders are open, the workspace strip, and node create/delete.
const std = @import("std");
const glinlandui = @import("glinlandui");
const sidebar = glinlandui.components.sidebar;
const TreeRow = glinlandui.components.tree.Row;
const TreeZone = glinlandui.components.tree.Zone;
const frame = glinlandui.frame;
const prop = glinlandui.props;

const postman = @import("../../data/model/postman.zig");
const curl = @import("../../data/model/curl.zig");
const curl_transfer = @import("../../domain/usecase/curl_transfer.zig");
const store = @import("../../data/local/workspace_store.zig");
const state_mod = @import("../../ui/state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const Path = state_mod.Path;
const UiState = state_mod.UiState;
const Session = session_mod.Session;
const Value = session_mod.Value;

pub const name_field_id = "kurir.name";
pub const workspace_field_id = "kurir.workspace";
pub const filter_field_id = "kurir.filter";
// The "+ New" menu: the button is the anchor, the rows come from the list, the card is the overlay.
pub const new_trigger_id = "kurir.new";
pub const new_list_id = "kurir.new.options";
pub const new_menu_id = "kurir.new.menu";
// The workspace menu: the gear beside the name is the button, the name field is the anchor it drops under.
pub const ws_trigger_id = "kurir.ws.menu";
pub const ws_list_id = "kurir.ws.options";
pub const ws_panel_id = "kurir.ws.panel";

// The two menus' rows, in declaration order: a pick joins the row's index to the intent it raises.
pub const new_rows = [_][]const u8{ "Collection", "Request", "Folder", "Import", "From cURL" };
// What a request row offers on a right click, in the order `pickRowMenu` switches on.
pub const row_menu_items = [_][]const u8{ "Rename", "Duplicate", "Delete", "Run this request..." };
// What a collection or folder row offers: the runner first, then the same three a request has.
pub const run_menu_items = [_][]const u8{ "Run collection...", "Rename", "Duplicate", "Delete" };
// The workspace menu's rows, in the order `onWsPick` switches on.
pub const ws_rows = [_][]const u8{ "New workspace", "Delete workspace", "Export collection" };

// How many bytes a row's name may take before its tail becomes "..".
const name_max: usize = 30;

// ---- what a row is built from ------------------------------------------------------------------

// The URL a request item carries, or "" when the node is not one.
fn requestUrl(node: Value) []const u8 {
    if (node != .object) return "";
    const request = node.object.get("request") orelse return "";
    return postman.urlRaw(request);
}

// A one-line label that fits a narrow row: past the buffer the tail becomes "..", never mid-codepoint.
pub fn clip(text: []const u8, buffer: []u8) []const u8 {
    if (text.len <= buffer.len) {
        @memcpy(buffer[0..text.len], text);
        return buffer[0..text.len];
    }
    var head = buffer.len - 2;
    while (head > 0 and (text[head] & 0xC0) == 0x80) head -= 1;
    @memcpy(buffer[0..head], text[0..head]);
    @memcpy(buffer[head..][0..2], "..");
    return buffer[0 .. head + 2];
}

// A path's address after the child at `removed` left `parent`: every slot past it shifts down one.
fn shiftDown(path: Path, parent_depth: usize, removed: u16) Path {
    var next = path;
    if (next.depth <= parent_depth) return next;
    if (next.segments[parent_depth] > removed) next.segments[parent_depth] -= 1;
    return next;
}

// True when `path` sits inside `ancestor`, which is the one drop a tree must refuse: a folder into itself.
fn insideOf(path: Path, ancestor: Path) bool {
    if (path.depth <= ancestor.depth) return false;
    var level: usize = 0;
    while (level < ancestor.depth) : (level += 1) {
        if (path.segments[level] != ancestor.segments[level]) return false;
    }
    return true;
}

// The word a status line uses for a zone: a row lands above or below the one it was dropped on.
fn side(above: bool) []const u8 {
    return if (above) "above" else "below";
}

// A case-insensitive substring test, which is what a filter box does.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// A node passes the filter when its own name holds the query, or a request inside it does.
fn matchesQuery(node: Value, query: []const u8) bool {
    if (containsIgnoreCase(Session.name(node), query)) return true;
    if (postman.isRequest(node)) return containsIgnoreCase(requestUrl(node), query);
    const count = postman.itemCount(node);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = postman.itemAt(node, i) orelse continue;
        if (matchesQuery(item, query)) return true;
    }
    return false;
}

// The menu names the row it was raised from, and the panel turns that row into its path.
pub fn onRowMenu(raw: ?*anyopaque, action: usize) void {
    const rc: *const Sidebar.RowCtx = @ptrCast(@alignCast(raw.?));
    rc.sidebar.pickRowMenu(rc.index, action);
}

pub const Sidebar = struct {
    session: *Session = undefined,

    expanded: std.ArrayList(Path) = .empty,
    rows: std.ArrayList(state_mod.TreeRow) = .empty,
    // The toolkit's panel state: its width and whether it is collapsed. The app owns it, the widget drags it.
    state: sidebar.State = .{ .width = 300, .expanded_width = 300 },

    // What narrows the tree. The bytes are STATE, and the view binds its filter field to them.
    filter_buf: [256]u8 = undefined,
    filter_len: usize = 0,

    // The two menus. They close each other, so only one card is ever drawn.
    new_menu_open: bool = false,
    ws_menu_open: bool = false,

    // The shell's runner, raised by a container row's card.
    run: RunHook = .{},
    // One click context per row, in a FIXED array: an ArrayList reallocs and a registered click outlives the frame.
    row_ctxs: [state_mod.max_tree_rows]RowCtx = undefined,
    row_ctx_count: usize = 0,

    // A container row's menu asks the shell for the runner, which owns the page.
    pub const RunHook = struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, Path) void = null,
    };

    pub const RowCtx = struct {
        sidebar: *Sidebar,
        index: usize,
    };

    // A keystroke in the name box: the panel's state only, because the view owns the widget.
    pub fn typedName(self: *Sidebar, text: []const u8) void {
        self.session.focus = .name;
        self.onNameChange(text);
    }

    // The name box took the keyboard.
    pub fn focusName(self: *Sidebar) void {
        self.session.focus = .name;
    }

    // Same pair for the workspace's name, which is a workspace field rather than a node's.
    pub fn typedWorkspace(self: *Sidebar, text: []const u8) void {
        self.session.focus = .workspace;
        self.onWorkspaceNameChange(text);
    }

    pub fn focusWorkspace(self: *Sidebar) void {
        self.session.focus = .workspace;
    }

    pub fn isExpanded(self: *const Sidebar, path: Path) bool {
        for (self.expanded.items) |item| {
            if (Path.eql(item, path)) return true;
        }
        return false;
    }

    pub fn expand(self: *Sidebar, path: Path, on: bool) void {
        const found = self.isExpanded(path);
        if (on and !found) {
            self.expanded.append(self.session.gpa, path) catch {};
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

    pub fn firstRequestPath(self: *Sidebar) ?Path {
        const count = store.collectionCount(self.session.doc, self.session.workspace);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const collection = store.collectionAt(self.session.doc, self.session.workspace, i) orelse continue;
            const root = Path.empty.child(@intCast(i));
            if (firstRequestInside(collection, root, 0)) |found| return found;
        }
        return null;
    }

    pub fn expandAncestors(self: *Sidebar, path: Path) void {
        var level: usize = 1;
        while (level < path.depth) : (level += 1) {
            var prefix = Path.empty;
            prefix.depth = level;
            @memcpy(prefix.segments[0..level], path.segments[0..level]);
            self.expand(prefix, true);
        }
    }

    // The tree as the frame draws it: whole, or narrowed to what the filter box says.
    pub fn rebuildRows(self: *Sidebar) void {
        self.rows.clearRetainingCapacity();
        self.row_ctx_count = 0;
        const query = self.filterText();
        // While filtering every container is open, because a match three levels down has to be reachable.
        const filtering = query.len > 0;
        const count = store.collectionCount(self.session.doc, self.session.workspace);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const collection = store.collectionAt(self.session.doc, self.session.workspace, i) orelse continue;
            if (filtering and !matchesQuery(collection, query)) continue;
            const path = Path.empty.child(@intCast(i));
            self.pushRow(collection, path, 0, .collection);
            if (filtering or self.isExpanded(path)) self.pushChildren(collection, path, 1, query);
        }
    }

    pub fn pushChildren(self: *Sidebar, node: Value, path: Path, depth: u16, query: []const u8) void {
        const count = postman.itemCount(node);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const item = postman.itemAt(node, i) orelse continue;
            if (query.len > 0 and !matchesQuery(item, query)) continue;
            const child_path = path.child(@intCast(i));
            const kind = Session.kind(item);
            self.pushRow(item, child_path, depth, kind);
            if (kind == .folder and (query.len > 0 or self.isExpanded(child_path))) self.pushChildren(item, child_path, depth + 1, query);
        }
    }

    pub fn pushRow(self: *Sidebar, node: Value, path: Path, depth: u16, kind: state_mod.NodeKind) void {
        if (self.rows.items.len >= state_mod.max_tree_rows) return;
        const selected = if (self.session.selection) |current| Path.eql(current, path) else false;
        const arena = self.session.view_arena.allocator();
        var name_buf: [name_max]u8 = undefined;
        const raw_name = Session.name(node);
        const label = if (raw_name.len == 0) "(unnamed)" else clip(raw_name, &name_buf);
        self.rows.append(self.session.gpa, .{
            .path = path,
            .depth = depth,
            .kind = kind,
            .label = arena.dupe(u8, label) catch label,
            .method = if (kind == .request) postman.normalizeMethod(postman.str(node.object.get("request").?, "method")) else "",
            .count = if (kind == .request) 0 else @intCast(@min(postman.itemCount(node), std.math.maxInt(u16))),
            .has_children = kind != .request,
            .expanded = self.isExpanded(path),
            .selected = selected,
            // Only an endpoint carries edits of its own; a container is not saved anywhere either way.
            .dirty = kind == .request and self.session.isDirty(path),
        }) catch {};
        self.row_ctx_count = self.rows.items.len;
    }

    // ---- the filter box -------------------------------------------------------------------------------

    pub fn filterText(self: *const Sidebar) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    // The storage the filter's field edits in place, so the widget and this state are one buffer.
    pub fn filterBuffer(self: *Sidebar) []u8 {
        return self.filter_buf[0..];
    }

    // A keystroke in the filter box, and the box taking the keyboard: state only.
    pub fn typedFilter(self: *Sidebar, text: []const u8) void {
        self.session.focus = .filter;
        self.setFilter(text);
    }

    pub fn focusFilter(self: *Sidebar) void {
        self.session.focus = .filter;
    }

    pub fn setFilter(self: *Sidebar, text: []const u8) void {
        // The field's draft IS this buffer, so the copy may be a self-copy: forwards, never @memcpy.
        self.filter_len = @min(text.len, self.filter_buf.len);
        std.mem.copyForwards(u8, self.filter_buf[0..self.filter_len], text[0..self.filter_len]);
        self.session.touch();
    }

    pub fn clearFilter(self: *Sidebar) void {
        // The state only: the field adopts the empty value on the next declare, because the value it holds CHANGED.
        self.filter_len = 0;
        self.session.touch();
    }

    // ---- the two menus -------------------------------------------------------------------------------

    pub fn toggleNew(self: *Sidebar) void {
        self.new_menu_open = !self.new_menu_open;
        if (self.new_menu_open) self.ws_menu_open = false;
        self.session.touch();
    }

    pub fn closeNew(self: *Sidebar) void {
        if (!self.new_menu_open) return;
        self.new_menu_open = false;
        self.session.touch();
    }

    pub fn closeWsMenu(self: *Sidebar) void {
        if (!self.ws_menu_open) return;
        self.ws_menu_open = false;
        self.session.touch();
    }

    pub fn toggleWsMenu(self: *Sidebar) void {
        self.ws_menu_open = !self.ws_menu_open;
        if (self.ws_menu_open) self.new_menu_open = false;
        self.session.touch();
    }

    // No scrim on either card: a menu closes when the pointer leaves its button and its card as one box.
    pub fn closeMenusIfPointerAway(self: *Sidebar) void {
        if (self.new_menu_open and self.pointerAway(new_trigger_id, new_menu_id)) {
            self.new_menu_open = false;
            self.session.touch();
        }
        if (self.ws_menu_open and self.pointerAway(ws_trigger_id, ws_panel_id)) {
            self.ws_menu_open = false;
            self.session.touch();
        }
    }

    // True when the pointer is outside the union of a button and the card hanging under it.
    fn pointerAway(self: *Sidebar, trigger_id: []const u8, card_id: []const u8) bool {
        _ = self;
        const trigger = frame.bounds(frame.clayId(trigger_id)) orelse return false;
        const card = frame.bounds(frame.clayId(card_id)) orelse return false;
        const left = @min(trigger.x, card.x);
        const top = @min(trigger.y, card.y);
        const right = @max(trigger.x + trigger.width, card.x + card.width);
        const bottom = @max(trigger.y + trigger.height, card.y + card.height);
        return frame.ptr_x < left or frame.ptr_x > right or frame.ptr_y < top or frame.ptr_y > bottom;
    }

    pub fn toggleSelected(self: *Sidebar) void {
        if (self.session.selection) |path| self.expand(path, !self.isExpanded(path));
        self.session.touch();
    }

    pub fn addCollection(self: *Sidebar) void {
        const arena = self.session.doc_arena.allocator();
        const id = self.session.randomId(arena);
        const name = std.fmt.allocPrint(arena, "Collection {d}", .{store.collectionCount(self.session.doc, self.session.workspace) + 1}) catch "Collection";
        const collection = postman.newCollection(arena, name, id) catch return self.session.failNow("Could not create a collection.");
        const index = store.addCollection(self.session.gpa, &self.session.doc, self.session.workspace, collection) catch
            return self.session.failNow("Could not create a collection.");
        self.session.selection = Path.empty.child(@intCast(index));
        self.expand(self.session.selection.?, true);

        self.session.commit();
        self.session.setStatus(false, "Created {s}. Add a request inside it.", .{name});
    }

    pub fn addFolder(self: *Sidebar) void {
        const parent = self.containerForInsert() orelse return self.session.failNow("Select a collection or a folder first, then add a folder inside it.");
        const arena = self.session.doc_arena.allocator();
        const node = self.session.nodeAt(parent) orelse return self.session.failNow("That selection is gone. Select a collection again.");
        const name = std.fmt.allocPrint(arena, "Folder {d}", .{postman.itemCount(node.*) + 1}) catch "Folder";
        const folder = postman.newFolder(arena, name) catch return self.session.failNow("Could not create a folder.");
        const index = postman.appendChild(self.session.gpa, node, folder) catch return self.session.failNow("Could not create a folder.");
        self.expand(parent, true);
        self.session.selection = parent.child(@intCast(index));

        self.session.commit();
        self.session.setStatus(false, "Created {s}.", .{name});
    }

    pub fn addRequest(self: *Sidebar) void {
        const parent = self.containerForInsert() orelse return self.session.failNow("Create a collection first, then add a request inside it.");
        const arena = self.session.doc_arena.allocator();
        const node = self.session.nodeAt(parent) orelse return self.session.failNow("That selection is gone. Select a collection again.");
        const name = std.fmt.allocPrint(arena, "Request {d}", .{postman.itemCount(node.*) + 1}) catch "Request";
        const item = postman.newRequest(arena, name, postman.default_method, "") catch return self.session.failNow("Could not create a request.");
        const index = postman.appendChild(self.session.gpa, node, item) catch return self.session.failNow("Could not create a request.");
        self.expand(parent, true);
        self.session.selection = parent.child(@intCast(index));

        self.session.commit();
        self.session.setStatus(false, "Created {s}. Paste a URL and send it.", .{name});
    }

    // "From cURL": the clipboard's `curl …` becomes a request, named after its own URL.
    pub fn addRequestFromCurl(self: *Sidebar) void {
        const buf = self.session.gpa.alloc(u8, curl.max_command) catch return self.session.failNow("Out of memory reading the clipboard.");
        defer self.session.gpa.free(buf);
        const text = glinlandui.clipboard.read(buf);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return self.session.failNow("The clipboard is empty. Copy a curl command first, then press + New again.");
        self.addRequestFromCurlText(text);
    }

    // The same import with the command handed in, so a test (and a future paste box) skips the clipboard.
    pub fn addRequestFromCurlText(self: *Sidebar, text: []const u8) void {
        const parent = self.containerForInsert() orelse return self.session.failNow("Create a collection first, then add a request from a curl command.");
        const node = self.session.nodeAt(parent) orelse return self.session.failNow("That selection is gone. Select a collection again.");
        const arena = self.session.docArena();
        const imported = curl_transfer.parse(arena, text) catch |err| return self.session.fail("That is not a curl command I can read ({s}).", .{@errorName(err)});

        var item = postman.newRequest(arena, imported.name, imported.request.method, imported.request.url) catch
            return self.session.failNow("Could not create a request.");
        if (imported.request.body.len > 0) postman.setBodyRaw(arena, &item, imported.request.body) catch {};
        for (imported.request.headers, 0..) |h, i| {
            postman.setHeaderKey(arena, &item, i, h.name) catch break;
            postman.setHeaderValue(arena, &item, i, h.value) catch break;
        }

        const index = postman.appendChild(self.session.gpa, node, item) catch return self.session.failNow("Could not create a request.");
        self.expand(parent, true);
        self.session.selection = parent.child(@intCast(index));

        self.session.commit();
        self.session.setStatus(false, "Imported {s} from cURL: {s} {s}.", .{ imported.name, imported.request.method, imported.request.url });
    }

    // A row was dropped on another: the panel owns what each zone means for the document.
    pub fn onTreeDrop(self: *Sidebar, from_row: usize, to_row: usize, zone: TreeZone) void {
        const from = self.rowAt(from_row) orelse return;
        const to = self.rowAt(to_row) orelse return;
        if (Path.eql(from, to)) return;
        // A row can never land inside its own subtree: that moves the folder into itself.
        if (insideOf(to, from)) return self.session.failNow("A folder cannot be dropped inside itself.");
        if (zone == .into) return self.dropInto(from, to);
        self.dropBeside(from, to, zone == .before);
    }

    // A drop INSIDE a folder or a collection: the node changes parent, and the container opens to show it.
    fn dropInto(self: *Sidebar, from: Path, to: Path) void {
        const from_parent = from.parent() orelse return self.session.failNow("A collection is a top-level row: it cannot be dropped inside another one.");
        const source = self.session.nodeAt(from) orelse return self.session.failNow("That row is gone. Try again.");
        const target = self.session.nodeAt(to) orelse return self.session.failNow("That folder is gone. Try again.");
        if (postman.isRequest(target.*)) return self.session.failNow("A request holds nothing. Drop above or below it instead.");
        const old_parent = self.session.nodeAt(from_parent) orelse return self.session.failNow("That folder is gone. Try again.");
        const moved_name = Session.name(source.*);
        const from_index = from.segments[from.depth - 1];
        const node = postman.detachChild(self.session.docArena(), old_parent, from_index) orelse return self.session.failNow("That row is gone. Try again.");
        // The document moved under the pointer, so the target is re-addressed before anything is written to it.
        const destination = shiftDown(to, from_parent.depth, from_index);
        const container = self.session.nodeAt(destination) orelse return self.session.failNow("That folder is gone. Try again.");
        const at = postman.appendChild(self.session.gpa, container, node) catch return self.session.failNow("Could not move that row.");
        self.expand(destination, true);
        self.expandAncestors(destination);
        self.session.selection = destination.child(@intCast(at));
        self.session.commit();
        self.session.setStatus(false, "Moved {s} into {s}.", .{ moved_name, Session.name(container.*) });
    }

    // A drop ABOVE or BELOW another row: a reorder among siblings, or a move into another folder's list.
    fn dropBeside(self: *Sidebar, from: Path, to: Path, above: bool) void {
        const from_parent = from.parent();
        const to_parent = to.parent();
        // Two collections are siblings in the workspace's own array, which is the same move one level up.
        if (from_parent == null and to_parent == null) return self.moveCollectionBeside(from, to, above);
        if (from_parent == null or to_parent == null) return self.session.failNow("A collection and a folder are not in one list. Drop the row inside a collection instead.");
        const from_index = from.segments[from.depth - 1];
        const source = self.session.nodeAt(from) orelse return self.session.failNow("That row is gone. Try again.");
        const target = self.session.nodeAt(to) orelse return self.session.failNow("That row is gone. Try again.");
        const moved_name = Session.name(source.*);
        const target_name = Session.name(target.*);
        if (Path.eql(from_parent.?, to_parent.?)) {
            const parent = self.session.nodeAt(from_parent.?) orelse return self.session.failNow("That folder is gone. Try again.");
            const to_index = to.segments[to.depth - 1];
            // The slot is asked in the list the row has ALREADY left, so anything past it comes back one.
            var at = if (above) to_index else to_index + 1;
            if (at > from_index) at -= 1;
            if (at == from_index) return;
            if (!postman.moveChild(parent, from_index, at)) return self.session.failNow("Could not move that row.");
            self.expand(from_parent.?, true);
            self.session.selection = from_parent.?.child(@intCast(at));
            self.session.commit();
            self.session.setStatus(false, "Moved {s} {s} {s}.", .{ moved_name, side(above), target_name });
            return;
        }
        // Cross-parent: the row leaves one folder and takes the slot it was dropped on in another.
        const old_parent = self.session.nodeAt(from_parent.?) orelse return self.session.failNow("That folder is gone. Try again.");
        const node = postman.detachChild(self.session.docArena(), old_parent, from_index) orelse return self.session.failNow("That row is gone. Try again.");
        const destination = shiftDown(to, from_parent.?.depth, from_index);
        const new_parent_path = destination.parent() orelse return self.session.failNow("That row is gone. Try again.");
        const new_parent = self.session.nodeAt(new_parent_path) orelse return self.session.failNow("That folder is gone. Try again.");
        const to_index = destination.segments[destination.depth - 1];
        const at = postman.insertChild(self.session.gpa, new_parent, if (above) to_index else to_index + 1, node) catch return self.session.failNow("Could not move that row.");
        self.expand(new_parent_path, true);
        self.expandAncestors(new_parent_path);
        self.session.selection = new_parent_path.child(@intCast(at));
        self.session.commit();
        self.session.setStatus(false, "Moved {s} {s} {s}.", .{ moved_name, side(above), target_name });
    }

    // Two collections in one workspace: the same above-or-below move, applied to `collections[]`.
    fn moveCollectionBeside(self: *Sidebar, from: Path, to: Path, above: bool) void {
        const from_index: usize = from.segments[0];
        const to_index: usize = to.segments[0];
        var at = if (above) to_index else to_index + 1;
        if (at > from_index) at -= 1;
        if (at == from_index) return;
        const source = store.collectionAt(self.session.doc, self.session.workspace, from_index) orelse return self.session.failNow("That collection is gone. Try again.");
        const target = store.collectionAt(self.session.doc, self.session.workspace, to_index) orelse return self.session.failNow("That collection is gone. Try again.");
        const moved_name = Session.name(source);
        const target_name = Session.name(target);
        if (!store.moveCollection(self.session.gpa, &self.session.doc, self.session.workspace, from_index, at)) return self.session.failNow("Could not move that collection.");
        self.session.selection = Path.empty.child(@intCast(at));
        self.session.commit();
        self.session.setStatus(false, "Moved {s} {s} {s}.", .{ moved_name, side(above), target_name });
    }

    // A right-click menu pick for the row at `row_index`: the row's PATH is read now, so a shifted row cannot act on a neighbour.
    pub fn pickRowMenu(self: *Sidebar, row_index: usize, action: usize) void {
        const path = self.rowAt(row_index) orelse return self.session.failNow("That row is gone. Right-click it again.");
        const node = self.session.nodeAt(path) orelse return self.session.failNow("That request is gone. Right-click it again.");
        // A request runs as a flow seeded with its own name; a container seeds every request under it.
        if (!postman.isRequest(node.*)) {
            switch (action) {
                0 => self.runFrom(path),
                1 => self.renameAt(path),
                2 => self.duplicateAt(path),
                else => self.deleteAt(path),
            }
            return;
        }
        switch (action) {
            0 => self.renameAt(path),
            1 => self.duplicateAt(path),
            2 => self.deleteAt(path),
            else => self.runFrom(path),
        }
    }

    // The runner lives in the shell; the card only says which row was asked for.
    fn runFrom(self: *Sidebar, path: Path) void {
        if (self.run.f) |run| run(self.run.ctx, path);
    }

    // Rename: select the row and hand the keyboard to the name field, which is where a name is typed.
    pub fn renameAt(self: *Sidebar, path: Path) void {
        self.select(path);
        // The view selects the whole name when the field gains the keyboard, so the first keystroke replaces it.
        frame.setFocus(name_field_id);
        self.session.setStatus(false, "Type a new name, then press Enter.", .{});
    }

    // Duplicate: a deep copy under the same parent, named "… copy", selected so it can be edited at once.
    pub fn duplicateAt(self: *Sidebar, path: Path) void {
        const parent_path = path.parent() orelse return self.session.failNow("That row has no parent to hold a copy.");
        const parent = self.session.nodeAt(parent_path) orelse return self.session.failNow("That folder is gone. Right-click the request again.");
        const source = self.session.nodeAt(path) orelse return self.session.failNow("That request is gone. Right-click it again.");
        const arena = self.session.docArena();
        var copy = postman.clone(arena, source.*) catch return self.session.failNow("Could not duplicate that request.");
        const name = postman.str(source.*, "name");
        const copy_name = std.fmt.allocPrint(arena, "{s} copy", .{name}) catch name;
        postman.setName(arena, &copy, copy_name) catch {};
        const index = postman.appendChild(self.session.gpa, parent, copy) catch return self.session.failNow("Could not duplicate that request.");
        self.expand(parent_path, true);
        self.session.selection = parent_path.child(@intCast(index));

        self.session.commit();
        self.session.setStatus(false, "Duplicated as {s}.", .{copy_name});
    }

    // Delete: the row's own node, selected first so the delete acts on what was right-clicked.
    pub fn deleteAt(self: *Sidebar, path: Path) void {
        self.session.selection = path;
        self.deleteSelected();
    }

    pub fn containerForInsert(self: *Sidebar) ?Path {
        if (self.session.selection) |path| {
            const node = self.session.nodeAt(path) orelse return null;
            if (!postman.isRequest(node.*)) return path;
            return path.parent();
        }
        if (store.collectionCount(self.session.doc, self.session.workspace) > 0) return Path.empty.child(0);
        return null;
    }

    pub fn deleteSelected(self: *Sidebar) void {
        const path = self.session.selection orelse return self.session.failNow("Select something to delete first.");
        if (path.depth == 0) return;
        if (path.depth == 1) {
            store.removeCollection(&self.session.doc, self.session.workspace, path.segments[0]);
        } else {
            const parent_path = path.parent() orelse return;
            const parent = self.session.nodeAt(parent_path) orelse return;
            postman.removeChild(self.session.gpa, parent, path.segments[path.depth - 1]);
        }
        self.session.selection = null;

        self.session.commit();
        self.session.setStatus(false, "Deleted. Everything else is untouched.", .{});
    }

    pub fn addWorkspace(self: *Sidebar) void {
        const arena = self.session.doc_arena.allocator();
        const id = self.session.randomId(arena);
        const name = std.fmt.allocPrint(arena, "Workspace {d}", .{store.workspaceCount(self.session.doc) + 1}) catch "Workspace";
        var workspace: postman.Object = .empty;
        workspace.put(arena, "id", .{ .string = id }) catch return self.session.failNow("Could not create a workspace.");
        workspace.put(arena, "name", .{ .string = name }) catch return self.session.failNow("Could not create a workspace.");
        workspace.put(arena, "collections", .{ .array = postman.Array.init(arena) }) catch return self.session.failNow("Could not create a workspace.");
        const index = store.addWorkspace(self.session.gpa, &self.session.doc, .{ .object = workspace }) catch
            return self.session.failNow("Could not create a workspace.");
        self.session.workspace = index;
        self.session.selection = null;
        self.expanded.clearRetainingCapacity();

        self.session.commit();
        self.session.setStatus(false, "Switched to {s}. Collections here are separate.", .{name});
    }

    pub fn nextWorkspace(self: *Sidebar) void {
        const count = store.workspaceCount(self.session.doc);
        if (count <= 1) return self.session.failNow("There is only one workspace. Add another to switch between them.");
        self.switchWorkspace((self.session.workspace + 1) % count);
    }

    pub fn switchWorkspace(self: *Sidebar, index: usize) void {
        if (index >= store.workspaceCount(self.session.doc)) return;
        self.session.workspace = index;
        self.session.selection = null;
        self.expanded.clearRetainingCapacity();
        if (store.collectionCount(self.session.doc, self.session.workspace) > 0) {
            self.session.selection = Path.empty.child(0);
            self.expand(self.session.selection.?, true);
        }

        self.session.touch();
        self.session.setStatus(false, "Switched to {s}.", .{store.workspaceName(self.session.doc, self.session.workspace)});
    }

    pub fn deleteWorkspace(self: *Sidebar) void {
        const count = store.workspaceCount(self.session.doc);
        if (count == 0) return;
        const name = store.workspaceName(self.session.doc, self.session.workspace);
        store.removeWorkspace(&self.session.doc, self.session.workspace);
        if (store.workspaceCount(self.session.doc) == 0) {
            const arena = self.session.doc_arena.allocator();
            const id = self.session.randomId(arena);
            const fresh = store.blank(arena, id) catch return self.session.failNow("Could not reset the workspace list.");
            self.session.doc = fresh;
        }
        if (self.session.workspace >= store.workspaceCount(self.session.doc)) self.session.workspace = store.workspaceCount(self.session.doc) - 1;
        self.session.selection = null;
        self.expanded.clearRetainingCapacity();

        self.session.commit();
        self.session.setStatus(false, "Deleted workspace {s}.", .{name});
    }

    pub fn onNameChange(self: *Sidebar, name: []const u8) void {
        const path = self.session.selection orelse return;
        const node = self.session.nodeAt(path) orelse return;
        if (postman.isCollection(node.*)) {
            const info = postman.objectChild(self.session.doc_arena.allocator(), node, "info") catch return;
            postman.setString(self.session.doc_arena.allocator(), info, "name", name) catch return;
        } else {
            postman.setName(self.session.doc_arena.allocator(), node, name) catch return;
        }
        self.session.commit();
    }

    pub fn onWorkspaceNameChange(self: *Sidebar, name: []const u8) void {
        store.setWorkspaceName(self.session.doc_arena.allocator(), &self.session.doc, self.session.workspace, name);
        self.session.commit();
    }

    // The first request inside a node, so a reload lands the editor on something usable.
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

    // A returning user wants to be where the work is: the first request, not the collection above it.
    pub fn restore(self: *Sidebar) void {
        if (self.firstRequestPath()) |found| {
            self.session.selection = found;
            self.expandAncestors(found);
        } else if (store.collectionCount(self.session.doc, self.session.workspace) > 0) {
            self.session.selection = Path.empty.child(0);
            self.expand(Path.empty.child(0), true);
        }
    }

    pub fn start(self: *Sidebar, session: *Session) void {
        self.session = session;
        // A click context per row: one fixed array, so a registered click never points at freed memory.
        for (&self.row_ctxs, 0..) |*ctx, i| ctx.* = .{ .sidebar = self, .index = i };
    }

    pub fn deinit(self: *Sidebar) void {
        self.expanded.deinit(self.session.gpa);
        self.rows.deinit(self.session.gpa);
    }

    // The left panel's props: the limits and tones live here, so the view only adds its own call site.
    pub fn props(self: *Sidebar) sidebar.Props {
        const t = self.session.theme;
        return .{
            .id = .{ .text = "kurir.sidebar" },
            .state = &self.state,
            .min_width = 252,
            .max_width = 460,
            // Narrower than this and the tool rows no longer fit, so a drag past it means "close it".
            .collapse_below = 180,
            .collapsed_width = 0,
            .h = .grow,
            .bg = t.colors.surface,
            .handle_bg = t.colors.surface_variant,
            .handle_hover_bg = t.colors.hover,
            .handle_active_bg = t.colors.primary,
        };
    }

    // The width the panel settled on. Read while the frame is declared, because a drag happens there.
    pub fn width(self: *Sidebar) f32 {
        return sidebar.width(self.props());
    }

    // The keyboard-free way to open and close the panel, for a button or a shortcut later.
    pub fn togglePanel(self: *Sidebar) void {
        self.state.collapsed = !self.state.collapsed;
        if (!self.state.collapsed) self.state.width = self.state.expanded_width;
        self.session.touch();
    }

    // A row's path by index, which is what a click on list row N means.
    pub fn rowAt(self: *Sidebar, index: usize) ?Path {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index].path;
    }

    pub fn select(self: *Sidebar, path: Path) void {
        self.session.selection = path;
        if (self.session.nodeAt(path)) |node| {
            if (Session.kind(node.*) != .request) self.expand(path, !self.isExpanded(path));
        }
        self.session.touch();
    }

    // A node was added or imported: it becomes the selection, and its parent opens to show it.
    pub fn reveal(self: *Sidebar, path: Path) void {
        self.session.selection = path;
        self.expand(path, true);
        self.expandAncestors(path);
        self.session.touch();
    }

    // The tree component's own row shape: a label, a depth, its caret state, and its count as the meta.
    fn treeRows(self: *Sidebar, arena: Allocator) []const TreeRow {
        const out = arena.alloc(TreeRow, self.rows.items.len) catch return &.{};
        for (self.rows.items, out) |r, *row| {
            row.* = .{
                .label = r.label,
                .depth = r.depth,
                .has_children = r.has_children,
                .expanded = r.expanded,
                .selected = r.selected,
                .meta = if (r.count > 0) std.fmt.allocPrint(arena, "{d}", .{r.count}) catch "" else "",
                .kind = if (r.kind == .request) .item else .group,
            };
        }
        return out;
    }

    // One menu per row: a request offers the three actions it always had, a container offers the runner too.
    fn treeMenus(self: *Sidebar, arena: Allocator) []const prop.ContextMenu {
        const out = arena.alloc(prop.ContextMenu, self.rows.items.len) catch return &.{};
        const t = self.session.theme;
        for (self.rows.items, out, 0..) |r, *menu, i| {
            const items: []const []const u8 = if (r.kind == .request) &row_menu_items else &run_menu_items;
            menu.* = .{
                .items = items,
                .on_select = .{ .f = onRowMenu, .ctx = &self.row_ctxs[i] },
                .bg = t.colors.surface,
                .fg = t.colors.text,
                .hover_bg = t.colors.hover,
                .border = t.colors.divider,
            };
        }
        return out;
    }

    // The panel's slice of the frame: the rows, the workspace strip, and what the tools may do.
    pub fn snapshot(self: *Sidebar, u: *UiState, arena: Allocator) void {
        self.rebuildRows();
        u.rows = self.rows.items;
        u.tree_rows = self.treeRows(arena);
        u.tree_menus = self.treeMenus(arena);
        u.selection = self.session.selection;
        u.workspace_index = self.session.workspace;
        u.workspace_count = store.workspaceCount(self.session.doc);
        u.workspace_name = store.workspaceName(self.session.doc, self.session.workspace);
        u.workspace_label = std.fmt.allocPrint(arena, "{s}  ·  {d}/{d}", .{
            u.workspace_name,
            self.session.workspace + 1,
            u.workspace_count,
        }) catch u.workspace_name;
        u.collection_count = store.collectionCount(self.session.doc, self.session.workspace);
        u.has_collection = u.collection_count > 0;
        u.sidebar_width = self.width();
        u.sidebar_collapsed = self.state.collapsed;
        u.filter = self.filterText();
        u.filter_active = self.filter_len > 0;
        u.new_menu_open = self.new_menu_open;
        u.ws_menu_open = self.ws_menu_open;

        if (self.session.selection) |path| {
            if (self.session.nodeAt(path)) |node| {
                u.has_selection = true;
                u.node_kind = Session.kind(node.*);
                u.node_name = Session.name(node.*);
                u.can_delete = true;
                u.can_add_folder = u.node_kind != .request;
                u.can_add_request = true;
            }
        }
    }
};
