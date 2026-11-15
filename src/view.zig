//! The view: pure declaration from the state, raising intents on the ViewModel and never writing anything.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const button_mod = glinlandui.components.button;
const input_mod = glinlandui.components.input;
const list_mod = glinlandui.components.list;
const scroll_mod = glinlandui.components.scroll;
const sidebar_mod = glinlandui.components.sidebar;
const text_mod = glinlandui.components.text;
const frame = glinlandui.frame;
const props = glinlandui.props;

const postman = @import("data/model/postman.zig");
const state_mod = @import("state.zig");
const theme_mod = @import("ui/theme/theme.zig");
const view_model = @import("ui/shell/view_model.zig");

const UiState = state_mod.UiState;
const KurirViewModel = view_model.KurirViewModel;
const Theme = glinlandui.theme.Theme;

const editor_h: u32 = 320;
const row_h: u32 = 26;
const indent: u16 = 14;
const body_min_h: f32 = 170;
const max_body_lines: usize = 4000;

// What a composable reads: the theme, the model, and this frame's snapshot of its state.
pub const Scope = struct {
    theme: Theme,
    vm: *KurirViewModel,
    state: UiState,
};

// `@Composable fun KurirScreen()` — the window's root function.
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

fn rootChildren(scope: *Scope) void {
    // The panel and its grab line are the toolkit's; what goes inside is Kurir's.
    var panel = scope.vm.sidebar.props();
    panel.src = @src();
    sidebar_mod.sidebar(panel, scope, sidebarChildren);
    mainArea(scope);
}

// ---- sidebar -------------------------------------------------------------------------------------------------

fn sidebarChildren(scope: *Scope) void {
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

fn sidebarContent(scope: *Scope) void {
    workspaceStrip(scope);
    toolbar(scope);
    tree(scope);
}

fn workspaceStrip(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.sides(10, 10, 8, 10),
        .gap = 6,
    }, scope, workspaceStripChildren);
}

fn workspaceStripChildren(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.ws.head" },
        .direction = .row,
        .w = .grow,
        .gap = 6,
        .child_align = .{ .y = .center },
    }, scope, wsHead);

    text_mod.label(.{ .label = .{ .text = scope.state.workspace_label, .size = t.type_scale.caption, .color = t.colors.text_dim } });

    const field = &scope.vm.sidebar.workspace_field;
    field.value = scope.state.workspace_name;
    field.w = .grow;
    input_mod.textField(field);
}

fn wsHead(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "WORKSPACE", .size = t.type_scale.caption, .color = t.colors.text_dim } });
    box_mod.spacer(.{ .text = "kurir.ws.spacer" });
    smallButton(scope, "kurir.ws.add", "+", 26, onAddWorkspace);
    smallButton(scope, "kurir.ws.next", "->", 26, onNextWorkspace);
    smallButton(scope, "kurir.ws.del", "-", 26, onDeleteWorkspace);
}

fn toolbar(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.sides(0, 10, 8, 10),
        .gap = 6,
    }, scope, toolbarChildren);
}

fn toolbarChildren(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools.row1" },
        .direction = .row,
        .w = .grow,
        .gap = 6,
        .child_align = .{ .y = .center },
    }, scope, toolsRowOne);

    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.tools.row2" },
        .direction = .row,
        .w = .grow,
        .gap = 6,
        .child_align = .{ .y = .center },
    }, scope, toolsRowTwo);

    text_mod.label(.{ .label = .{ .text = scope.state.status, .size = t.type_scale.caption, .color = if (scope.state.status_is_error) theme_mod.danger else t.colors.text_dim }, .wrap = true });
}

fn toolsRowOne(scope: *Scope) void {
    smallButton(scope, "kurir.add.collection", "+ Collection", 122, onAddCollection);
    smallButton(scope, "kurir.add.folder", "+ Folder", 96, onAddFolder);
}

fn toolsRowTwo(scope: *Scope) void {
    smallButton(scope, "kurir.add.request", "+ Request", 122, onAddRequest);
    smallButton(scope, "kurir.import", "Import", 70, onImport);
    smallButton(scope, "kurir.export", "Export", 70, onExport);
}

fn tree(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.rows.len == 0) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.tree.empty" },
            .direction = .column,
            .w = .grow,
            .pad = props.Pad.all(16),
            .gap = 8,
            .hover_bg = scope.theme.colors.hover,
            // The empty state is the first button a new user presses, so it is one.
            .on_click = .{ .f = onAddCollection, .ctx = scope.vm },
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

fn emptyTree(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "No collections yet.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = "Click here, or press + Collection, to make one.", .size = t.type_scale.caption, .color = t.colors.text_done }, .wrap = true });
}

