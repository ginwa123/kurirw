//! The request editor's screen: name row, method bar, URL, tabs, header table and the body field.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const dropdown_mod = glinlandui.components.dropdown;
const button_mod = glinlandui.components.button;
const input_mod = glinlandui.components.input;
const scroll_mod = glinlandui.components.scroll;
const text_mod = glinlandui.components.text;
const frame = glinlandui.frame;
const props = glinlandui.props;

const postman = @import("../../data/model/postman.zig");
const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const editor_vm = @import("view_model.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");

const smallButton = widgets.smallButton;
const tabButton = widgets.tabButton;

const Scope = scope_mod.Scope;
const body_min_h = scope_mod.body_min_h;
const max_body_lines = scope_mod.max_body_lines;

// What a menu row reads: the theme, so each verb keeps its colour inside the card too.
const MethodMenu = struct {
    theme: glinlandui.theme.Theme,
};

fn renderMethodRow(menu: MethodMenu, item: []const u8, index: usize) void {
    _ = index;
    const t = menu.theme;
    text_mod.label(.{ .label = .{ .text = item, .size = t.type_scale.caption, .color = theme_mod.methodColor(item) } });
}

pub fn requestEditor(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.editor" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.surface,
        .border = .all(1, scope.theme.colors.divider),
        .pad = props.Pad.all(12),
        .gap = .{ .px = 8 },
    }, scope, editorChildren);
}

pub fn editorChildren(scope: *Scope) void {
    nameRow(scope);
    methodRow(scope);
    editorTabs(scope);
    editorBody(scope);
}

pub fn nameRow(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.name.row" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 8 },
        .child_align = .{ .y = .center },
    }, scope, nameRowChildren);
}

pub fn nameRowChildren(scope: *Scope) void {
    const t = scope.theme;
    const field = &scope.vm.sidebar.name_field;
    field.value = scope.state.node_name;
    field.disabled = !scope.state.has_selection;
    field.w = .{ .clamp = .{ .min = 160, .max = 360, .grow = true } };
    input_mod.textField(field);

    if (!scope.state.has_selection) {
        text_mod.label(.{ .label = .{ .text = "Pick a request on the left, or create one.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    } else if (scope.state.node_kind != .request) {
        text_mod.label(.{ .label = .{ .text = "Container: add a request inside it.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    }

    box_mod.spacer(.{ .text = "kurir.name.spacer" });

    button_mod.button(.{
        .id = .{ .text = "kurir.delete" },
        .label = .{ .text = "Delete", .size = t.type_scale.caption, .color = t.colors.text },
        .bg = t.colors.surface_variant,
        .hover_bg = t.colors.hover,
        .disabled = !scope.state.can_delete,
        .pad = props.Pad.axes(4, 10),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onDelete, .ctx = scope.vm },
    });
}

// What the URL field may take: a text field is never narrower than its own value, so an uncapped one widens the row and pushes Send past the window's edge.
fn urlWidth(scope: *Scope) props.Size {
    const send_w: f32 = if (frame.bounds((props.Id{ .text = "kurir.send" }).clay())) |b| b.width else 70;
    const curl_w: f32 = if (frame.bounds((props.Id{ .text = editor_vm.curl_copy_id }).clay())) |b| b.width else 0;
    // Everything the row spends before the field: the method button, its 4 pt gaps, the panel's grip and the editor's own padding.
    const fixed: f32 = 96 + send_w + curl_w + (if (curl_w > 0) @as(f32, 12) else 8) + 7 + 24;
    const avail = scope.vm.viewport_w - scope.state.sidebar_width - fixed;
    if (avail < 160) return .grow;
    return .{ .clamp = .{ .min = 160, .max = avail, .grow = true } };
}

pub fn methodRow(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.method.row" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 4 },
        .child_align = .{ .y = .center },
    }, scope, methodRowChildren);
}

pub fn methodRowChildren(scope: *Scope) void {
    const t = scope.theme;
    const enabled = scope.state.node_kind == .request;
    const method = scope.state.method;
    const color = theme_mod.methodColor(method);

    // The trigger is the anchor: the card attaches to this element by name, and nothing shifts when it opens.
    button_mod.button(.{
        .id = .{ .text = editor_vm.method_trigger_id },
        .label = .{ .text = frame.formatText("{s}  v", .{method}), .size = t.type_scale.caption, .color = if (enabled) t.colors.on_primary else t.colors.text_dim },
        .bg = if (enabled) color else t.colors.background,
        .hover_bg = t.colors.surface_variant,
        .disabled = !enabled,
        .w = .{ .fixed = 96 },
        .pad = props.Pad.axes(4, 6),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onMethodToggle, .ctx = scope.vm },
    });

    if (scope.state.method_open) {
        dropdown_mod.dropdown(.{
            .src = @src(),
            // No element carries this id: it is the menu's name in the semantics tree only.
            .field_id = "kurir.method.picker",
            .list_id = editor_vm.method_list_id,
            .field = null,
            .row_h = .{ .px = 30 },
            .row_bg = t.colors.surface,
            .row_fg = t.colors.text,
            .hover_bg = t.colors.hover,
            .border_width = .{ .px = 0 },
            .radius = .{ .px = 0 },
            .gap = .{ .px = 0 },
            .font_size = t.type_scale.caption,
            .on_select = .{ .f = actions.onMethodPick, .ctx = scope.vm },
            .overlay = true,
            .anchor_text = editor_vm.method_trigger_id,
            .overlay_id = editor_vm.method_menu_id,
            .overlay_bg = t.colors.surface,
            .overlay_pad = .{ .px = 4 },
            .overlay_border_width = .{ .px = 1 },
            .overlay_border_color = t.colors.divider,
            .z_index = 20,
        }, postman.methods[0..], MethodMenu{ .theme = t }, renderMethodRow);
    }

    const field = &scope.vm.editor.url_field;
    field.value = scope.state.url;
    field.disabled = !enabled;
    field.w = urlWidth(scope);
    input_mod.textField(field);

    button_mod.button(.{
        .id = .{ .text = "kurir.send" },
        .label = .{ .text = if (scope.state.sending) "Sending..." else "Send", .size = t.type_scale.label, .color = t.colors.on_primary },
        .bg = theme_mod.success,
        .hover_bg = t.colors.primary_hover,
        .disabled = !enabled or scope.state.sending,
        .pad = props.Pad.axes(8, 18),
        .radius = props.Radius.all(6),
        .on_click = .{ .f = actions.onSend, .ctx = scope.vm },
    });

    // The other half of "paste a curl command": this one writes the request back out as one.
    if (enabled) smallButton(scope, editor_vm.curl_copy_id, "cURL", 64, actions.onCopyCurl);
}

pub fn editorTabs(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.editor.tabs" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .child_align = .{ .y = .center },
    }, scope, editorTabsChildren);
}

pub fn editorTabsChildren(scope: *Scope) void {
    const t = scope.theme;
    tabButton(scope, "kurir.tab.headers", "Headers", scope.state.editor_tab == .headers, actions.onHeadersTab);
    tabButton(scope, "kurir.tab.body", "Body", scope.state.editor_tab == .body, actions.onBodyTab);
    box_mod.spacer(.{ .text = "kurir.tabs.spacer" });
    if (scope.state.node_kind == .request and scope.state.editor_tab == .headers) {
        smallButton(scope, "kurir.header.add", "+ Header", 84, actions.onAddHeader);
    }
    text_mod.label(.{ .label = .{ .text = "Ctrl/Cmd+Enter sends", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn editorBody(scope: *Scope) void {
    if (scope.state.node_kind != .request) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.editor.empty" },
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .direction = .column,
            .gap = .{ .px = 6 },
        }, scope, editorEmpty);
        return;
    }
    if (scope.state.editor_tab == .headers) {
        headersTable(scope);
    } else {
        bodyEditor(scope);
    }
}

pub fn editorEmpty(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "A method, a URL, headers and a JSON body live here once a request is selected.", .size = t.type_scale.body, .color = t.colors.text_dim }, .wrap = true });
}

