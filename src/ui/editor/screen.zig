//! The request editor's screen: name row, method bar, URL, tabs, header table and the body field.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const dropdown = glinlandui.components.dropdown.dropdown;
const button = glinlandui.components.button.button;
const textField = glinlandui.components.input.textField;
const scroll = glinlandui.components.scroll.scroll;
const label = glinlandui.components.text.label;
const frame = glinlandui.frame;
const props = glinlandui.props;

const postman = @import("../../data/model/postman.zig");
const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const views_mod = @import("../shell/views.zig");
const shell_vm = @import("../shell/view_model.zig");
const editor_vm = @import("view_model.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");

const smallButton = widgets.smallButton;
const tabButton = widgets.tabButton;

const Scope = scope_mod.Scope;
const body_min_h = scope_mod.body_min_h;
const max_body_lines = scope_mod.max_body_lines;

// The request's name box renames the node the sidebar has selected, so its intent is the sidebar's.
fn onNameTyped(raw: ?*anyopaque, text: []const u8) void {
    const vm: *shell_vm.KurirViewModel = @ptrCast(@alignCast(raw.?));
    vm.sidebar.typedName(text);
}

fn onNameFocused(raw: ?*anyopaque) void {
    const vm: *shell_vm.KurirViewModel = @ptrCast(@alignCast(raw.?));
    vm.sidebar.focusName();
}

// Ctrl/Cmd+Enter: the field asks whether the intent took the draft. It did not, so the body stays where it is.
fn onBodySubmit(raw: ?*anyopaque, text: []const u8) bool {
    const vm: *shell_vm.KurirViewModel = @ptrCast(@alignCast(raw.?));
    _ = text;
    vm.send();
    return false;
}

// The panel's widgets: styled and bound on the first frame that declares them, and only handed values after that.
fn views(scope: *Scope) *views_mod.Views.Editor {
    const v = &scope.views.editor;
    if (v.started) return v;
    const session = &scope.vm.session;
    const vm = scope.vm;
    v.name = session.fieldStyle(.{ .text = shell_vm.name_field_id }, @src());
    v.name.bind();
    v.name.on_change = .{ .f = onNameTyped, .ctx = vm };
    v.name.on_focus = .{ .f = onNameFocused, .ctx = vm };
    v.url = session.fieldStyle(.{ .text = editor_vm.url_field_id }, @src());
    v.url.bind();
    v.url.on_change = .{ .f = editor_vm.Editor.onUrlTyped, .ctx = &vm.editor };
    v.url.on_focus = .{ .f = editor_vm.Editor.onUrlFocused, .ctx = &vm.editor };
    // The body is one multiline field; the toolkit draws its own lines and caret, and grows the text as it is typed.
    v.body = session.fieldStyle(.{ .text = editor_vm.body_id }, @src());
    v.body.multiline = true;
    // The body scrolls with its caret: typing past the bottom edge follows the line, it does not hide it.
    v.body.scroll_id = editor_vm.body_scroll_id;
    v.body.pad = props.Pad.all(editor_vm.body_pad);
    v.body.bind();
    v.body.on_change = .{ .f = editor_vm.Editor.onBodyTyped, .ctx = &vm.editor };
    v.body.on_focus = .{ .f = editor_vm.Editor.onBodyFocused, .ctx = &vm.editor };
    v.body.on_submit = .{ .f = onBodySubmit, .ctx = vm };
    // The body's colouring: a CodeEditor owns the JSON runs the field paints, and nothing else about the editing.
    v.body_code = @import("../code_editor.zig").CodeEditor.init(session.gpa);
    // The scripts: one multiline field per phase, each scrolling with its caret.
    v.pre = session.fieldStyle(.{ .text = editor_vm.pre_field_id }, @src());
    v.pre.multiline = true;
    v.pre.scroll_id = editor_vm.script_scroll_id;
    v.pre.pad = props.Pad.all(editor_vm.body_pad);
    v.pre.bind();
    v.pre.on_change = .{ .f = editor_vm.Editor.onPreTyped, .ctx = &vm.editor };
    v.post = session.fieldStyle(.{ .text = editor_vm.post_field_id }, @src());
    v.post.multiline = true;
    v.post.scroll_id = editor_vm.script_scroll_id;
    v.post.pad = props.Pad.all(editor_vm.body_pad);
    v.post.bind();
    v.post.on_change = .{ .f = editor_vm.Editor.onPostTyped, .ctx = &vm.editor };

    var i: usize = 0;
    while (i < state_mod.max_headers) : (i += 1) {
        v.headers[i * 2] = session.fieldStyle(.at(editor_vm.header_key_prefix, i), @src());
        v.headers[i * 2].bind();
        v.headers[i * 2 + 1] = session.fieldStyle(.at(editor_vm.header_value_prefix, i), @src());
        v.headers[i * 2 + 1].bind();
        v.headers[i * 2].on_change = .{ .f = editor_vm.Editor.onHeaderTyped, .ctx = &vm.editor.header_ctxs[i * 2] };
        v.headers[i * 2 + 1].on_change = .{ .f = editor_vm.Editor.onHeaderTyped, .ctx = &vm.editor.header_ctxs[i * 2 + 1] };
    }
    // The part table is a header table over a different array: same fields, same two columns.
    i = 0;
    while (i < state_mod.max_body_parts) : (i += 1) {
        v.parts[i * 2] = session.fieldStyle(.at(editor_vm.part_key_prefix, i), @src());
        v.parts[i * 2].bind();
        v.parts[i * 2 + 1] = session.fieldStyle(.at(editor_vm.part_value_prefix, i), @src());
        v.parts[i * 2 + 1].bind();
        v.parts[i * 2].on_change = .{ .f = editor_vm.Editor.onPartTyped, .ctx = &vm.editor.part_ctxs[i * 2] };
        v.parts[i * 2 + 1].on_change = .{ .f = editor_vm.Editor.onPartTyped, .ctx = &vm.editor.part_ctxs[i * 2 + 1] };
    }
    // The Vars tab is the same two-column table again, over the request's own variables.
    i = 0;
    while (i < state_mod.max_vars) : (i += 1) {
        v.vars[i * 2] = session.fieldStyle(.at(editor_vm.var_name_prefix, i), @src());
        v.vars[i * 2].bind();
        v.vars[i * 2 + 1] = session.fieldStyle(.at(editor_vm.var_value_prefix, i), @src());
        v.vars[i * 2 + 1].bind();
        v.vars[i * 2].on_change = .{ .f = editor_vm.Editor.onVarTyped, .ctx = &vm.editor.var_ctxs[i * 2] };
        v.vars[i * 2 + 1].on_change = .{ .f = editor_vm.Editor.onVarTyped, .ctx = &vm.editor.var_ctxs[i * 2 + 1] };
    }
    v.started = true;
    return v;
}

