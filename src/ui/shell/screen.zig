//! The window's root function: it composes the three panels and owns the layout between them.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const frame = glinlandui.frame;
const modal_mod = glinlandui.components.modal;
const props = glinlandui.props;
const sidebar_mod = glinlandui.components.sidebar;
const split_mod = glinlandui.components.split;
const tabs_mod = glinlandui.components.tabs;
const text_mod = glinlandui.components.text;

const theme_mod = @import("../theme/theme.zig");
const state_mod = @import("../state.zig");
const scope_mod = @import("scope.zig");
const actions = @import("actions.zig");
const sidebar_screen = @import("../sidebar/screen.zig");
const editor_screen = @import("../editor/screen.zig");
const env_screen = @import("../env/screen.zig");
const response_screen = @import("../response/screen.zig");

pub const Scope = scope_mod.Scope;

// The tab bar and the question it asks before the window closes: the two ids a test addresses them by.
pub const tabs_id = "kurir.tabs";
pub const quit_id = "kurir.quit";

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
    // The tab bar is the editor's row, not the window's: one tab per open endpoint, above the request.
    tabBar(scope);
    // The manager takes the main area the request and its answer were using: it is a page, not a second window.
    if (scope.state.env_manager) {
        env_screen.managerPage(scope);
    } else {
        editor_screen.requestEditor(scope);
        splitGrip(scope);
        response_screen.responsePane(scope, scope.vm.responseHeight());
    }
    statusBar(scope);
    quitPrompt(scope);
}

// The open endpoints: the tab on screen is the brightest one, and a tab with unsaved edits wears a dot where its close box sits.
fn tabBar(scope: *Scope) void {
    if (scope.state.tabs.len == 0) return;
    const t = scope.theme;
    tabs_mod.tabs(.{
        .src = @src(),
        .id = .{ .text = tabs_id },
        .tabs = scope.state.tabs,
        .h = .{ .fixed = 34 },
        // Every tab is the same width, so the bar reads as a bar however long a request's name is.
        .tab_w = .{ .px = 176 },
        .bg = t.colors.background,
        .active_bg = theme_mod.tab_active,
        .hover_bg = theme_mod.tab_hover,
        .fg = t.colors.text_dim,
        .active_fg = t.colors.text,
        .close_fg = t.colors.text_done,
        .close_hover = t.colors.hover,
        // The dot that stands in for the close box is the sidebar's unsaved tone, so one colour means one thing.
        .dirty_fg = theme_mod.accent,
        // The active tab keeps one bright edge, drawn where it meets the pane it opens.
        .active_line = theme_mod.accent,
        .divider = t.colors.divider,
        .drop_line = theme_mod.accent,
        .on_select = .{ .f = actions.onPickTab, .ctx = scope.vm },
        .on_close = .{ .f = actions.onCloseTab, .ctx = scope.vm },
        // Drag a tab onto another to move it, and right click one for Save / Close others / Close to a side / Close.
        .on_move = actions.onMoveTab,
        .ctx = scope.vm,
        .menu = .{
            .f = actions.onPickTabMenu,
            .ctx = scope.vm,
            .style = .{
                .bg = t.colors.surface,
                .fg = t.colors.text,
                .hover_bg = t.colors.hover,
                .disabled_fg = t.colors.text_done,
                .border = t.colors.divider,
            },
        },
    });
}

// The question the window asks when it is closed with unsaved edits: a scrim, a sentence and three answers.
fn quitPrompt(scope: *Scope) void {
    if (!scope.state.quit_prompt) return;
    const t = scope.theme;
    const answers = [_]modal_mod.Action{
        .{ .label = "Cancel" },
        .{ .label = "Quit without saving" },
        .{ .label = "Save and quit", .primary = true },
    };
    modal_mod.modal(.{
        .src = @src(),
        .id = .{ .text = quit_id },
        .title = "Unsaved changes",
        .message = "This endpoint is not saved yet. Save it before the window closes?",
        .actions = &answers,
        .on_action = .{ .f = actions.onQuitAction, .ctx = scope.vm },
        .window_w = scope.vm.viewport_w,
        .window_h = scope.vm.viewport_h,
        .bg = t.colors.surface,
        .border = t.colors.divider,
        .title_fg = t.colors.text,
        .fg = t.colors.text_dim,
        .action_bg = t.colors.surface_variant,
        .action_hover = t.colors.hover,
        .action_fg = t.colors.text,
        .primary = theme_mod.accent,
        .primary_hover = t.colors.primary_hover,
        .primary_fg = t.colors.on_primary,
    });
}

// Dragging this line up grows the response, the way dragging the sidebar's line widens the panel.
fn splitGrip(scope: *Scope) void {
    var p = scope.vm.splitProps();
    p.src = @src();
    split_mod.grip(p);
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
        .border = .all(1, t.colors.divider),
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