fn treeChildren(scope: *Scope) void {
    const t = scope.theme;
    list_mod.list(.{
        .id = .{ .text = "kurir.tree.list" },
        .row_h = row_h,
        .row_bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .selected_bg = t.colors.surface_variant,
        .selected_fg = t.colors.text,
        .row_fg = t.colors.text,
        .radius = 0,
        .on_select = .{ .f = onRow, .ctx = scope.vm },
    }, scope.state.rows, scope, renderRow);
}

// A row: a caret for a container, a coloured method for a request, then the name.
const RowScope = struct {
    scope: *Scope,
    row: state_mod.TreeRow,
    index: usize,
};

fn renderRow(scope: *Scope, row: state_mod.TreeRow, index: usize) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.tree.row", index) },
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(row_h) },
        .pad = props.Pad.sides(0, 8, 0, @intCast(8 + row.depth * indent)),
        .gap = 6,
        .child_align = .{ .y = .center },
    }, &RowScope{ .scope = scope, .row = row, .index = index }, rowChildren);
}

fn rowChildren(rs: *const RowScope) void {
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

// ---- main area -----------------------------------------------------------------------------------------------

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
    requestEditor(scope);
    responsePane(scope);
}

fn requestEditor(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.editor" },
        .direction = .column,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(editor_h) },
        .bg = scope.theme.colors.surface,
        .border = .{ .width = 1, .color = scope.theme.colors.divider },
        .pad = props.Pad.all(12),
        .gap = 8,
    }, scope, editorChildren);
}

fn editorChildren(scope: *Scope) void {
    nameRow(scope);
    methodRow(scope);
    editorTabs(scope);
    editorBody(scope);
}

fn nameRow(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.name.row" },
        .direction = .row,
        .w = .grow,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, scope, nameRowChildren);
}

fn nameRowChildren(scope: *Scope) void {
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
        .on_click = .{ .f = onDelete, .ctx = scope.vm },
    });
}

fn methodRow(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.method.row" },
        .direction = .row,
        .w = .grow,
        .gap = 4,
        .child_align = .{ .y = .center },
    }, scope, methodRowChildren);
}

fn methodRowChildren(scope: *Scope) void {
    const t = scope.theme;
    const enabled = scope.state.node_kind == .request;
    for (postman.methods, 0..) |method, i| {
        const active = std.mem.eql(u8, scope.state.method, method);
        const color = theme_mod.methodColor(method);
        button_mod.button(.{
            .id = .{ .text = frame.elementId("kurir.method", i) },
            .label = .{ .text = method, .size = t.type_scale.caption, .color = if (active) t.colors.on_primary else color },
            .bg = if (active) color else t.colors.background,
            .hover_bg = t.colors.surface_variant,
            .disabled = !enabled,
            .w = .{ .fixed = 56 },
            .pad = props.Pad.axes(4, 6),
            .radius = props.Radius.all(4),
            .on_click = .{ .f = onMethod, .ctx = &scope.vm.editor.method_ctxs[i] },
        });
    }

    const field = &scope.vm.editor.url_field;
    field.value = scope.state.url;
    field.disabled = !enabled;
    field.w = .grow;
    input_mod.textField(field);

    button_mod.button(.{
        .id = .{ .text = "kurir.send" },
        .label = .{ .text = "Send", .size = t.type_scale.label, .color = t.colors.on_primary },
        .bg = theme_mod.success,
        .hover_bg = t.colors.primary_hover,
        .disabled = !enabled,
        .pad = props.Pad.axes(8, 18),
        .radius = props.Radius.all(6),
        .on_click = .{ .f = onSend, .ctx = scope.vm },
    });
}

fn editorTabs(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.editor.tabs" },
        .direction = .row,
        .w = .grow,
        .gap = 6,
        .child_align = .{ .y = .center },
    }, scope, editorTabsChildren);
}

fn editorTabsChildren(scope: *Scope) void {
    const t = scope.theme;
    tabButton(scope, "kurir.tab.headers", "Headers", scope.state.editor_tab == .headers, onHeadersTab);
    tabButton(scope, "kurir.tab.body", "Body", scope.state.editor_tab == .body, onBodyTab);
    box_mod.spacer(.{ .text = "kurir.tabs.spacer" });
    if (scope.state.node_kind == .request and scope.state.editor_tab == .headers) {
        smallButton(scope, "kurir.header.add", "+ Header", 84, onAddHeader);
    }
    text_mod.label(.{ .label = .{ .text = "Ctrl/Cmd+Enter sends", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn editorBody(scope: *Scope) void {
    if (scope.state.node_kind != .request) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.editor.empty" },
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .direction = .column,
            .gap = 6,
        }, scope, editorEmpty);
        return;
    }
    if (scope.state.editor_tab == .headers) {
        headersTable(scope);
    } else {
        bodyEditor(scope);
    }
}

fn editorEmpty(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "A method, a URL, headers and a JSON body live here once a request is selected.", .size = t.type_scale.body, .color = t.colors.text_dim }, .wrap = true });
}

