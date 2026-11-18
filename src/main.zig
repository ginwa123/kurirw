// The entry point: the window, the Host, and the composable it renders. Nothing else.
const std = @import("std");
const builtin = @import("builtin");
const glinlandui = @import("glinlandui");
const kurirw = @import("kurirw");
const version = @import("version.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // `kurirw --version` answers without a window, which is how the installer says what it installed.
    if (wantsVersion(init.minimal.args, gpa)) {
        // stdout, because a version is output: a script captures it without touching its error handling.
        var buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "kurirw {s}\n", .{version.text}) catch "kurirw\n";
        std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
        return;
    }

    var app = kurirw.app.App{};
    try app.start(gpa, init.io, init.environ_map);
    defer app.deinit();

    var host = try glinlandui.host.Host.init(gpa, &app, kurirw.app.App.content);
    defer host.deinit();
    // The app's own face, installed before the first frame so no width was measured with the toolkit's bundled one.
    kurirw.font.install(gpa) catch |err| std.debug.print("kurir: the embedded face could not be installed ({s}); drawing with the toolkit's\n", .{@errorName(err)});
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
    // The engine zooms for Ctrl/Cmd `+`/`-`/`0`; the app only says how small its layout may get, so a zoom that would not fit stops early.
    host.min_content = .{ .w = 900, .h = 560 };
    // The Activity's theme reaches the window once: every widget that leaves a spacing prop unset follows it.
    host.theme = app.theme;
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

// Ctrl/Cmd+S saves the document, before the focused field sees the key; Ctrl/Cmd `+`, `-`, `0` zoom is the engine's own.
fn onShortcut(ctx: ?*anyopaque, mods: glinlandui.components.input.Mods, keycode: u32) bool {
    if (!mods.shortcut()) return false;
    const app: *kurirw.app.App = @ptrCast(@alignCast(ctx.?));
    switch (keycode) {
        key_s => app.vm().save(),
        else => return false,
    }
    return true;
}

// The one argument the app answers: `--version` (or `-V`), so a script can ask a binary what it is.
fn wantsVersion(args: std.process.Args, gpa: std.mem.Allocator) bool {
    // Windows keeps its command line in UTF-16, so the iterator needs an allocator on every platform here.
    var it = std.process.Args.Iterator.initAllocator(args, gpa) catch return false;
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return true;
    }
    return false;
}
