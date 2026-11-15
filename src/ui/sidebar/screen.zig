//! The left panel's screen: the workspace strip, the tool rows and the tree.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const input_mod = glinlandui.components.input;
const list_mod = glinlandui.components.list;
const scroll_mod = glinlandui.components.scroll;
const sidebar_mod = glinlandui.components.sidebar;
const text_mod = glinlandui.components.text;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");

const smallButton = widgets.smallButton;
const tabButton = widgets.tabButton;

const Scope = scope_mod.Scope;
const row_h = scope_mod.row_h;
const indent = scope_mod.indent;

pub fn sidebarChildren(scope: *Scope) void {
    // Pinned to the panel's own width: text metrics must never widen the panel past the line the pointer holds.
    const w = sidebar_mod.width(scope.vm.sidebar.props());
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.sidebar.content" },
        .direction = .column,
        .w = .{ .fixed = w },
        .h = .grow,
    }, scope, sidebarContent);
}

pub fn sidebarContent(scope: *Scope) void {
    workspaceStrip(scope);
    toolbar(scope);
    tree(scope);
}

pub fn workspaceStrip(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.sides(10, 10, 8, 10),
        .gap = .{ .px = 6 },
    }, scope, workspaceStripChildren);
}

pub fn workspaceStripChildren(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws.head" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .child_align = .{ .y = .center },
    }, scope, wsHead);

    text_mod.label(.{ .label = .{ .text = scope.state.workspace_label, .size = t.type_scale.caption, .color = t.colors.text_dim } });

    const field = &scope.vm.sidebar.workspace_field;
    field.value = scope.state.workspace_name;
    field.w = .grow;
    input_mod.textField(field);
}

pub fn wsHead(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "WORKSPACE", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    box_mod.spacer(.{ .text = "kurir.ws.spacer" });
    smallButton(scope, "kurir.ws.add", "+", 26, actions.onAddWorkspace);
    smallButton(scope, "kurir.ws.next", "->", 26, actions.onNextWorkspace);
    smallButton(scope, "kurir.ws.del", "-", 26, actions.onDeleteWorkspace);
}

pub fn toolbar(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.sides(0, 10, 8, 10),
        .gap = .{ .px = 6 },
    }, scope, toolbarChildren);
}

pub fn toolbarChildren(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools.row1" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .child_align = .{ .y = .center },
    }, scope, toolsRowOne);

    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools.row2" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .child_align = .{ .y = .center },
    }, scope, toolsRowTwo);
}

pub fn toolsRowOne(scope: *Scope) void {
    smallButton(scope, "kurir.add.collection", "+ Collection", 122, actions.onAddCollection);
    smallButton(scope, "kurir.add.folder", "+ Folder", 96, actions.onAddFolder);
}

pub fn toolsRowTwo(scope: *Scope) void {
    smallButton(scope, "kurir.add.request", "+ Request", 122, actions.onAddRequest);
    smallButton(scope, "kurir.import", "Import", 70, actions.onImport);
    smallButton(scope, "kurir.export", "Export", 70, actions.onExport);
}

pub fn tree(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.rows.len == 0) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.tree.empty" },
            .direction = .column,
            .w = .grow,
            .pad = props.Pad.all(16),
            .gap = .{ .px = 8 },
            .hover_bg = scope.theme.colors.hover,
            // The empty state is the first button a new user presses, so it is one.
            .on_click = .{ .f = actions.onAddCollection, .ctx = scope.vm },
        }, scope, emptyTree);
        return;
    }
    scroll_mod.scroll(.{
        .id = .{ .text = "kurir.tree" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.surface,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, treeChildren);
}

pub fn emptyTree(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "No collections yet.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = "Click here, or press + Collection, to make one.", .size = t.type_scale.caption, .color = t.colors.text_done }, .wrap = true });
}

pub fn treeChildren(scope: *Scope) void {
    const t = scope.theme;
    list_mod.list(.{
        .id = .{ .text = "kurir.tree.list" },
        .row_h = .{ .px = @floatFromInt(row_h) },
        .row_bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .selected_bg = t.colors.surface_variant,
        .selected_fg = t.colors.text,
        .row_fg = t.colors.text,
        .radius = .{ .px = 0 },
        .on_select = .{ .f = actions.onRow, .ctx = scope.vm },
    }, scope.state.rows, scope, renderRow);
}

// A row: a caret for a container, a coloured method for a request, then the name.
const RowScope = struct {
    scope: *Scope,
    row: state_mod.TreeRow,
    index: usize,
};

pub fn renderRow(scope: *Scope, row: state_mod.TreeRow, index: usize) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.row", index) },
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(row_h) },
        .pad = props.Pad.sides(0, 8, 0, @floatFromInt(8 + row.depth * indent)),
        .gap = .{ .px = 6 },
        .child_align = .{ .y = .center },
    }, &RowScope{ .scope = scope, .row = row, .index = index }, rowChildren);
}

pub fn rowChildren(rs: *const RowScope) void {
    const t = rs.scope.theme;
    const row = rs.row;

    if (row.has_children) {
        text_mod.label(.{ .label = .{ .text = if (row.expanded) "v" else ">", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    } else {
        text_mod.label(.{ .label = .{ .text = " ", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    }

    if (row.kind == .request) {
        text_mod.label(.{ .label = .{ .text = row.method, .size = t.type_scale.caption, .color = theme_mod.methodColor(row.method) } });
    } else {
        text_mod.label(.{ .label = .{ .text = if (row.kind == .collection) "[]" else "{}", .size = t.type_scale.caption, .color = t.colors.text_done } });
    }

    text_mod.label(.{
        .label = .{
            .text = if (row.label.len == 0) "(unnamed)" else row.label,
            .size = t.type_scale.body,
            .color = if (row.selected) t.colors.text else t.colors.text_dim,
        },
        .wrap = false,
    });
}