fn headersTable(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.header_count == 0) {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = "kurir.headers.empty" },
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .direction = .column,
            .gap = 6,
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

fn headersEmpty(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "No headers on this request.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = "Press + Header to add one, for example Content-Type: application/json.", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn headerRows(scope: *Scope) void {
    const count = @min(scope.state.header_count, state_mod.max_headers);
    var i: usize = 0;
    while (i < count) : (i += 1) headerRow(scope, i);
}

const HeaderScope = struct {
    scope: *Scope,
    index: usize,
};

fn headerRow(scope: *Scope, index: usize) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.header.row", index) },
        .direction = .row,
        .w = .grow,
        .gap = 6,
        .pad = props.Pad.sides(2, 0, 2, 0),
        .child_align = .{ .y = .center },
    }, &HeaderScope{ .scope = scope, .index = index }, headerRowChildren);
}

fn headerRowChildren(hs: *const HeaderScope) void {
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
        .on_click = .{ .f = onToggleHeader, .ctx = &scope.vm.editor.header_ctxs[index * 2] },
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
        .on_click = .{ .f = onRemoveHeader, .ctx = &scope.vm.editor.header_ctxs[index * 2] },
    });
}

// ---- the body editor: the one widget Kurir draws itself ------------------------------------------------------

fn bodyEditor(scope: *Scope) void {
    const t = scope.theme;
    scroll_mod.scroll(.{
        .id = .{ .text = "kurir.body.scroll" },
        .direction = .both,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .border_width = 1,
        .border_color = t.colors.divider,
        .radius = 6,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, bodyField);
}

// The body is the toolkit's multiline field: it draws its own lines, its own caret, and takes its own clicks.
fn bodyField(scope: *Scope) void {
    const field = &scope.vm.editor.body_field;
    const lines: f32 = @floatFromInt(@max(field.editor.lineCount(), 1));
    field.value = scope.state.body;
    field.w = .grow;
    // Tall enough for the text, and never shorter than the pane, so a long body scrolls instead of clipping.
    field.h = .{ .fixed = @max(body_min_h, lines * field.lineHeight() + 12) };
    input_mod.textField(field);
}

// ---- the response pane ---------------------------------------------------------------------------------------

fn responsePane(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.background,
        .pad = props.Pad.all(12),
        .gap = 8,
    }, scope, responseChildren);
}

fn responseChildren(scope: *Scope) void {
    responseHeader(scope);
    responseBody(scope);
}

fn responseHeader(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response.head" },
        .direction = .row,
        .w = .grow,
        .gap = 12,
        .child_align = .{ .y = .center },
    }, scope, responseHeadChildren);
}

fn responseHeadChildren(scope: *Scope) void {
    const t = scope.theme;
    const response = scope.state.response;
    switch (response.kind) {
        .none => text_mod.label(.{ .label = .{ .text = "No response yet. Send a request to see one.", .size = t.type_scale.body, .color = t.colors.text_dim } }),
        .ok => {
            text_mod.label(.{ .label = .{ .text = response.status_text, .size = t.type_scale.label, .color = theme_mod.statusColor(response.status) } });
            text_mod.label(.{ .label = .{ .text = response.time_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
            text_mod.label(.{ .label = .{ .text = response.size_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
            tabButton(scope, "kurir.resp.tab.body", "Body", scope.state.response_tab == .body, onResponseBodyTab);
            tabButton(scope, "kurir.resp.tab.headers", "Headers", scope.state.response_tab == .headers, onResponseHeadersTab);
        },
        .failed => text_mod.label(.{ .label = .{ .text = response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } }),
    }
}

fn responseBody(scope: *Scope) void {
    switch (scope.state.response.kind) {
        .none => {},
        .failed => errorBanner(scope),
        .ok => okResponse(scope),
    }
}

fn errorBanner(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response.error" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.all(12),
        .gap = 6,
        .bg = t.colors.surface,
        .border = .{ .width = 1, .color = theme_mod.danger },
        .radius = props.Radius.all(6),
    }, scope, errorBannerChildren);
}

fn errorBannerChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = scope.state.response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } });
    text_mod.label(.{ .label = .{ .text = scope.state.response.error_message, .size = t.type_scale.body, .color = t.colors.text }, .wrap = true });
}

fn okResponse(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.response_tab == .headers) {
        scroll_mod.scroll(.{
            .id = .{ .text = "kurir.response.headers" },
            .direction = .vertical,
            .w = .grow,
            .h = .grow,
            .thumb_bg = t.colors.surface_variant,
            .thumb_hover_bg = t.colors.primary,
        }, scope, responseHeaderRows);
        return;
    }
    scroll_mod.scroll(.{
        .id = .{ .text = "kurir.response.body" },
        .direction = .both,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.surface,
        .border_width = 1,
        .border_color = t.colors.divider,
        .radius = 6,
        .pad = 10,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, responseBodyLines);
}

