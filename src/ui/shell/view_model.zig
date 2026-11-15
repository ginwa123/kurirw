//! The screen's ViewModel: one of each panel, the wiring between them, and the intents the view raises.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const split_mod = glinlandui.components.split;

const postman = @import("../../data/model/postman.zig");
const store = @import("../../data/local/workspace_store.zig");
const http_mod = @import("../../data/remote/http_client.zig");
const state_mod = @import("../state.zig");
const theme_mod = @import("../theme/theme.zig");
const file_store = @import("../../data/repository/workspace_impl.zig");

const session_mod = @import("session.zig");
const sidebar_mod = @import("../sidebar/view_model.zig");
const editor_mod = @import("../editor/view_model.zig");
const response_mod = @import("../response/view_model.zig");
const pump_mod = @import("pump.zig");

const file_picker = @import("../../data/local/file_picker.zig");
const request_job = @import("../../data/remote/request_job.zig");
const domain = @import("../../domain/repository/workspace.zig");
const send_request = @import("../../domain/usecase/send_request.zig");
const import_collection = @import("../../domain/usecase/import_collection.zig");
const export_collection = @import("../../domain/usecase/export_collection.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Path = state_mod.Path;
const Session = session_mod.Session;
const Sidebar = sidebar_mod.Sidebar;
const Editor = editor_mod.Editor;
const Response = response_mod.Response;

// The widget ids the view and the E2E tests address. Each lives where it is created.
pub const url_field_id = editor_mod.url_field_id;
pub const name_field_id = sidebar_mod.name_field_id;
pub const workspace_field_id = sidebar_mod.workspace_field_id;
pub const body_id = editor_mod.body_id;
pub const header_key_prefix = editor_mod.header_key_prefix;
pub const header_value_prefix = editor_mod.header_value_prefix;
pub const body_pad = editor_mod.body_pad;
pub const line_height = editor_mod.line_height;

pub const Dialogs = file_picker.Dialogs;
pub const filter_field_id = sidebar_mod.filter_field_id;
pub const new_trigger_id = sidebar_mod.new_trigger_id;
pub const new_list_id = sidebar_mod.new_list_id;
pub const ws_trigger_id = sidebar_mod.ws_trigger_id;
pub const ws_list_id = sidebar_mod.ws_list_id;
pub const method_trigger_id = editor_mod.method_trigger_id;
pub const method_list_id = editor_mod.method_list_id;
pub const method_menu_id = editor_mod.method_menu_id;
pub const HeaderCtx = Editor.HeaderCtx;

// Everything the screen needs from outside, built once by `di/container.zig`.
pub const Deps = struct {
    gpa: Allocator,
    io: std.Io,
    theme: glinlandui.theme.Theme,
    path: []const u8,
    workspace: domain.Workspace,
    remote: *http_mod.Real,
    dialogs: *file_picker.Dialogs,
    pump: *pump_mod.Pump,
};

pub const KurirViewModel = struct {
    // The view addresses a header toggle by the context the editor creates.
    pub const HeaderCtx = Editor.HeaderCtx;

    // The three panels plus the document they share.
    session: Session = .{},
    sidebar: Sidebar = .{},
    editor: Editor = .{},
    response: Response = .{},

    // The frame's snapshot, rebuilt once per frame while `session.dirty`.
    view: UiState = .{},

    // The line between the editor and the response: the response's height is what it drags.
    split: split_mod.State = .{ .size = 320 },
    // The window's height, so the split knows how much room there is; `App.content` hands it over every frame.
    viewport_h: f32 = 840,

    // Borrowed, not owned: the container built them and outlives the view.
    dialogs: *Dialogs = undefined,
    real: ?*http_mod.Real = null,
    // A test installs a scripted transport, so no suite opens a socket.
    transport_override: ?http_mod.Transport = null,

    // The window's frame pump, borrowed from the Activity: on while a request is in flight.
    pump: *pump_mod.Pump = undefined,
    // One request at a time, on its own task. The frame loop collects it the moment it lands.
    job: ?Pending = null,

    const Pending = struct {
        job: *request_job.Job,
        // The endpoint it belongs to, keyed when the send started.
        key: response_mod.Key,
    };

    pub fn init() KurirViewModel {
        // Everything is defaulted: the session's arenas wait for `start`, and so does the wiring.
        return .{};
    }

    pub fn start(self: *KurirViewModel, deps: Deps) void {
        // The panels hold `*Session`, so the session is wired FIRST and nothing may move afterwards.
        self.dialogs = deps.dialogs;
        self.real = deps.remote;
        self.pump = deps.pump;
        self.session.start(deps.gpa, deps.io, deps.theme, deps.path, deps.workspace);
        self.sidebar.start(&self.session);
        // A row click selects here, not in the panel: the editor has to follow the selection.
        self.sidebar.click_owner = self;
        self.sidebar.click_fn = onRowClick;
        self.editor.start(&self.session);
        self.response.start(&self.session);
        // The one intent that crosses panels: Ctrl/Cmd+Enter while the body has the keyboard sends.
        self.editor.body_field.on_submit = .{ .f = onBodySubmit, .ctx = self };

        const loaded = self.session.load();
        self.sidebar.restore();
        self.editor.load();
        self.session.touch();
        // A first run leaves the file behind, so the next start has something to load.
        if (!loaded.from_disk and loaded.error_name.len == 0) self.session.persist();
    }

    pub fn deinit(self: *KurirViewModel) void {
        // Quitting waits for a finished request and abandons a running one: joining would hold the window.
        if (self.job) |pending| {
            if (pending.job.poll()) pending.job.destroy(self.session.gpa) else pending.job.abandon();
        }
        self.job = null;
        self.response.deinit();
        self.editor.deinit();
        self.sidebar.deinit();
        self.session.deinit();
        self.* = undefined;
    }

    // `onCleared`: the store calls this when the screen goes away.
    pub fn onCleared(self: *KurirViewModel) void {
        self.deinit();
    }

    // ---- the frame's snapshot ---------------------------------------------------------------------------

    // `uiState`: what the view draws. A panel resizes while the frame is declared, so its numbers refresh here.
    pub fn uiState(self: *KurirViewModel) UiState {
        // A request on its own task is collected here, so a frame never waits for the network.
        self.collect();
        // Neither menu has a scrim: each panel closes its own when the pointer leaves it, read from the last frame.
        self.editor.closeIfPointerAway();
        self.sidebar.closeMenusIfPointerAway();
        if (self.session.dirty) self.refresh();
        self.view.sidebar_width = self.sidebar.width();
        self.view.sidebar_collapsed = self.sidebar.state.collapsed;
        self.view.response_h = self.responseHeight();
        return self.view;
    }

    fn refresh(self: *KurirViewModel) void {
        _ = self.session.view_arena.reset(.retain_capacity);
        const arena = self.session.view_arena.allocator();
        var view = UiState{};
        self.sidebar.snapshot(&view, arena);
        self.editor.snapshot(&view, arena);
        self.response.snapshot(&view);
        view.status = self.session.status();
        view.status_is_error = self.session.status_is_error;
        view.focus = self.session.focus;
        view.dialog_available = self.dialogs.available;
        view.sending = self.job != null;
        // An empty workspace offers nothing to delete or to put a request into.
        if (!view.has_collection and !view.has_selection) view.can_add_request = false;
        self.view = view;
        self.session.dirty = false;
    }

    // ---- the facade: one line per intent, so the view and the tests never reach into a panel -------

    // The window changed size: the split's ceiling follows it, so a smaller window cannot squeeze the editor out.
    pub fn setViewport(self: *KurirViewModel, h: u32) void {
        self.viewport_h = @floatFromInt(h);
    }

    // The line between the editor and the response. A pane BELOW a horizontal line grows as the line goes up.
    pub fn splitProps(self: *KurirViewModel) split_mod.Props {
        const t = self.session.theme;
        return .{
            .id = .{ .text = "kurir.split" },
            .state = &self.split,
            .axis = .horizontal,
            .side = .after,
            .min = state_mod.response_min_h,
            .max = @max(state_mod.response_min_h, self.viewport_h - state_mod.editor_min_h),
            .thickness = 6,
            // A step lighter than both panes, so the line reads as a divider before the pointer ever touches it.
            .bg = t.colors.surface_variant,
            .hover_bg = t.colors.hover,
            .active_bg = theme_mod.accent,
        };
    }

    // The height the response draws at right now: read while the frame is declared, because a drag happens there.
    pub fn responseHeight(self: *KurirViewModel) f32 {
        return split_mod.size(self.splitProps());
    }

    pub fn sidebarProps(self: *KurirViewModel) glinlandui.components.sidebar.Props {
        return self.sidebar.props();
    }

    pub fn toggleSidebar(self: *KurirViewModel) void {
        self.sidebar.togglePanel();
    }

    // The row click the panel's boxes raise, installed once in `start`.
    fn onRowClick(raw: ?*anyopaque, index: usize) void {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        self.onRowSelect(index);
    }

    // The panel's two menus and its filter, as the view raises them.
    pub fn toggleNewMenu(self: *KurirViewModel) void {
        self.sidebar.toggleNew();
    }

    pub fn pickNewMenu(self: *KurirViewModel, index: usize) void {
        self.sidebar.closeNew();
        switch (index) {
            0 => self.addCollection(),
            1 => self.addRequest(),
            2 => self.addFolder(),
            3 => self.importCollection(),
            else => {},
        }
    }

    pub fn toggleWorkspaceMenu(self: *KurirViewModel) void {
        self.sidebar.toggleWsMenu();
    }

    pub fn pickWorkspaceMenu(self: *KurirViewModel, index: usize) void {
        self.sidebar.closeWsMenu();
        switch (index) {
            0 => self.addWorkspace(),
            1 => self.deleteWorkspace(),
            2 => self.exportSelected(),
            else => {},
        }
    }

    pub fn setFilter(self: *KurirViewModel, text: []const u8) void {
        self.sidebar.setFilter(text);
    }

    pub fn onRowSelect(self: *KurirViewModel, index: usize) void {
        const path = self.sidebar.rowAt(index) orelse return;
        self.select(path);
    }

    pub fn select(self: *KurirViewModel, path: Path) void {
        self.sidebar.select(path);
        self.editor.load();
    }

    pub fn toggleSelected(self: *KurirViewModel) void {
        self.sidebar.toggleSelected();
    }

    // A structural change: the tree moved, so the editor re-reads whatever is selected now.
    fn sync(self: *KurirViewModel) void {
        self.editor.load();
        self.session.touch();
    }

    pub fn addCollection(self: *KurirViewModel) void {
        self.sidebar.addCollection();
        self.sync();
    }

    pub fn addFolder(self: *KurirViewModel) void {
        self.sidebar.addFolder();
        self.sync();
    }

    pub fn addRequest(self: *KurirViewModel) void {
        self.sidebar.addRequest();
        self.sync();
    }

    pub fn deleteSelected(self: *KurirViewModel) void {
        self.sidebar.deleteSelected();
        self.response.forgetAll();
        self.sync();
    }

    pub fn addWorkspace(self: *KurirViewModel) void {
        self.sidebar.addWorkspace();
        self.sync();
    }

    pub fn nextWorkspace(self: *KurirViewModel) void {
        self.sidebar.nextWorkspace();
        self.sync();
    }

    pub fn deleteWorkspace(self: *KurirViewModel) void {
        self.sidebar.deleteWorkspace();
        self.response.forgetAll();
        self.sync();
    }

    pub fn onNameChange(self: *KurirViewModel, name: []const u8) void {
        self.sidebar.onNameChange(name);
    }

    pub fn onWorkspaceNameChange(self: *KurirViewModel, name: []const u8) void {
        self.sidebar.onWorkspaceNameChange(name);
    }

    pub fn setMethod(self: *KurirViewModel, method: []const u8) void {
        self.editor.setMethod(method);
    }

    pub fn toggleMethods(self: *KurirViewModel) void {
        self.editor.toggleMethods();
    }

    pub fn pickMethod(self: *KurirViewModel, index: usize) void {
        self.editor.pickMethod(index);
    }

    pub fn onUrlChange(self: *KurirViewModel, url: []const u8) void {
        self.editor.onUrlChange(url);
    }

    pub fn onHeaderKeyChange(self: *KurirViewModel, index: usize, text: []const u8) void {
        self.editor.onHeaderKeyChange(index, text);
    }

    pub fn onHeaderValueChange(self: *KurirViewModel, index: usize, text: []const u8) void {
        self.editor.onHeaderValueChange(index, text);
    }

    pub fn addHeader(self: *KurirViewModel) void {
        self.editor.addHeader();
    }

    pub fn removeHeader(self: *KurirViewModel, index: usize) void {
        self.editor.removeHeader(index);
    }

    pub fn toggleHeader(self: *KurirViewModel, index: usize) void {
        self.editor.toggleHeader(index);
    }

    pub fn headerFieldsDisabled(self: *KurirViewModel, index: usize) bool {
        return self.editor.headerDisabled(index);
    }

    pub fn setBody(self: *KurirViewModel, text: []const u8) void {
        self.editor.setBody(text);
    }

    pub fn setEditorTab(self: *KurirViewModel, tab: state_mod.Tab) void {
        self.editor.setTab(tab);
    }

    pub fn setResponseTab(self: *KurirViewModel, tab: state_mod.Tab) void {
        self.response.setTab(tab);
    }

    // Which body lines a frame must declare. The pane asks the panel, never the geometry itself.
    pub fn visibleBodyLines(self: *KurirViewModel, total: usize) response_mod.Visible {
        return self.response.visibleLines(total);
    }

    // ---- sending ----------------------------------------------------------------------------------------

    pub fn transport(self: *KurirViewModel, arena: Allocator) http_mod.Transport {
        if (self.transport_override) |override| return override;
        if (self.real) |real| return real.transport(arena);
        return .{ .ctx = null, .arena = arena, .send_fn = http_mod.sendOffline };
    }

    pub fn send(self: *KurirViewModel) void {
        if (self.job != null) return self.session.failNow("A request is already in flight. Wait for it to answer.");
        const node = self.session.selectedRequest() orelse
            return self.session.failNow("Select a request to send. The tree on the left holds them.");
        // The result belongs to the endpoint that is selected now, so it is keyed before the request runs.
        const key = self.response.begin() orelse
            return self.session.failNow("Select a request to send. The tree on the left holds them.");

        const gpa = self.session.gpa;
        const job = request_job.Job.create(gpa, self.session.io) catch
            return self.session.failNow("Could not start the request.");
        const wire = send_request.build(job.arena(), node.*) catch |err| {
            job.destroy(gpa);
            return switch (err) {
                error.NotARequest => self.session.failNow("Could not read that request."),
                error.NoUrl => self.session.failNow("This request has no URL. Paste one in the URL field, then send."),
            };
        };
        job.request = .{ .method = wire.method, .url = wire.url, .headers = wire.headers, .body = wire.body };
        // The transport writes into the job's arena, on the job's thread: the frame never waits for it.
        job.start(self.transport(job.arena()));

        self.job = .{ .job = job, .key = key };
        self.pump.set(true);
        self.session.setStatus(false, "Sending {s}...", .{wire.method});
        self.session.touch();
    }

    // Called once per frame: an acquire load while the request runs, a collect once it has answered.
    fn collect(self: *KurirViewModel) void {
        const pending = self.job orelse return;
        if (!pending.job.poll()) return;
        const result = pending.job.take();
        self.job = null;
        self.pump.set(false);
        // Store FIRST: the result and the formatted body point into the job's arena, and `store` copies them out.
        self.response.store(pending.key, result, pending.job.shown);
        pending.job.destroy(self.session.gpa);
    }

    // ---- import and export ------------------------------------------------------------------------------

    pub fn importCollection(self: *KurirViewModel) void {
        if (!self.dialogs.available) return self.session.failNow("This build has no file dialog. Set the path in KURIR_HOME and restart.");
        const path = self.dialogs.open_fn(self.dialogs.ctx, self.session.gpa, "Import a Postman collection (v2.1 JSON)") orelse
            return self.session.failNow("Import cancelled.");
        defer self.session.gpa.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.session.io, path, self.session.gpa, .limited(16 * 1024 * 1024)) catch |err|
            return self.session.fail("Could not read {s} ({s}).", .{ path, @errorName(err) });
        defer self.session.gpa.free(bytes);

        const value = import_collection.parse(self.session.docArena(), bytes) catch |err| switch (err) {
            error.NotJson => return self.session.failNow("That file is not JSON. Export the collection again from Postman."),
            error.NotACollection => return self.session.failNow("That JSON is not a Postman v2.1 collection: it has no \"info\" object."),
        };

        const index = store.addCollection(self.session.gpa, &self.session.doc, self.session.workspace, value) catch
            return self.session.failNow("Could not store the imported collection.");
        self.sidebar.reveal(Path.empty.child(@intCast(index)));
        self.sync();
        self.session.persist();
        self.session.setStatus(false, "Imported {s}.", .{Session.name(value)});
    }

    pub fn exportSelected(self: *KurirViewModel) void {
        if (!self.dialogs.available) return self.session.failNow("This build has no file dialog. Copy the JSON from the data file instead.");
        const path = self.session.selection orelse return self.session.failNow("Select a collection to export. A collection is the unit Postman imports.");
        if (path.depth == 0) return self.session.failNow("Select a collection to export, not the workspace.");
        const collection = store.collectionAt(self.session.doc, self.session.workspace, path.segments[0]) orelse
            return self.session.failNow("That collection is gone.");

        const bytes = export_collection.bytes(self.session.gpa, collection) catch
            return self.session.failNow("Could not write the collection as JSON.");
        defer self.session.gpa.free(bytes);

        const suggested = export_collection.suggestedName(self.session.gpa, Session.name(collection));
        defer self.session.gpa.free(suggested);
        const target = self.dialogs.save_fn(self.dialogs.ctx, self.session.gpa, "Export this collection as Postman v2.1 JSON", suggested) orelse
            return self.session.failNow("Export cancelled.");
        defer self.session.gpa.free(target);

        std.Io.Dir.cwd().writeFile(self.session.io, .{ .sub_path = target, .data = bytes }) catch |err|
            return self.session.fail("Could not write {s} ({s}).", .{ target, @errorName(err) });
        self.session.setStatus(false, "Exported {s} to {s}. Postman imports that file as it is.", .{ Session.name(collection), target });
        self.session.touch();
    }

    // Ctrl/Cmd+Enter: the field asks whether the intent took the draft. It did not, so the body stays where it is.
    fn onBodySubmit(raw: ?*anyopaque, text: []const u8) bool {
        const self: *KurirViewModel = @ptrCast(@alignCast(raw.?));
        _ = text;
        self.send();
        return false;
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
    // On the heap: the panels hold `*Session`, so a by-value copy would leave them pointing at a dead frame.
    vm: *KurirViewModel,
    deps: *Deps,
    dialogs: *file_picker.Dialogs,
    file: *file_store.FileStore,
    remote: *http_mod.Real,
    pump: *pump_mod.Pump,

    fn boot() !Harness {
        var tmp = testing.tmpDir(.{});
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        const path = try std.fs.path.join(testing.allocator, &.{ buf[0..len], "kurir", store.file_name });

        const file = try testing.allocator.create(file_store.FileStore);
        file.* = file_store.FileStore.init(testing.io, path);
        const remote = try testing.allocator.create(http_mod.Real);
        remote.* = http_mod.Real.init(testing.allocator);
        const dialogs = try testing.allocator.create(file_picker.Dialogs);
        dialogs.* = .{};
        const pump = try testing.allocator.create(pump_mod.Pump);
        pump.* = .{};
        const deps = try testing.allocator.create(Deps);
        deps.* = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .theme = theme_mod.app_theme,
            .path = path,
            .workspace = file.workspace(),
            .remote = remote,
            .dialogs = dialogs,
            .pump = pump,
        };

        const vm = try testing.allocator.create(KurirViewModel);
        vm.* = KurirViewModel.init();
        vm.start(deps.*);
        return .{ .tmp = tmp, .path = path, .vm = vm, .deps = deps, .dialogs = dialogs, .file = file, .remote = remote, .pump = pump };
    }

    fn stop(self: *Harness) void {
        self.vm.deinit();
        testing.allocator.destroy(self.vm);
        self.remote.deinit();
        testing.allocator.destroy(self.remote);
        testing.allocator.destroy(self.dialogs);
        testing.allocator.destroy(self.pump);
        testing.allocator.destroy(self.deps);
        testing.allocator.destroy(self.file);
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    // A send runs on its own task, so a test pumps the frame the way the app does until it answers.
    fn settle(self: *Harness) void {
        var spins: usize = 0;
        while (self.vm.uiState().sending) : (spins += 1) {
            if (spins > 5_000) return;
            std.Io.sleep(testing.io, .fromMilliseconds(2), .awake) catch {};
        }
        _ = self.vm.uiState();
    }

    // A second ViewModel over the same file: the reload the PRD asks for.
    fn reopen(self: *Harness) !*KurirViewModel {
        const vm = try testing.allocator.create(KurirViewModel);
        vm.* = KurirViewModel.init();
        vm.start(self.deps.*);
        return vm;
    }

    fn state(self: *Harness) UiState {
        return self.vm.uiState();
    }

    fn firstRequest(self: *Harness) *KurirViewModel {
        self.vm.addCollection();
        self.vm.addRequest();
        return self.vm;
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

    const again = try h.reopen();
    defer {
        again.deinit();
        testing.allocator.destroy(again);
    }

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
    h.settle();
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
    h.settle();
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
    h.settle();
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

test "the body field commits what it types into the model" {
    var h = try Harness.boot();
    defer h.stop();

    _ = h.firstRequest();
    h.vm.setBody("{\"amount\": 100}");
    try testing.expectEqualStrings("{\"amount\": 100}", h.state().body);

    // The same text goes into the document, which is what a reload reads.
    const again = try h.reopen();
    defer {
        again.deinit();
        testing.allocator.destroy(again);
    }
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
    h.dialogs.save_fn = fakeSave;
    h.dialogs.ctx = &dialogs;

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
    h.dialogs.open_fn = fakeOpen;
    h.dialogs.ctx = &import_dialogs;
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
    h.dialogs.open_fn = fakeOpen;
    h.dialogs.ctx = &dialogs;

    h.vm.importCollection();
    try testing.expect(h.state().status_is_error);
    try testing.expect(std.mem.indexOf(u8, h.state().status, "info") != null);
}

test "a collection that was deleted from the document cannot be sent" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.send();
    h.settle();
    try testing.expect(h.state().status_is_error);
    try testing.expect(std.mem.indexOf(u8, h.state().status, "Select a request") != null);
}

test "the filter narrows the tree to matches, keeps their collection, and clearing restores it" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    h.vm.addRequest();
    h.vm.onNameChange("List charges");
    h.vm.addRequest();
    h.vm.onNameChange("Ping");
    try testing.expectEqual(@as(usize, 3), h.state().rows.len);

    // One match keeps the container above it, because a row is not reachable without its collection.
    h.vm.setFilter("charges");
    const narrowed = h.state();
    try testing.expect(narrowed.filter_active);
    try testing.expectEqual(@as(usize, 2), narrowed.rows.len);
    try testing.expectEqual(state_mod.NodeKind.collection, narrowed.rows[0].kind);
    try testing.expectEqualStrings("List charges", narrowed.rows[1].label);

    // The URL counts too: the request is named Ping, its URL is what holds the word.
    h.vm.select(state_mod.Path.empty.child(0).child(1));
    h.vm.onUrlChange("https://api.example.com/ping");
    h.vm.setFilter("example.com");
    try testing.expectEqual(@as(usize, 2), h.state().rows.len);

    // Nothing matches: the tree is empty, and the panel knows why.
    h.vm.setFilter("zzz");
    try testing.expectEqual(@as(usize, 0), h.state().rows.len);
    try testing.expect(h.state().filter_active);

    h.vm.setFilter("");
    try testing.expectEqual(@as(usize, 3), h.state().rows.len);
    try testing.expect(!h.state().filter_active);
}

test "a collection row carries how many children it holds" {
    var h = try Harness.boot();
    defer h.stop();

    h.vm.addCollection();
    h.vm.addRequest();
    h.vm.addRequest();
    const rows = h.state().rows;
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(u16, 2), rows[0].count);
    // A request counts nothing: it holds no children.
    try testing.expectEqual(@as(u16, 0), rows[1].count);
}

test "a long label is clipped with two dots, never inside a codepoint" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("abcdefgh", sidebar_mod.clip("abcdefgh", &buffer));
    try testing.expectEqualStrings("abcdef..", sidebar_mod.clip("abcdefghij", &buffer));

    var small: [4]u8 = undefined;
    // "aaa" + a two-byte "e acute": the clip backs off to a boundary instead of writing half a glyph.
    try testing.expectEqualStrings("aa..", sidebar_mod.clip("aaa\xc3\xa9", &small));
}
