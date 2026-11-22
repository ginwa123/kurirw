//! The response pane's screen: status, time, size, the body/headers tabs, and the failure banner.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const textField = glinlandui.components.input.textField;
const scroll = glinlandui.components.scroll.scroll;
const label = glinlandui.components.text.label;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("../../ui/state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const views_mod = @import("../shell/views.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");
const code_editor = @import("../code_editor.zig");
const response_vm = @import("view_model.zig");

const smallButton = widgets.smallButton;
const tabButton = widgets.tabButton;

const Scope = scope_mod.Scope;

// The pane's widgets: styled and bound on the first frame that declares them.
fn views(scope: *Scope) *views_mod.Views.Response {
    const v = &scope.views.response;
    if (v.started) return v;
    const session = &scope.vm.session;
    v.body = session.fieldStyle(.{ .text = response_vm.body_text_id }, @src());
    v.body.multiline = true;
    // Read-only: a response is something you read, select and copy — never something you type into.
    v.body.readonly = true;
    v.body.scroll_id = response_vm.body_scroll_id;
    v.body.pad = glinlandui.props.Pad.all(10);
    // The pane already draws the frame around the body: the field itself is seamless, so the text is the content.
    v.body.border = .{};
    // And no focus ring either: an outline around a page of printed JSON reads as a defect, and the caret shows the focus.
    v.body.focus_ring_w = .{ .px = 0 };
    v.body.radius = glinlandui.props.Radius.all(0);
    v.body.h = .{ .fixed = 30 };
    // The answer's colouring: a CodeEditor over the same field, so a JSON response reads like JSON.
    v.body_code = code_editor.CodeEditor.init(session.gpa);
    v.started = true;
    return v;
}

const Theme = glinlandui.theme.Theme;
const Color = glinlandui.Color;

// The pane is as tall as the split says: the line above it is what the pointer drags.
pub fn responsePane(scope: *Scope, height: f32) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response" },
        .direction = .column,
        .w = .grow,
        .h = .{ .fixed = height },
        .bg = scope.theme.colors.background,
        .pad = props.Pad.all(12),
        .gap = .{ .px = 8 },
    }, scope, responseChildren);
}

pub fn responseChildren(scope: *Scope) void {
    responseHeader(scope);
    responseBody(scope);
}

pub fn responseHeader(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response.head" },
        .direction = .row,
        .w = .grow,
        .gap = .{ .px = 12 },
        .child_align = .{ .y = .center },
    }, scope, responseHeadChildren);
}

pub fn responseHeadChildren(scope: *Scope) void {
    const t = scope.theme;
    const response = scope.state.response;
    switch (response.kind) {
        .none => label(.{ .label = .{ .text = "No response yet. Send a request to see one.", .size = t.type_scale.body, .color = t.colors.text_dim } }),
        .ok => {
            label(.{ .label = .{ .text = response.status_text, .size = t.type_scale.label, .color = theme_mod.statusColor(response.status) } });
            label(.{ .label = .{ .text = response.time_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
            label(.{ .label = .{ .text = response.size_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
        },
        .failed => label(.{ .label = .{ .text = response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } }),
    }

    spacer(.{ .text = "kurir.response.head.spacer" });

    // The tabs belong to the pane, not to the answer: the history outlives whatever result is on screen.
    tabButton(scope, "kurir.resp.tab.body", "Body", scope.state.response_tab == .body, actions.onResponseBodyTab);
    tabButton(scope, "kurir.resp.tab.headers", "Headers", scope.state.response_tab == .headers, actions.onResponseHeadersTab);
    if (scope.state.history.len > 0) {
        tabButton(scope, "kurir.resp.tab.history", frame.formatText("History {d}", .{scope.state.history.len}), scope.state.response_tab == .history, actions.onResponseHistoryTab);
    }
    if (scope.state.response_pinned) {
        label(.{ .label = .{ .text = "history", .size = t.type_scale.caption, .color = theme_mod.accent } });
    }
}

pub fn responseBody(scope: *Scope) void {
    if (scope.state.response_tab == .history) {
        historyList(scope);
        return;
    }
    switch (scope.state.response.kind) {
        .none => {},
        .failed => errorBanner(scope),
        .ok => okResponse(scope),
    }
}

pub fn errorBanner(scope: *Scope) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response.error" },
        .direction = .column,
        .w = .grow,
        .pad = props.Pad.all(12),
        .gap = .{ .px = 6 },
        .bg = t.colors.surface,
        .border = .all(1, theme_mod.danger),
        .radius = props.Radius.all(6),
    }, scope, errorBannerChildren);
}

pub fn errorBannerChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = scope.state.response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } });
    label(.{ .label = .{ .text = scope.state.response.error_message, .size = t.type_scale.body, .color = t.colors.text }, .wrap = true });
}

