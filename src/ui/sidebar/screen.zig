//! The left panel's screen: the workspace header, the filter and "+ New" row, and the hand-rolled tree.
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const button_mod = glinlandui.components.button;
const dropdown_mod = glinlandui.components.dropdown;
const input_mod = glinlandui.components.input;
const scroll_mod = glinlandui.components.scroll;
const sidebar_mod = glinlandui.components.sidebar;
const text_mod = glinlandui.components.text;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const sidebar_vm = @import("view_model.zig");
const actions = @import("../shell/actions.zig");

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
        .bg = scope.theme.colors.surface,
    }, scope, sidebarContent);
}

pub fn sidebarContent(scope: *Scope) void {
    workspaceHeader(scope);
    searchRow(scope);
    sectionLabel(scope);
    tree(scope);
    menus(scope);
}

// ---- the workspace header: a badge, the name, the counter, and the two menu buttons ------------------

pub fn workspaceHeader(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.sides(10, 10, 10, 10),
    }, scope, workspaceHeaderChildren);
}

pub fn workspaceHeaderChildren(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws.head" },
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = 32 },
        .gap = .{ .px = 8 },
        .child_align = .{ .y = .center },
    }, scope, workspaceHead);
}

pub fn workspaceHead(scope: *Scope) void {
    const t = scope.theme;

    // The badge is the workspace's mark, so it takes the accent and carries the initial.
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws.badge" },
        .direction = .row,
        .w = .{ .fixed = 26 },
        .h = .{ .fixed = 26 },
        .bg = theme_mod.accent,
        .radius = props.Radius.all(7),
        .child_align = .{ .x = .center, .y = .center },
    }, scope, badgeChildren);

    const field = &scope.vm.sidebar.workspace_field;
    field.value = scope.state.workspace_name;
    field.w = .grow;
    field.h = .{ .fixed = 26 };
    field.bg = t.colors.surface;
    field.fg = t.colors.text;
    field.border = .{};
    field.pad = props.Pad.axes(0, 2);
    field.font_size = t.type_scale.body;
    input_mod.textField(field);

    text_mod.label(.{ .label = .{
        .text = frame.formatText("{d} / {d}", .{ scope.state.workspace_index + 1, scope.state.workspace_count }),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });

    iconButton(scope, "kurir.ws.next", "v", 20, actions.onNextWorkspace);
    iconButton(scope, sidebar_vm.ws_trigger_id, "...", 26, actions.onWsToggle);
}

pub fn badgeChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "K", .size = t.type_scale.caption, .color = t.colors.on_primary } });
}

// ---- the filter and the "+ New" menu button ----------------------------------------------------------

pub fn searchRow(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 8 },
        .pad = props.Pad.sides(0, 10, 8, 10),
        .child_align = .{ .y = .center },
    }, scope, searchRowChildren);
}

pub fn searchRowChildren(scope: *Scope) void {
    const t = scope.theme;

    const field = &scope.vm.sidebar.filter_field;
    field.value = scope.state.filter;
    field.w = .grow;
    input_mod.textField(field);

    // A menu button: one button whose card lists what can be created, so the row stays one line.
    button_mod.button(.{
        .src = @src(),
        .id = .{ .text = sidebar_vm.new_trigger_id },
        .label = .{ .text = "+ New  v", .size = t.type_scale.caption, .color = t.colors.on_primary },
        .bg = theme_mod.accent,
        .hover_bg = t.colors.primary_hover,
        .w = .{ .fixed = 84 },
        .h = .{ .fixed = 28 },
        .pad = props.Pad.axes(0, 8),
        .radius = props.Radius.all(6),
        .on_click = .{ .f = actions.onNewToggle, .ctx = scope.vm },
    });
}

pub fn noChildren(scope: *Scope) void {
    _ = scope;
}

fn iconNoChildren(ic: *const IconCtx) void {
    _ = ic;
}

pub fn sectionLabel(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tree.section" },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.sides(4, 12, 8, 12),
    }, &t, sectionLabelText);
}

