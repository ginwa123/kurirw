//! The response pane's screen: status, time, size, the body/headers tabs, and the failure banner.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box_mod = glinlandui.components.box;
const scroll_mod = glinlandui.components.scroll;
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
const max_body_lines = scope_mod.max_body_lines;
const Theme = glinlandui.theme.Theme;

pub fn responsePane(scope: *Scope) void {
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

pub fn responseChildren(scope: *Scope) void {
    responseHeader(scope);
    responseBody(scope);
}

pub fn responseHeader(scope: *Scope) void {
    box_mod.box(.{
        .src = @src(),
        .id = .{ .text = "kurir.response.head" },
        .direction = .row,
        .w = .grow,
        .gap = 12,
        .child_align = .{ .y = .center },
    }, scope, responseHeadChildren);
}

pub fn responseHeadChildren(scope: *Scope) void {
    const t = scope.theme;
    const response = scope.state.response;
    switch (response.kind) {
        .none => text_mod.label(.{ .label = .{ .text = "No response yet. Send a request to see one.", .size = t.type_scale.body, .color = t.colors.text_dim } }),
        .ok => {
            text_mod.label(.{ .label = .{ .text = response.status_text, .size = t.type_scale.label, .color = theme_mod.statusColor(response.status) } });
            text_mod.label(.{ .label = .{ .text = response.time_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
            text_mod.label(.{ .label = .{ .text = response.size_text, .size = t.type_scale.caption, .color = t.colors.text_dim } });
            tabButton(scope, "kurir.resp.tab.body", "Body", scope.state.response_tab == .body, actions.onResponseBodyTab);
            tabButton(scope, "kurir.resp.tab.headers", "Headers", scope.state.response_tab == .headers, actions.onResponseHeadersTab);
        },
        .failed => text_mod.label(.{ .label = .{ .text = response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } }),
    }
}

pub fn responseBody(scope: *Scope) void {
    switch (scope.state.response.kind) {
        .none => {},
        .failed => errorBanner(scope),
        .ok => okResponse(scope),
    }
}

pub fn errorBanner(scope: *Scope) void {
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

pub fn errorBannerChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = scope.state.response.error_title, .size = t.type_scale.label, .color = theme_mod.danger } });
    text_mod.label(.{ .label = .{ .text = scope.state.response.error_message, .size = t.type_scale.body, .color = t.colors.text }, .wrap = true });
}

pub fn okResponse(scope: *Scope) void {
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

pub fn responseHeaderRows(scope: *Scope) void {
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

pub fn responseHeaderRowChildren(hs: *const HeaderNameScope) void {
    text_mod.label(.{ .label = .{ .text = hs.name, .size = hs.theme.type_scale.caption, .color = hs.theme.colors.text_dim } });
    text_mod.label(.{ .label = .{ .text = hs.value, .size = hs.theme.type_scale.body, .color = hs.theme.colors.text } });
}

pub fn responseBodyLines(scope: *Scope) void {
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