// The Scripts tab's code field never shrinks below this, so an empty script still reads as an editor.
const script_min_h: f32 = 150;

// What a menu row reads: the theme, so each verb keeps its colour inside the card too.
const MethodMenu = struct {
    theme: glinlandui.theme.Theme,
};

fn renderMethodRow(menu: MethodMenu, item: []const u8, index: usize) void {
    _ = index;
    const t = menu.theme;
    label(.{ .label = .{ .text = item, .size = t.type_scale.caption, .color = theme_mod.methodColor(item) } });
}

pub fn requestEditor(scope: *Scope) void {
    box(.{
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
    box(.{
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
    const v = views(scope);
    const field = &v.name;
    field.value = scope.state.node_name;
    field.disabled = !scope.state.has_selection;
    field.w = .{ .clamp = .{ .min = 160, .max = 360, .grow = true } };
    // A name box that GAINS the keyboard selects the whole name, so the first keystroke replaces it.
    const focused = frame.isFocused(shell_vm.name_field_id);
    if (focused and !v.name_focused) field.editor.selectAll();
    v.name_focused = focused;
    textField(field);

    if (!scope.state.has_selection) {
        label(.{ .label = .{ .text = "Pick a request on the left, or create one.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    } else if (scope.state.node_kind != .request) {
        label(.{ .label = .{ .text = "Container: add a request inside it.", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    }

    spacer(.{ .text = "kurir.name.spacer" });

    // The environment this window sends with. The mockup puts it at the right of the request's own row.
    label(.{ .label = .{ .text = "Environment", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    button(.{
        .id = .{ .text = editor_vm.env_trigger_id },
        .label = .{ .text = environmentLabel(scope.state.env_active), .size = t.type_scale.caption, .color = t.colors.text },
        .bg = t.colors.surface_variant,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(4, 10),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onEnvToggle, .ctx = scope.vm },
    });
    if (scope.state.env_menu) environmentMenu(scope);

    button(.{
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

pub fn methodRow(scope: *Scope) void {
    box(.{
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
    button(.{
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
        dropdown(.{
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

    const field = &views(scope).url;
    field.value = scope.state.url;
    field.disabled = !enabled;
    // The weight: the room the row has left after the method button, Send and cURL; 160 pt is the floor.
    field.w = .{ .clamp = .{ .min = 160, .grow = true } };
    textField(field);

    button(.{
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
    box(.{
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
    tabButton(scope, "kurir.tab.vars", "Vars (this request only)", scope.state.editor_tab == .vars, actions.onVarsTab);
    tabButton(scope, "kurir.tab.scripts", "Scripts", scope.state.editor_tab == .scripts, actions.onScriptsTab);
    spacer(.{ .text = "kurir.tabs.spacer" });
    if (scope.state.node_kind == .request and scope.state.editor_tab == .headers) {
        smallButton(scope, "kurir.header.add", "+ Header", 84, actions.onAddHeader);
    } else if (scope.state.node_kind == .request and scope.state.editor_tab == .body and scope.state.body_mode.isTable()) {
        smallButton(scope, "kurir.body.part.add", "+ Row", 64, actions.onAddBodyPart);
    } else if (scope.state.node_kind == .request and scope.state.editor_tab == .vars) {
        smallButton(scope, "kurir.var.add", "+ Variable", 92, actions.onAddRequestVar);
    }
    label(.{ .label = .{ .text = "Ctrl/Cmd+Enter sends", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn editorBody(scope: *Scope) void {
    if (scope.state.node_kind != .request) {
        box(.{
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
    switch (scope.state.editor_tab) {
        .headers => headersTable(scope),
        .body => bodyTab(scope),
        .vars => varsTab(scope),
        .scripts => scriptsTab(scope),
    }
}

// The Body tab: the mode selector above whatever that mode edits.
pub fn bodyTab(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.body.tab" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 8 },
    }, scope, bodyTabChildren);
}

pub fn bodyTabChildren(scope: *Scope) void {
    bodyModeRow(scope);
    switch (scope.state.body_mode) {
        .none => bodyNoneHint(scope),
        .raw => bodyEditor(scope),
        .formdata, .urlencoded => bodyPartsTable(scope),
    }
}

// Postman's radio row, drawn as the tabs this panel already uses: one button per mode, plus the raw language.
pub fn bodyModeRow(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.body.modes" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 4 },
        .child_align = .{ .y = .center },
    }, scope, bodyModeRowChildren);
}

pub fn bodyModeRowChildren(scope: *Scope) void {
    for (editor_vm.Editor.modes, 0..) |mode, index| bodyModeButton(scope, mode, index);
    spacer(.{ .text = "kurir.body.modes.spacer" });
    if (scope.state.body_mode == .raw) {
        for (state_mod.raw_languages, 0..) |language, index| bodyLanguageButton(scope, language, index);
        smallButton(scope, "kurir.body.prettify", "Prettify", 76, actions.onPrettifyBody);
    }
}

fn bodyModeButton(scope: *Scope, mode: postman.BodyMode, index: usize) void {
    const t = scope.theme;
    const active = scope.state.body_mode == mode;
    button(.{
        .id = .{ .text = frame.elementId(editor_vm.mode_prefix, index) },
        .label = .{ .text = mode.label(), .size = t.type_scale.caption, .color = if (active) t.colors.text else t.colors.text_dim },
        .bg = if (active) t.colors.surface_variant else t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(4, 10),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onBodyMode, .ctx = &scope.vm.editor.mode_ctxs[index] },
    });
}

fn bodyLanguageButton(scope: *Scope, language: []const u8, index: usize) void {
    const t = scope.theme;
    const active = std.mem.eql(u8, scope.state.body_language, language);
    button(.{
        .id = .{ .text = frame.elementId(editor_vm.language_prefix, index) },
        .label = .{ .text = language, .size = t.type_scale.caption, .color = if (active) t.colors.text else t.colors.text_done },
        .bg = if (active) t.colors.surface_variant else t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 7),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onBodyLanguage, .ctx = &scope.vm.editor.language_ctxs[index] },
    });
}

fn bodyNoneHint(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.body.none" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .pad = props.Pad.all(8),
        .gap = .{ .px = 6 },
    }, scope, bodyNoneChildren);
}

fn bodyNoneChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "This request sends no body.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{ .text = "Pick raw, form-data or x-www-form-urlencoded above to give it one.", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn editorEmpty(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "A method, a URL, headers and a JSON body live here once a request is selected.", .size = t.type_scale.body, .color = t.colors.text_dim }, .wrap = true });
}

pub fn headersTable(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.header_count == 0) {
        box(.{
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
    scroll(.{
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
    label(.{ .label = .{ .text = "No headers on this request.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{ .text = "Press + Header to add one, for example Content-Type: application/json.", .size = t.type_scale.caption, .color = t.colors.text_done } });
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
    box(.{
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

    button(.{
        .id = .{ .text = frame.elementId("kurir.header.on", index) },
        .label = .{ .text = if (enabled) "on" else "off", .size = t.type_scale.caption, .color = if (enabled) t.colors.on_primary else t.colors.text_dim },
        .bg = if (enabled) theme_mod.success else t.colors.surface_variant,
        .hover_bg = t.colors.primary_hover,
        .w = .{ .fixed = 34 },
        .pad = props.Pad.axes(3, 4),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onToggleHeader, .ctx = &scope.vm.editor.header_ctxs[index * 2] },
    });

    const key_field = &views(scope).headers[index * 2];
    key_field.value = row.name;
    key_field.h = .{ .fixed = 26 };
    key_field.w = .{ .clamp = .{ .min = 90, .max = 220 } };
    textField(key_field);

    const value_field = &views(scope).headers[index * 2 + 1];
    value_field.value = row.value;
    value_field.h = .{ .fixed = 26 };
    // The row has one weight: the value takes what the key and the buttons leave.
    value_field.w = .{ .clamp = .{ .min = 120, .grow = true } };
    textField(value_field);

    button(.{
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
    scroll(.{
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

// The form-data and urlencoded table: one key/value row per part, with the same columns a header row has.
pub fn bodyPartsTable(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.body_part_count == 0) {
        box(.{
            .src = @src(),
            .id = .{ .text = "kurir.body.parts.empty" },
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .direction = .column,
            .gap = .{ .px = 6 },
        }, scope, bodyPartsEmpty);
        return;
    }
    scroll(.{
        .id = .{ .text = "kurir.body.parts" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, partRows);
}

fn bodyPartsEmpty(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "No rows in this body yet.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{ .text = "Press + Row to add a key and a value.", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn partRows(scope: *Scope) void {
    const count = @min(scope.state.body_part_count, state_mod.max_body_parts);
    var i: usize = 0;
    while (i < count) : (i += 1) partRow(scope, i);
}

const PartScope = struct {
    scope: *Scope,
    index: usize,
};

pub fn partRow(scope: *Scope, index: usize) void {
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.body.part.row", index) },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &PartScope{ .scope = scope, .index = index }, partRowChildren);
}

pub fn partRowChildren(ps: *const PartScope) void {
    const scope = ps.scope;
    const t = scope.theme;
    const index = ps.index;
    if (index >= scope.state.body_parts.len) return;
    const row = scope.state.body_parts[index];
    const enabled = !scope.vm.editor.bodyPartDisabled(index);

    button(.{
        .id = .{ .text = frame.elementId("kurir.body.part.on", index) },
        .label = .{ .text = if (enabled) "on" else "off", .size = t.type_scale.caption, .color = if (enabled) t.colors.on_primary else t.colors.text_dim },
        .bg = if (enabled) theme_mod.success else t.colors.surface_variant,
        .hover_bg = t.colors.primary_hover,
        .w = .{ .fixed = 34 },
        .pad = props.Pad.axes(3, 4),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onToggleBodyPart, .ctx = &scope.vm.editor.part_ctxs[index * 2] },
    });

    const key_field = &views(scope).parts[index * 2];
    key_field.value = row.key;
    key_field.h = .{ .fixed = 26 };
    key_field.w = .{ .clamp = .{ .min = 90, .max = 220 } };
    textField(key_field);

    const value_field = &views(scope).parts[index * 2 + 1];
    value_field.value = row.value;
    value_field.h = .{ .fixed = 26 };
    // The row has one weight: the value takes what the key and the buttons leave.
    value_field.w = .{ .clamp = .{ .min = 120, .grow = true } };
    textField(value_field);

    button(.{
        .id = .{ .text = frame.elementId("kurir.body.part.del", index) },
        .label = .{ .text = "x", .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onRemoveBodyPart, .ctx = &scope.vm.editor.part_ctxs[index * 2] },
    });
}

// The body is the toolkit's multiline field: it draws its own lines, its own caret, and takes its own clicks.
pub fn bodyField(scope: *Scope) void {
    const v = views(scope);
    const field = &v.body;
    const lines: f32 = @floatFromInt(@max(field.editor.lineCount(), 1));
    field.value = scope.state.body;
    field.w = .grow;
    // Tall enough for the text, and never shorter than the pane, so a long body scrolls instead of clipping.
    field.h = .{ .fixed = @max(body_min_h, lines * field.lineHeight() + 12) };
    // The CodeEditor declares the field and hands it the JSON runs; clicking, typing and the caret stay the field's.
    v.body_code.textField(field);
}

// ---- the environment picker, and the request's own variables -----------------------------------------------

// What the trigger says: the active environment, or that nothing sends.
fn environmentLabel(active: []const u8) []const u8 {
    if (active.len == 0) return editor_vm.no_environment;
    return frame.formatText("{s}  v", .{active});
}

// What a row of the picker's card reads: the active environment says so, the two verbs stay plain.
const EnvMenu = struct {
    theme: glinlandui.theme.Theme,
    active: []const u8,
};

fn renderEnvRow(menu: EnvMenu, item: []const u8, index: usize) void {
    _ = index;
    const t = menu.theme;
    const chosen = menu.active.len > 0 and std.mem.eql(u8, item, menu.active);
    const text = if (chosen) frame.formatText("{s}   active", .{item}) else item;
    label(.{ .label = .{
        .text = text,
        .size = t.type_scale.caption,
        .color = if (chosen) theme_mod.accent else t.colors.text,
    } });
}

// The card under the trigger: the workspace's environments, "No environment", and the way to the manager.
fn environmentMenu(scope: *Scope) void {
    const t = scope.theme;
    var rows: [state_mod.max_environments + 2][]const u8 = undefined;
    var count: usize = 0;
    for (scope.state.env_names) |name| {
        if (count >= state_mod.max_environments) break;
        rows[count] = name;
        count += 1;
    }
    rows[count] = editor_vm.no_environment;
    count += 1;
    rows[count] = editor_vm.manage_environments;
    count += 1;
    dropdown(.{
        .src = @src(),
        .field_id = editor_vm.env_menu_field_id,
        .list_id = editor_vm.env_menu_list_id,
        .field = null,
        .row_h = .{ .px = 28 },
        .row_bg = t.colors.surface,
        .row_fg = t.colors.text,
        .hover_bg = t.colors.hover,
        .border_width = .{ .px = 0 },
        .radius = .{ .px = 0 },
        .gap = .{ .px = 0 },
        .font_size = t.type_scale.caption,
        .on_select = .{ .f = actions.onEnvPick, .ctx = scope.vm },
        .overlay = true,
        .anchor_text = editor_vm.env_trigger_id,
        .overlay_id = editor_vm.env_menu_id,
        .overlay_bg = t.colors.surface,
        .overlay_pad = .{ .px = 4 },
        .overlay_border_width = .{ .px = 1 },
        .overlay_border_color = t.colors.divider,
        .z_index = 20,
    }, rows[0..count], EnvMenu{ .theme = t, .active = scope.state.env_active }, renderEnvRow);
}

// The Vars tab: the variables this request carries itself, which no other request resolves.
pub fn varsTab(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.vars.tab" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 6 },
    }, scope, varsTabChildren);
}

pub fn varsTabChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{
        .text = "These variables apply to this request only. Shared variables live in the Environment.",
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    }, .wrap = true });
    if (scope.state.request_var_count == 0) {
        label(.{ .label = .{ .text = "No variables of its own yet.", .size = t.type_scale.body, .color = t.colors.text_done } });
        return;
    }
    scroll(.{
        .id = .{ .text = "kurir.vars" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, varsRows);
}

pub fn varsRows(scope: *Scope) void {
    const count = @min(scope.state.request_var_count, state_mod.max_vars);
    var i: usize = 0;
    while (i < count) : (i += 1) varsRow(scope, i);
}

const VarScope = struct {
    scope: *Scope,
    index: usize,
};

pub fn varsRow(scope: *Scope, index: usize) void {
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.var.row", index) },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 6 },
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &VarScope{ .scope = scope, .index = index }, varsRowChildren);
}

pub fn varsRowChildren(vs: *const VarScope) void {
    const scope = vs.scope;
    const t = scope.theme;
    const index = vs.index;
    if (index >= scope.state.request_vars.len) return;
    const row = scope.state.request_vars[index];
    const editor = &scope.vm.editor;

    const name_field = &views(scope).vars[index * 2];
    name_field.value = row.name;
    name_field.h = .{ .fixed = 26 };
    name_field.w = .{ .clamp = .{ .min = 90, .max = 220, .grow = true } };
    textField(name_field);

    const value_field = &views(scope).vars[index * 2 + 1];
    value_field.value = row.value;
    value_field.h = .{ .fixed = 26 };
    value_field.w = .{ .clamp = .{ .min = 120, .max = 520, .grow = true } };
    textField(value_field);

    button(.{
        .id = .{ .text = frame.elementId("kurir.var.del", index) },
        .label = .{ .text = "x", .size = t.type_scale.caption, .color = t.colors.text_dim },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(3, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onRemoveRequestVar, .ctx = &editor.var_ctxs[index * 2] },
    });
}

// ---- the Scripts tab: a phase rail, one code field, and what the last run said -----------------------------

// The Scripts tab: the two phases on the left, the code field on the right, and the last run under it.
pub fn scriptsTab(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.scripts.tab" },
        .direction = .row,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 10 },
    }, scope, scriptsTabChildren);
}

pub fn scriptsTabChildren(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.scripts.rail" },
        .direction = .column,
        .w = .{ .fixed = 96 },
        .gap = .{ .px = 6 },
    }, scope, phaseRail);
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.scripts.pane" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 6 },
    }, scope, scriptPane);
}

fn phaseRail(scope: *Scope) void {
    phaseButton(scope, .pre, editor_vm.phase_pre_id, "Pre-req");
    phaseButton(scope, .post, editor_vm.phase_post_id, "Post-res");
}

// One phase: a button whose context was built once on the panel, because a click lands frames later.
fn phaseButton(scope: *Scope, phase: state_mod.ScriptPhase, id: []const u8, text: []const u8) void {
    const t = scope.theme;
    const active = scope.state.script_phase == phase;
    const index: usize = if (phase == .pre) 0 else 1;
    button(.{
        .src = @src(),
        .id = .{ .text = id },
        .label = .{ .text = text, .size = t.type_scale.caption, .color = if (active) t.colors.text else t.colors.text_dim },
        .bg = if (active) t.colors.surface_variant else t.colors.surface,
        .hover_bg = t.colors.hover,
        .w = .grow,
        .h = .{ .fixed = 28 },
        .pad = props.Pad.axes(0, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = actions.onScriptPhase, .ctx = &scope.vm.editor.phase_ctxs[index] },
    });
}

fn scriptPane(scope: *Scope) void {
    const t = scope.theme;
    scroll(.{
        .id = .{ .text = editor_vm.script_scroll_id },
        .direction = .both,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .border_width = .{ .px = 1 },
        .border_color = t.colors.divider,
        .radius = .{ .px = 6 },
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, scriptField);
    // What the language offers: a Postman snippet is pasted almost as it was, and this is the whole of it.
    label(.{ .label = .{
        .text = "local x = value  ·  if cond then ... else ... end  ·  .. joins text  ·  pm.response.json(), .text(), .code, .headers.get(name)  ·  pm.environment.set(name, value), and pm.globals is the same  ·  print() and console.log() land below",
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    }, .wrap = true });
    if (scope.state.script_error.len > 0) {
        label(.{ .label = .{
            .text = scope.state.script_error,
            .size = t.type_scale.caption,
            .color = theme_mod.danger,
        }, .wrap = true });
    } else if (scope.state.script_log.len > 0) {
        label(.{ .label = .{
            .text = scope.state.script_log,
            .size = t.type_scale.caption,
            .color = t.colors.text,
        }, .wrap = true });
    }
}

// The code field: the multiline editor the toolkit owns, sized to its own line count.
fn scriptField(scope: *Scope) void {
    const v = views(scope);
    const field = if (scope.state.script_phase == .pre) &v.pre else &v.post;
    field.value = scope.state.script_code;
    const lines: f32 = @floatFromInt(@max(field.editor.lineCount(), 1));
    field.w = .grow;
    // Tall enough for the code, never shorter than the pane, so a long script scrolls instead of clipping.
    field.h = .{ .fixed = @max(script_min_h, lines * field.lineHeight() + 12) };
    textField(field);
}
