// The entry point: the window, the Host, and the composable it renders. Nothing else.
const std = @import("std");
const builtin = @import("builtin");
const glinlandui = @import("glinlandui");
const kurirw = @import("kurirw");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var app = kurirw.app.App{};
    try app.start(gpa, init.io, init.environ_map);
    defer app.deinit();

    var host = try glinlandui.host.Host.init(gpa, &app, kurirw.app.App.content);
    defer host.deinit();
    // Unsaved edits hold the window open and ask their question; the answer closes it through this host.
    host.close_hook = onCloseRequested;
    host.close_ctx = &app;
    app.vm().quit = .{ .ctx = &host, .f = onQuit };
    // Ctrl/Cmd+S saves the document, whichever field has the keyboard.
    host.keys.register(onShortcut, &app);
    // A Debug or ReleaseSafe build is a build a developer is looking at, so the component tree is one right-click away.
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) _ = glinlandui.devtools.attach(gpa, &host);

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "kurirw",
        .title = "Kurir — API client",
        .width = 1280,
        .height = 840,
        .min_width = 900,
        .min_height = 560,
    });
    // While a request is in flight the window keeps presenting frames, so `uiState()` can collect it.
    app.pump = .{ .ctx = &window, .set_fn = setAnimating };
    window.delegate = host.delegate();
    try window.run();
}

// Only a backend that can be asked has `setAnimating`; the Linux window draws on demand, so there the pump is a no-op.
fn setAnimating(ctx: ?*anyopaque, on: bool) void {
    const win: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) win.setAnimating(on);
}

// `s` in the evdev numbering every backend reports, which is what the key chain hands an app.
const key_s: u32 = 31;

// The window is closing: with unsaved edits the app holds it open and asks, and the answer calls requestQuit.
fn onCloseRequested(ctx: ?*anyopaque) bool {
    const app: *kurirw.app.App = @ptrCast(@alignCast(ctx.?));
    return app.vm().requestClose();
}

fn onQuit(ctx: ?*anyopaque) void {
    const host: *glinlandui.host.Host = @ptrCast(@alignCast(ctx.?));
    host.requestQuit();
}

// Ctrl/Cmd+S: the one shortcut the app claims before the focused field sees the key.
fn onShortcut(ctx: ?*anyopaque, mods: glinlandui.components.input.Mods, keycode: u32) bool {
    if (keycode != key_s or !mods.shortcut()) return false;
    const app: *kurirw.app.App = @ptrCast(@alignCast(ctx.?));
    app.vm().save();
    return true;
}