pub fn sectionLabelText(t: *const glinlandui.theme.Theme) void {
    text_mod.label(.{ .label = .{ .text = "COLLECTIONS", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

// ---- the tree ---------------------------------------------------------------------------------------

pub fn tree(scope: *Scope) void {
    if (scope.state.rows.len == 0) {
        emptyTree(scope);
        return;
    }
    scroll_mod.scroll(.{
        .id = .{ .text = "kurir.tree" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.surface,
        .thumb_bg = scope.theme.colors.surface_variant,
        .thumb_hover_bg = theme_mod.accent,
    }, scope, treeChildren);
}

// An empty tree says what to do, and the whole block is the button that does it.
pub fn emptyTree(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tree.empty" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.all(16),
        .gap = .{ .px = 6 },
        .hover_bg = scope.theme.colors.hover,
        .on_click = .{ .f = actions.onAddCollection, .ctx = scope.vm },
    }, scope, emptyTreeChildren);
}

pub fn emptyTreeChildren(scope: *Scope) void {
    const t = scope.theme;
    // A filter that matches nothing is a different empty state from a workspace with no collections.
    text_mod.label(.{ .label = .{
        .text = if (scope.state.filter_active) "Nothing matches that filter." else "No collections yet.",
        .size = t.type_scale.body,
        .color = t.colors.text_dim,
    } });
    text_mod.label(.{ .label = .{
        .text = if (scope.state.filter_active) "Clear the filter to see the whole tree." else "Press + New to make one.",
        .size = t.type_scale.caption,
        .color = t.colors.text_done,
    }, .wrap = true });
}

pub fn treeChildren(scope: *Scope) void {
    var i: usize = 0;
    while (i < scope.state.rows.len and i < state_mod.max_tree_rows) : (i += 1) row(scope, i);
}

// One row is one click target: a bar, a caret, an icon or a method chip, the name, and what else it knows.
pub fn row(scope: *Scope, index: usize) void {
    const r = scope.state.rows[index];
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.row", index) },
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(row_h) },
        .bg = if (r.selected) Color.lerp(scope.theme.colors.surface, theme_mod.accent, 0.12) else null,
        .hover_bg = scope.theme.colors.hover,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(0, 8, 0, @floatFromInt(4 + r.depth * indent)),
        .child_align = .{ .y = .center },
        .on_click = .{ .f = actions.onRowCtx, .ctx = &scope.vm.sidebar.row_ctxs[index] },
    }, &RowCtx{ .scope = scope, .index = index }, rowChildren);
}

const Color = glinlandui.Color;

const RowCtx = struct {
    scope: *Scope,
    index: usize,
};

pub fn rowChildren(rc: *const RowCtx) void {
    const scope = rc.scope;
    const t = scope.theme;
    const r = scope.state.rows[rc.index];

    // The selection mark: a full-height accent bar, drawn even when nothing is selected so text never shifts.
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.bar", rc.index) },
        .direction = .row,
        .w = .{ .fixed = 2 },
        .h = .grow,
        .bg = if (r.selected) theme_mod.accent else null,
    }, scope, noChildren);

    if (r.kind == .request) {
        // A request has no caret, so its chip sits exactly where a container's icon does.
        methodChip(scope, rc.index, r.method);
        text_mod.label(.{ .label = .{ .text = r.label, .size = t.type_scale.body, .color = t.colors.text } });
    } else {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.tree.caret", rc.index) },
            .direction = .row,
            .w = .{ .fixed = 10 },
            .h = .grow,
            .child_align = .{ .x = .center, .y = .center },
        }, &CaretCtx{ .theme = t, .row = r }, caretChildren);
        folderIcon(scope, rc.index);
        text_mod.label(.{ .label = .{ .text = r.label, .size = t.type_scale.body, .color = t.colors.text } });
        box_mod.spacer(.{ .text = frame.elementId("kurir.tree.gap", rc.index) });
        if (r.count > 0) {
            text_mod.label(.{ .label = .{
                .text = frame.formatText("{d}", .{r.count}),
                .size = t.type_scale.caption,
                .color = t.colors.text_done,
            } });
        }
    }
}

const CaretCtx = struct {
    theme: glinlandui.theme.Theme,
    row: state_mod.TreeRow,
};

pub fn caretChildren(cc: *const CaretCtx) void {
    if (!cc.row.has_children) return;
    text_mod.label(.{ .label = .{
        .text = if (cc.row.expanded) "v" else ">",
        .size = cc.theme.type_scale.caption,
        .color = cc.theme.colors.text_dim,
    } });
}

// A container's icon, drawn rather than typed: the font has no folder glyph, and a box would read as one missing.
pub fn folderIcon(scope: *Scope, index: usize) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.icon", index) },
        .direction = .column,
        .w = .{ .fixed = 12 },
        .h = .{ .fixed = 10 },
        .gap = .{ .px = 0 },
    }, &IconCtx{ .theme = scope.theme, .index = index }, folderChildren);
}

const IconCtx = struct {
    theme: glinlandui.theme.Theme,
    index: usize,
};

