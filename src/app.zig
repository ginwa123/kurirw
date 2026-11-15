//! The Activity: the store, the theme, and the composition. No widget code lives here.
const std = @import("std");
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;
const input_mod = glinlandui.components.input;

const view = @import("view.zig");
const view_model = @import("view_model.zig");
const theme_mod = @import("theme.zig");
const store_mod = @import("model/store.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.KurirViewModel) = .{},
    // `MaterialTheme`: the Activity picks it, and the model and the view both read it.
    theme: glinlandui.theme.Theme = theme_mod.app_theme,
    // The file panels import and export open; a test replaces them.
    dialogs: view_model.Dialogs = .{},

    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    // `onCreate`: resolve where the document lives, load it, and give the URL field the keyboard.
    pub fn start(self: *App, gpa: std.mem.Allocator, io: std.Io, environ: anytype) !void {
        self.gpa = gpa;
        self.io = io;
        const path = try store_mod.defaultPath(gpa, environ);
        const model = self.vm();
        model.dialogs = self.dialogs;
        model.start(gpa, io, self.theme, path);
        // The URL field takes the keyboard only when there is a request to type into.
        if (model.uiState().node_kind == .request) frame.setFocus(view_model.url_field_id);
    }

    pub fn deinit(self: *App) void {
        self.store.clear();
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.KurirViewModel {
        return self.store.getOrCreate(view_model.KurirViewModel.init);
    }

    // `setContent { MaterialTheme { KurirScreen() } }`, as the Host's root function.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();
        var scope = view.Scope{
            .theme = self.theme,
            .vm = model,
            .state = model.uiState(),
        };
        view.KurirScreen(&scope);
    }

    // Keys reach the ViewModel only so the hand-rolled body editor can edit; everything else the engine types.
    pub fn keyHandler(ctx: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        return self.vm().onKey(mods, keycode);
    }

    pub fn textHandler(ctx: ?*anyopaque, text: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        return self.vm().onText(text);
    }
};
