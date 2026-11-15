//! The window's root function: it composes the three panels and owns the layout between them.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const frame = glinlandui.frame;
const props = glinlandui.props;
const sidebar_mod = glinlandui.components.sidebar;
const text_mod = glinlandui.components.text;

const theme_mod = @import("../theme/theme.zig");
const state_mod = @import("../state.zig");
const scope_mod = @import("scope.zig");
const sidebar_screen = @import("../sidebar/screen.zig");
const editor_screen = @import("../editor/screen.zig");
const response_screen = @import("../response/screen.zig");

pub const Scope = scope_mod.Scope;

pub fn KurirScreen(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.root" },
        .direction = .row,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.background,
    }, scope, rootChildren);
}

pub fn rootChildren(scope: *Scope) void {
    // The panel and its grab line are the toolkit's; what goes inside is Kurir's.
    var panel = scope.vm.sidebar.props();
    panel.src = @src();
    sidebar_mod.sidebar(panel, scope, sidebar_screen.sidebarChildren);
    mainArea(scope);
}

fn mainArea(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.main" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.background,
    }, scope, mainChildren);
}

fn mainChildren(scope: *Scope) void {
    editor_screen.requestEditor(scope);
    response_screen.responsePane(scope);
    statusBar(scope);
}

// The status line lives with the work, not with the tree, so an error never reads as a collection row.
fn statusBar(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.status" },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.axes(6, 14),
        .child_align = .{ .y = .center },
        .bg = t.colors.surface,
        .border = .{ .width = 1, .color = t.colors.divider },
    }, scope, statusChildren);
}

fn statusChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{
        .text = scope.state.status,
        .size = t.type_scale.caption,
        .color = if (scope.state.status_is_error) theme_mod.danger else t.colors.text_dim,
    }, .wrap = true });
}