pub fn folderChildren(ic: *const IconCtx) void {
    const t = ic.theme;
    // The tab first, then the body: a two-part silhouette reads as a folder, where a ring or a glyph cannot.
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.icon.tab", ic.index) },
        .direction = .row,
        .w = .{ .fixed = 5 },
        .h = .{ .fixed = 2 },
        .bg = t.colors.text_done,
        .radius = props.Radius.all(1),
    }, ic, iconNoChildren);
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.icon.body", ic.index) },
        .direction = .row,
        .w = .{ .fixed = 12 },
        .h = .{ .fixed = 8 },
        .bg = Color.withAlpha(t.colors.text_dim, 46),
        .border = .all(1, t.colors.text_done),
        .radius = props.Radius.all(2),
    }, ic, iconNoChildren);
}

// A verb's chip: a tint of its own tone, so the column of requests can be read at a glance.
pub fn methodChip(scope: *Scope, index: usize, method: []const u8) void {
    _ = scope;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.chip", index) },
        .direction = .row,
        .w = .{ .fixed = 46 },
        .h = .{ .fixed = 18 },
        .bg = theme_mod.chipBg(method),
        .radius = props.Radius.all(4),
        .child_align = .{ .x = .center, .y = .center },
    }, &ChipCtx{ .method = method }, chipChildren);
}

const ChipCtx = struct {
    method: []const u8,
};

pub fn chipChildren(cc: *const ChipCtx) void {
    text_mod.label(.{ .label = .{ .text = cc.method, .size = .{ .px = 10 }, .color = theme_mod.methodColor(cc.method) } });
}

// ---- the two menus ----------------------------------------------------------------------------------

fn menus(scope: *Scope) void {
    if (scope.state.new_menu_open) {
        dropdown_mod.dropdown(.{
            .src = @src(),
            .field_id = "kurir.new.picker",
            .list_id = sidebar_vm.new_list_id,
            .row_h = .{ .px = 28 },
            .row_bg = scope.theme.colors.surface,
            .row_fg = scope.theme.colors.text,
            .hover_bg = scope.theme.colors.hover,
            .border_width = .{ .px = 0 },
            .radius = .{ .px = 0 },
            .gap = .{ .px = 0 },
            .font_size = scope.theme.type_scale.caption,
            .on_select = .{ .f = actions.onNewPick, .ctx = scope.vm },
            .overlay = true,
            .anchor_text = sidebar_vm.new_trigger_id,
            .overlay_id = sidebar_vm.new_menu_id,
            .overlay_bg = scope.theme.colors.surface_variant,
            .overlay_pad = .{ .px = 4 },
            .overlay_border_width = .{ .px = 1 },
            .overlay_border_color = scope.theme.colors.divider,
            .z_index = 20,
        }, sidebar_vm.new_rows[0..], scope.theme, plainRow);
    }
    if (scope.state.ws_menu_open) {
        dropdown_mod.dropdown(.{
            .src = @src(),
            .field_id = "kurir.ws.picker",
            .list_id = sidebar_vm.ws_list_id,
            .row_h = .{ .px = 28 },
            .row_bg = scope.theme.colors.surface,
            .row_fg = scope.theme.colors.text,
            .hover_bg = scope.theme.colors.hover,
            .border_width = .{ .px = 0 },
            .radius = .{ .px = 0 },
            .gap = .{ .px = 0 },
            .font_size = scope.theme.type_scale.caption,
            .on_select = .{ .f = actions.onWsPick, .ctx = scope.vm },
            .overlay = true,
            // Anchored to the header row, because a card is only as wide as what it hangs from.
            .anchor_text = "kurir.ws.head",
            .overlay_id = sidebar_vm.ws_panel_id,
            .overlay_bg = scope.theme.colors.surface_variant,
            .overlay_pad = .{ .px = 4 },
            .overlay_border_width = .{ .px = 1 },
            .overlay_border_color = scope.theme.colors.divider,
            .z_index = 20,
        }, sidebar_vm.ws_rows[0..], scope.theme, plainRow);
    }
}

fn plainRow(t: glinlandui.theme.Theme, item: []const u8, index: usize) void {
    _ = index;
    text_mod.label(.{ .label = .{ .text = item, .size = t.type_scale.caption, .color = t.colors.text } });
}

// A square button with no fill of its own: it is a mark, not a block.
fn iconButton(scope: *Scope, id: []const u8, label: []const u8, width: u32, comptime handler: *const fn (?*anyopaque) void) void {
    const t = scope.theme;
    button_mod.button(.{
        .src = @src(),
        .id = .{ .text = id },
        .label = .{ .text = label, .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .w = .{ .fixed = @floatFromInt(width) },
        .h = .{ .fixed = 26 },
        .pad = props.Pad.all(0),
        .radius = props.Radius.all(6),
        .on_click = .{ .f = handler, .ctx = scope.vm },
    });
}
