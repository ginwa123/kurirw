//! The two buttons every panel draws. Both hand the click to a trampoline in `actions.zig`.
const glinlandui = @import("glinlandui");

const button_mod = glinlandui.components.button;
const props = glinlandui.props;

const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;

const HandlerFn = *const fn (?*anyopaque) void;

pub fn smallButton(scope: *Scope, id: []const u8, label: []const u8, width: u32, comptime handler: HandlerFn) void {
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

pub fn tabButton(scope: *Scope, id: []const u8, label: []const u8, active: bool, comptime handler: HandlerFn) void {
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
