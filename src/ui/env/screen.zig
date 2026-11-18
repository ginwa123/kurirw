//! The manager's page: the workspace's environments on the left, the selected one's variables on the right.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const button = glinlandui.components.button.button;
const textField = glinlandui.components.input.textField;
const scroll = glinlandui.components.scroll.scroll;
const label = glinlandui.components.text.label;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("../state.zig");
const scope_mod = @import("../shell/scope.zig");
const views_mod = @import("../shell/views.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");
const env_vm = @import("view_model.zig");

const smallButton = widgets.smallButton;
const Scope = scope_mod.Scope;

// The manager's widgets: styled and bound on the first frame that declares them.
fn views(scope: *Scope) *views_mod.Views.Env {
    const v = &scope.views.env;
    if (v.started) return v;
    const session = &scope.vm.session;
    const vm = scope.vm;
    var i: usize = 0;
    while (i < state_mod.max_env_vars) : (i += 1) {
        v.names[i] = session.fieldStyle(.at(env_vm.name_prefix, i), @src());
        v.names[i].bind();
        v.initial[i] = session.fieldStyle(.at(env_vm.initial_prefix, i), @src());
        v.initial[i].bind();
        v.current[i] = session.fieldStyle(.at(env_vm.current_prefix, i), @src());
        v.current[i].bind();
        v.names[i].on_change = .{ .f = env_vm.onTyped, .ctx = &vm.env.var_ctxs[i * 3] };
        v.initial[i].on_change = .{ .f = env_vm.onTyped, .ctx = &vm.env.var_ctxs[i * 3 + 1] };
        v.current[i].on_change = .{ .f = env_vm.onTyped, .ctx = &vm.env.var_ctxs[i * 3 + 2] };
    }
    // The right pane's title IS the environment's name field, so a rename is typing.
    v.name = session.fieldStyle(.{ .text = env_vm.env_name_id }, @src());
    v.name.bind();
    v.name.on_change = .{ .f = env_vm.onNameTyped, .ctx = &vm.env.name_ctx };
    v.started = true;
    return v;
}

// The whole page: the mockup's card, drawn in the main area because the engine's modal has no room for a table.
pub fn managerPage(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = env_vm.manager_id },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.surface,
        .border = .all(1, scope.theme.colors.divider),
        .pad = props.Pad.all(14),
        .gap = .{ .px = 10 },
    }, scope, managerChildren);
}

fn managerChildren(scope: *Scope) void {
    managerHeader(scope);
    managerBody(scope);
    managerFooter(scope);
}

fn managerHeader(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.header" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
    }, scope, managerHeaderChildren);
}

fn managerHeaderChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "Manage environments", .size = t.type_scale.title, .color = t.colors.text } });
    spacer(.{ .text = "kurir.env.manager.header.spacer" });
    smallButton(scope, env_vm.close_id, "Close", 64, actions.onEnvClose);
}

fn managerBody(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.body" },
        .direction = .row,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 14 },
    }, scope, managerBodyChildren);
}

fn managerBodyChildren(scope: *Scope) void {
    environmentList(scope);
    variablePane(scope);
}

// The left list: the environments, the button that adds one, then the workspace's collections.
fn environmentList(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.list" },
        .direction = .column,
        .w = .{ .fixed = 200 },
        .h = .grow,
        .gap = .{ .px = 3 },
    }, scope, environmentListChildren);
}

