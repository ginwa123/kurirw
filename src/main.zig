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
    window.delegate = host.delegate();
    try window.run();
}