fn responseHeaderRows(scope: *Scope) void {
    for (scope.state.response.headers, 0..) |header, i| {
        box_mod.box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.response.header", i) },
            .direction = .row,
            .w = .grow,
            .gap = 8,
        }, &HeaderNameScope{ .name = header.name, .value = header.value, .theme = scope.theme }, responseHeaderRowChildren);
    }
}

const HeaderNameScope = struct {
    name: []const u8,
    value: []const u8,
    theme: Theme,
};

fn responseHeaderRowChildren(hs: *const HeaderNameScope) void {
    text_mod.label(.{ .label = .{ .text = hs.name, .size = hs.theme.type_scale.caption, .color = hs.theme.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = hs.value, .size = hs.theme.type_scale.body, .color = hs.theme.colors.text } });
}

fn responseBodyLines(scope: *Scope) void {
    const t = scope.theme;
    const body = scope.state.response.body;
    if (body.len == 0) {
        text_mod.label(.{ .label = .{ .text = "(empty body)", .size = t.type_scale.body, .color = t.colors.text_dim } });
        return;
    }
    var start: usize = 0;
    var lines: usize = 0;
    while (start < body.len and lines < max_body_lines) : (lines += 1) {
        const end = std.mem.findScalarPos(u8, body, start, '\n') orelse body.len;
        const line = body[start..end];
        text_mod.label(.{ .label = .{ .text = if (line.len == 0) " " else line, .size = t.type_scale.body, .color = t.colors.text } });
        start = end + 1;
    }
}

// ---- small pieces ---------------------------------------------------------------------------------------------

const HandlerFn = *const fn (?*anyopaque) void;

fn smallButton(scope: *Scope, id: []const u8, label: []const u8, width: u32, comptime handler: HandlerFn) void {
    const t = scope.theme;
    button_mod.button(.{
        .id = .{ .text = id },
        .label = .{ .text = label, .size = t.type_scale.caption, .color = t.colors.text },
        .bg = t.colors.surface_variant,
        .hover_bg = t.colors.hover,
        .w = .{ .fixed = @floatFromInt(width) },
        .pad = props.Pad.axes(4, 8),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = handler, .ctx = scope.vm },
    });
}

fn tabButton(scope: *Scope, id: []const u8, label: []const u8, active: bool, comptime handler: HandlerFn) void {
    const t = scope.theme;
    button_mod.button(.{
        .id = .{ .text = id },
        .label = .{ .text = label, .size = t.type_scale.caption, .color = if (active) t.colors.text else t.colors.text_dim },
        .bg = if (active) t.colors.surface_variant else t.colors.surface,
        .hover_bg = t.colors.hover,
        .pad = props.Pad.axes(4, 10),
        .radius = props.Radius.all(4),
        .on_click = .{ .f = handler, .ctx = scope.vm },
    });
}

// ---- intents -------------------------------------------------------------------------------------------------

fn onRow(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.onRowSelect(index);
}

fn onMethod(ctx: ?*anyopaque) void {
    const method_ctx: *KurirViewModel.MethodCtx = @ptrCast(@alignCast(ctx.?));
    method_ctx.editor.setMethod(method_ctx.method);
}

fn onSend(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.send();
}

fn onAddCollection(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addCollection();
}

fn onAddFolder(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addFolder();
}

fn onAddRequest(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addRequest();
}

fn onDelete(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.deleteSelected();
}

fn onAddWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addWorkspace();
}

fn onNextWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.nextWorkspace();
}

fn onDeleteWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.deleteWorkspace();
}

fn onImport(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.importCollection();
}

fn onExport(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.exportSelected();
}

fn onAddHeader(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addHeader();
}

fn onRemoveHeader(ctx: ?*anyopaque) void {
    const header_ctx: *KurirViewModel.HeaderCtx = @ptrCast(@alignCast(ctx.?));
    header_ctx.editor.removeHeader(header_ctx.index);
}

fn onToggleHeader(ctx: ?*anyopaque) void {
    const header_ctx: *KurirViewModel.HeaderCtx = @ptrCast(@alignCast(ctx.?));
    header_ctx.editor.toggleHeader(header_ctx.index);
}

fn onHeadersTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.headers);
}

fn onBodyTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.body);
}

fn onResponseBodyTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setResponseTab(.body);
}

fn onResponseHeadersTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setResponseTab(.headers);
}

test "the layout constants describe one row band per tree row" {
    try std.testing.expectEqual(@as(u32, 26), row_h);
    try std.testing.expect(editor_h > row_h * 3);
}