fn environmentListChildren(scope: *Scope) void {
    const t = scope.theme;
    sectionLabel(scope, "ENVIRONMENTS");
    for (scope.state.env_names, 0..) |name, index| {
        if (index >= state_mod.max_environments) break;
        const chosen = scope.state.env_group == .environment and scope.state.env_selected == index;
        const active = std.mem.eql(u8, name, scope.state.env_active);
        listRow(scope, &scope.vm.env.env_ctxs[index], frame.elementId(env_vm.env_row_prefix, index), name, chosen, active);
    }
    if (scope.state.env_names.len == 0) {
        label(.{ .label = .{ .text = "No environments yet.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    }
    smallButton(scope, env_vm.new_id, "+ New environment", 150, actions.onEnvNew);

    // A little air, then the collections: they follow the environments instead of being pushed to the floor.
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.gap" },
        .w = .grow,
        .h = .{ .fixed = 12 },
    }, scope, nothing);
    sectionLabel(scope, "COLLECTIONS");
    for (scope.state.collection_names, 0..) |name, index| {
        const chosen = scope.state.env_group == .collection and scope.state.collection_selected == index;
        listRow(scope, &scope.vm.env.collection_ctxs[index], frame.elementId(env_vm.collection_row_prefix, index), name, chosen, false);
    }
    if (scope.state.collection_names.len == 0) {
        label(.{ .label = .{ .text = "No collections here.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    }
}

fn sectionLabel(scope: *Scope, text: []const u8) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = text, .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn nothing(_: *Scope) void {}

// One name in the left list: the row being edited is filled, and the environment that sends says so.
fn listRow(scope: *Scope, ctx: *env_vm.Env.ListCtx, id: []const u8, name: []const u8, chosen: bool, active: bool) void {
    const t = scope.theme;
    const text = if (active) frame.formatText("{s}   active", .{name}) else name;
    button(.{
        .id = .{ .text = id },
        .label = .{ .text = text, .size = t.type_scale.caption, .color = if (chosen) t.colors.text else t.colors.text_dim },
        .bg = if (chosen) t.colors.surface_variant else t.colors.surface,
        .hover_bg = t.colors.hover,
        .w = .grow,
        .pad = props.Pad.axes(5, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onEnvSelect, .ctx = ctx },
    });
}

// The right pane: the selected group's title, its note, and the table of variables under it.
fn variablePane(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.pane" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 8 },
    }, scope, variablePaneChildren);
}

fn variablePaneChildren(scope: *Scope) void {
    const t = scope.theme;
    const environment_group = scope.state.env_group == .environment;
    if (environment_group) {
        box(.{
            .src = @src(),
            .id = .{ .text = "kurir.env.manager.title" },
            .direction = .row,
            .w = .grow,
            .gap = .{ .px = 8 },
            .child_align = .{ .y = .center },
        }, scope, paneTitleRow);
    } else {
        label(.{ .label = .{ .text = groupTitle(scope), .size = t.type_scale.body, .color = t.colors.text } });
    }
    label(.{ .label = .{
        .text = if (environment_group)
            "Sent with every request while this environment is active: the current value wins, the initial one is the fallback."
        else
            "These belong to the collection, so they are saved with the document (Ctrl/Cmd+S).",
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    }, .wrap = true });

    if (environment_group) environmentHeader(scope) else collectionHeader(scope);
    if (environment_group) environmentRows(scope) else collectionRows(scope);
}

// The pane's title is the environment's own name, so a rename is typing; Delete removes the environment itself.
fn paneTitleRow(scope: *Scope) void {
    const t = scope.theme;
    const field = &views(scope).name;
    field.value = groupTitle(scope);
    field.h = .{ .fixed = 30 };
    field.w = .{ .fixed = 260 };
    field.pad = props.Pad.axes(4, 9);
    textField(field);
    spacer(.{ .text = "kurir.env.manager.title.spacer" });
    label(.{ .label = .{ .text = "Rename it here.", .size = t.type_scale.caption, .color = t.colors.text_done } });
    smallButton(scope, env_vm.delete_id, "Delete", 64, actions.onEnvRemove);
}

fn groupTitle(scope: *Scope) []const u8 {
    if (scope.state.env_group == .collection) {
        if (scope.state.collection_selected < scope.state.collection_names.len) {
            return scope.state.collection_names[scope.state.collection_selected];
        }
        return "No collection selected";
    }
    if (scope.state.env_selected < scope.state.env_names.len) return scope.state.env_names[scope.state.env_selected];
    return "No environment yet";
}

fn environmentHeader(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.columns" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
    }, scope, environmentHeaderChildren);
}

fn environmentHeaderChildren(scope: *Scope) void {
    columnLabel(scope, "Variable", nameWidth());
    columnLabel(scope, "Initial value", valueWidth());
    columnLabel(scope, "Current value", valueWidth());
    columnLabel(scope, "Secret", .{ .fixed = 50 });
}

// The three value columns share what the pane has left, so a narrow window still fits all of them.
fn nameWidth() props.Size {
    return .{ .clamp = .{ .min = 110, .max = 200, .grow = true } };
}

fn valueWidth() props.Size {
    return .{ .clamp = .{ .min = 110, .max = 220, .grow = true } };
}

fn columnLabel(scope: *Scope, text: []const u8, size: props.Size) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        // The label names its own box: two columns may be the same width, but no two say the same thing.
        .id = .{ .text = frame.elementId(text, 0) },
        .w = size,
        .direction = .row,
    }, &CellLabel{ .text = text, .theme = t }, cellLabel);
}

const CellLabel = struct {
    text: []const u8,
    theme: glinlandui.theme.Theme,
};

fn cellLabel(cell: *const CellLabel) void {
    label(.{ .label = .{ .text = cell.text, .size = cell.theme.type_scale.caption, .color = cell.theme.colors.text_done } });
}

fn collectionHeader(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.env.manager.columns" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
    }, scope, collectionHeaderChildren);
}

fn collectionHeaderChildren(scope: *Scope) void {
    columnLabel(scope, "Variable", nameWidth());
    columnLabel(scope, "Value", valueWidth());
}