pub fn headersTable(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.header_count == 0) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.headers.empty" },
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .direction = .column,
            .gap = .{ .px = 6 },
        }, scope, headersEmpty);
        return;
    }
    scroll_mod.scroll(.{
        .id = .{ .text = "kurir.headers" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, headerRows);
}

pub fn headersEmpty(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "No headers on this request.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = "Press + Header to add one, for example Content-Type: application/json.", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn headerRows(scope: *Scope) void {
    const count = @min(scope.state.header_count, state_mod.max_headers);
    var i: usize = 0;
    while (i < count) : (i += 1) headerRow(scope, i);
}

const HeaderScope = struct {
    scope: *Scope,
    index: usize,
};

pub fn headerRow(scope: *Scope, index: usize) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.header.row", index) },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &HeaderScope{ .scope = scope, .index = index }, headerRowChildren);
}

pub fn headerRowChildren(hs: *const HeaderScope) void {
    const scope = hs.scope;
    const t = scope.theme;
    const index = hs.index;
    if (index >= scope.state.headers.len) return;
    const row = scope.state.headers[index];
    const enabled = !scope.vm.headerFieldsDisabled(index);

    button_mod.button(.{
        .id = .{ .text = frame.elementId("kurir.header.on", index) },
        .label = .{ .text = if (enabled) "on" else "off", .size = t.type_scale.caption, .color = if (enabled) t.colors.on_primary else t.colors.text_dim },
        .bg = if (enabled) theme_mod.success else t.colors.surface_variant,
        .hover_bg = t.colors.primary_hover,
        .w = .{ .fixed = 34 },
        .pad = props.Pad.axes(3, 4),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onToggleHeader, .ctx = &scope.vm.editor.header_ctxs[index * 2] },
    });

    const key_field = &scope.vm.editor.header_fields[index * 2];
    key_field.value = row.name;
    key_field.h = .{ .fixed = 26 };
    key_field.w = .{ .clamp = .{ .min = 90, .max = 220, .grow = true } };
    input_mod.textField(key_field);

    const value_field = &scope.vm.editor.header_fields[index * 2 + 1];
    value_field.value = row.value;
    value_field.h = .{ .fixed = 26 };
    value_field.w = .grow;
    input_mod.textField(value_field);

    button_mod.button(.{
        .id = .{ .text = frame.elementId("kurir.header.del", index) },
        .label = .{ .text = "x", .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onRemoveHeader, .ctx = &scope.vm.editor.header_ctxs[index * 2] },
    });
}

pub fn bodyEditor(scope: *Scope) void {
    const t = scope.theme;
    scroll_mod.scroll(.{
        .id = .{ .text = editor_vm.body_scroll_id },
        .direction = .both,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .border_width = .{ .px = 1 },
        .border_color = t.colors.divider,
        .radius = .{ .px = 6 },
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, bodyField);
}

// The body is the toolkit's multiline field: it draws its own lines, its own caret, and takes its own clicks.
pub fn bodyField(scope: *Scope) void {
    const field = &scope.vm.editor.body_field;
    const lines: f32 = @floatFromInt(@max(field.editor.lineCount(), 1));
    field.value = scope.state.body;
    field.w = .grow;
    // Tall enough for the text, and never shorter than the pane, so a long body scrolls instead of clipping.
    field.h = .{ .fixed = @max(body_min_h, lines * field.lineHeight() + 12) };
    input_mod.textField(field);
}
