//! The Activity: the theme, the container, and the composition. No widget code lives here.
const std = @import("std");
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;

const view = @import("ui/shell/screen.zig");
const view_model = @import("ui/shell/view_model.zig");
const theme_mod = @import("ui/theme/theme.zig");
const container_mod = @import("di/container.zig");
const pump_mod = @import("ui/shell/pump.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.KurirViewModel) = .{},
    // `MaterialTheme`: the Activity picks it, and the model and the view both read it.
    theme: glinlandui.theme.Theme = theme_mod.app_theme,
    // Every dependency the screen needs is built here, once, and borrowed by the ViewModel.
    container: container_mod.Container = .{},
    // The window's frame pump: `main` points it at the window it creates, a headless test leaves it a no-op.
    pump: pump_mod.Pump = .{},

    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    // `onCreate`: build the container, load the document, and give the URL field the keyboard.
    pub fn start(self: *App, gpa: std.mem.Allocator, io: std.Io, environ: anytype) !void {
        self.gpa = gpa;
        self.io = io;
        try self.container.init(gpa, io, environ);
        const model = self.vm();
        model.start(.{
            .gpa = gpa,
            .io = io,
            .theme = self.theme,
            .path = self.container.path,
            .session_path = self.container.session_path,
            .env_path = self.container.env_path,
            .workspace = self.container.file.workspace(),
            .remote = &self.container.remote,
            .dialogs = &self.container.dialogs,
            .pump = &self.pump,
        });
        // The URL field takes the keyboard only when there is a request to type into.
        if (model.uiState().node_kind == .request) frame.setFocus(view_model.url_field_id);
    }

    pub fn deinit(self: *App) void {
        self.store.clear();
        self.container.deinit();
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.KurirViewModel {
        return self.store.getOrCreate(view_model.KurirViewModel.init);
    }

    // `setContent { MaterialTheme { KurirScreen() } }`, as the Host's root function.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();
        // The engine keeps the window's size and the zoom; a weight takes the room its row has, so nothing here needs either.
        _ = w;
        _ = h;
        // A Host forgets the focus an Activity claimed before it existed, so the first frame claims it again.
        if (!frame.focusKnown() and model.uiState().node_kind == .request) frame.setFocus(view_model.url_field_id);
        var scope = view.Scope{
            .theme = self.theme,
            .vm = model,
            .state = model.uiState(),
        };
        view.KurirScreen(&scope);
    }
};