fn environmentRows(scope: *Scope) void {
    const t = scope.theme;
    scroll(.{
        .id = .{ .text = "kurir.env.manager.rows" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, environmentRowList);
}

fn environmentRowList(scope: *Scope) void {
    const t = scope.theme;
    const count = @min(scope.state.env_count, state_mod.max_env_vars);
    if (count == 0) {
        label(.{ .label = .{ .text = "No variables in this environment yet.", .size = t.type_scale.caption, .color = t.colors.text_done } });
    }
    var i: usize = 0;
    while (i < count) : (i += 1) environmentRow(scope, i);
    // The button sits where the next row would: right under the last one, inside the same scroll.
    smallButton(scope, env_vm.add_variable_id, "+ Add variable", 120, actions.onEnvAddVariable);
}

const RowScope = struct {
    scope: *Scope,
    index: usize,
};

fn environmentRow(scope: *Scope, index: usize) void {
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.env.manager.row", index) },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &RowScope{ .scope = scope, .index = index }, environmentRowChildren);
}

fn environmentRowChildren(rs: *const RowScope) void {
    const scope = rs.scope;
    const t = scope.theme;
    const index = rs.index;
    if (index >= scope.state.env_rows.len) return;
    const row = scope.state.env_rows[index];
    const env = &scope.vm.env;
    // A secret is never drawn: the columns show dots, whatever the value is.
    const dots = "••••••••";

    const v = views(scope);
    const name_field = &v.names[index];
    name_field.value = row.name;
    name_field.h = .{ .fixed = 26 };
    name_field.w = nameWidth();
    textField(name_field);

    const initial_field = &v.initial[index];
    initial_field.value = if (row.secret) dots else row.initial;
    initial_field.h = .{ .fixed = 26 };
    initial_field.w = valueWidth();
    textField(initial_field);

    const current_field = &v.current[index];
    current_field.value = if (row.secret) dots else row.current;
    current_field.h = .{ .fixed = 26 };
    current_field.w = valueWidth();
    textField(current_field);

    button(.{
        .id = .{ .text = frame.elementId("kurir.env.manager.secret", index) },
        .label = .{ .text = if (row.secret) "on" else "off", .size = t.type_scale.caption, .color = if (row.secret) theme_on(t) else t.colors.text_dim },
        .bg = t.colors.surface_variant,
        .hover_bg = t.colors.hover,
        .w = .{ .fixed = 50 },
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onEnvToggleSecret, .ctx = &env.var_ctxs[index * 3] },
    });

    button(.{
        .id = .{ .text = frame.elementId("kurir.env.manager.del", index) },
        .label = .{ .text = "x", .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onEnvRemoveVariable, .ctx = &env.var_ctxs[index * 3] },
    });
}

fn theme_on(t: glinlandui.theme.Theme) glinlandui.Color {
    return t.colors.primary;
}

fn collectionRows(scope: *Scope) void {
    const t = scope.theme;
    scroll(.{
        .id = .{ .text = "kurir.env.manager.pairs" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, collectionRowList);
}

fn collectionRowList(scope: *Scope) void {
    const t = scope.theme;
    const count = @min(scope.state.pair_count, state_mod.max_vars);
    if (count == 0) {
        label(.{ .label = .{ .text = "No variables in this collection yet.", .size = t.type_scale.caption, .color = t.colors.text_done } });
    }
    var i: usize = 0;
    while (i < count) : (i += 1) collectionRow(scope, i);
    smallButton(scope, env_vm.add_variable_id, "+ Add variable", 120, actions.onEnvAddVariable);
}

fn collectionRow(scope: *Scope, index: usize) void {
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.env.manager.pair", index) },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &RowScope{ .scope = scope, .index = index }, collectionRowChildren);
}

fn collectionRowChildren(rs: *const RowScope) void {
    const scope = rs.scope;
    const t = scope.theme;
    const index = rs.index;
    if (index >= scope.state.pair_rows.len) return;
    const row = scope.state.pair_rows[index];
    const env = &scope.vm.env;

    const name_field = &views(scope).names[index];
    name_field.value = row.name;
    name_field.h = .{ .fixed = 26 };
    name_field.w = nameWidth();
    textField(name_field);

    const value_field = &views(scope).initial[index];
    value_field.value = row.value;
    value_field.h = .{ .fixed = 26 };
    value_field.w = valueWidth();
    textField(value_field);

    button(.{
        .id = .{ .text = frame.elementId("kurir.env.manager.pair.del", index) },
        .label = .{ .text = "x", .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onEnvRemoveVariable, .ctx = &env.var_ctxs[index * 3] },
    });
}

fn managerFooter(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{
        .text = "Use them in a request as {{name}}. A request's own Vars tab is read first, then this environment, then the collection.",
        .size = t.type_scale.caption,
        .color = t.colors.text_done,
    }, .wrap = true });
}
