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

// Ask for another frame while a request is in flight. Only the backends that can be asked have the call:
// the Linux/Wayland window draws on demand and exposes no `setAnimating`, so there the pump is a no-op.
fn setAnimating(ctx: ?*anyopaque, on: bool) void {
    const win: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) win.setAnimating(on);
}