pub fn okResponse(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.response_tab == .headers) {
        scroll(.{
            .id = .{ .text = "kurir.response.headers" },
            .direction = .vertical,
            .w = .grow,
            .h = .grow,
            .track_bg = theme_mod.scrollbarTrack(t),
            .thumb_bg = t.colors.surface_variant,
            .thumb_hover_bg = t.colors.primary,
        }, scope, responseHeaderRows);
        return;
    }
    scroll(.{
        .id = .{ .text = response_vm.body_scroll_id },
        .direction = .both,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.surface,
        .border_width = .{ .px = 1 },
        .border_color = t.colors.divider,
        .radius = .{ .px = 6 },
        .pad = .{ .px = 10 },
        .track_bg = theme_mod.scrollbarTrack(t),
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, responseBodyLines);
}

pub fn responseHeaderRows(scope: *Scope) void {
    for (scope.state.response.headers, 0..) |header, i| {
        box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.response.header", i) },
            .direction = .row,
            .w = .grow,
            .gap = .{ .px = 8 },
        }, &HeaderNameScope{ .name = header.name, .value = header.value, .theme = scope.theme }, responseHeaderRowChildren);
    }
}

const HeaderNameScope = struct {
    name: []const u8,
    value: []const u8,
    theme: Theme,
};

pub fn responseHeaderRowChildren(hs: *const HeaderNameScope) void {
    label(.{ .label = .{ .text = hs.name, .size = hs.theme.type_scale.caption, .color = hs.theme.colors.text_dim } });
    label(.{ .label = .{ .text = hs.value, .size = hs.theme.type_scale.body, .color = hs.theme.colors.text } });
}

// The body is the toolkit's READ-ONLY multiline field: select a run, Cmd/Ctrl+C, and nothing can edit it.
pub fn responseBodyLines(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.response.body.len == 0) {
        label(.{ .label = .{ .text = "(empty body)", .size = t.type_scale.body, .color = t.colors.text_dim } });
        return;
    }
    const v = views(scope);
    const field = &v.body;
    // The document is the field's buffer, so a megabyte body is drawn, not copied.
    field.show(scope.state.response.body);
    // The app already knows where every line starts, and the field's window arithmetic is a read of that index.
    field.lines = scope.state.response.lines;
    field.w = .grow;
    // Full content height: the scrollbar measures the whole body while the field itself only draws the visible window.
    const total = if (scope.state.response.lines.len > 1) scope.state.response.lines.len - 1 else 0;
    field.h = .{ .fixed = @as(f32, @floatFromInt(total)) * field.lineHeight() + 2 * field.pad.top.pts() + 4 };
    // A JSON answer is coloured from the same rules the body editor uses; HTML or plain text is left alone.
    v.body_code.textField(field);
}

// ---- the history tab ------------------------------------------------------------------------------------------

// The last sends, newest first: the whole row is one click target, so a past result is one press away.
pub fn historyList(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.history.len == 0) {
        box(.{
            .src = @src(),
            .id = .{ .text = "kurir.response.history.empty" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .pad = props.Pad.all(8),
            .gap = .{ .px = 6 },
        }, scope, historyEmpty);
        return;
    }
    scroll(.{
        .id = .{ .text = response_vm.history_scroll_id },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .track_bg = theme_mod.scrollbarTrack(t),
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, historyRows);
}

fn historyEmpty(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "No results yet.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{ .text = "Send a request and its result lands here, twenty at a time.", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

pub fn historyRows(scope: *Scope) void {
    for (scope.state.history, 0..) |row, index| historyRow(scope, row, index);
}

const HistoryScope = struct {
    scope: *Scope,
    row: state_mod.HistoryRow,
    index: usize,
};

pub fn historyRow(scope: *Scope, row: state_mod.HistoryRow, index: usize) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId(response_vm.history_row_prefix, index) },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.axes(6, 8),
        .gap = .{ .px = 10 },
        .radius = props.Radius.all(4),
        // The pinned row is the one on screen, so it carries the same tint the selected tree row uses.
        .bg = if (row.pinned) Color.lerp(t.colors.surface, theme_mod.accent, 0.14) else t.colors.surface,
        .hover_bg = if (row.pinned) null else t.colors.hover,
        .child_align = .{ .y = .center },
        .on_click = .{ .f = actions.onHistoryRow, .ctx = &scope.vm.history_ctxs[index] },
    }, &HistoryScope{ .scope = scope, .row = row, .index = index }, historyRowChildren);
}

pub fn historyRowChildren(hs: *const HistoryScope) void {
    const t = hs.scope.theme;
    const row = hs.row;
    label(.{ .label = .{ .text = row.method, .size = t.type_scale.caption, .color = theme_mod.methodColor(row.method) } });
    label(.{ .label = .{ .text = row.name, .size = t.type_scale.body, .color = t.colors.text } });
    spacer(.{ .text = frame.elementId("kurir.response.history.spacer", hs.index) });
    label(.{ .label = .{ .text = row.status, .size = t.type_scale.caption, .color = if (row.failed) theme_mod.danger else theme_mod.statusColor(200) } });
    label(.{ .label = .{ .text = row.detail, .size = t.type_scale.caption, .color = t.colors.text_done } });
}
