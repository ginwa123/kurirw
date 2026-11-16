//! The file panels import and export open. A test installs its own, so no suite ever opens a real dialog.
const std = @import("std");
const glinlandui = @import("glinlandui");

const Allocator = std.mem.Allocator;

// The file panels import and export open.
pub const Dialogs = struct {
    ctx: ?*anyopaque = null,
    open_fn: *const fn (?*anyopaque, Allocator, []const u8) ?[]const u8 = openReal,
    save_fn: *const fn (?*anyopaque, Allocator, []const u8, []const u8) ?[]const u8 = saveReal,
    available: bool = true,
};

const json_filters = [_]glinlandui.file_dialog.Filter{
    .{ .name = "Postman collection", .rules = &.{.{ .pattern = "*.json" }} },
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

fn openReal(_: ?*anyopaque, gpa: Allocator, title: []const u8) ?[]const u8 {
    const selection = glinlandui.file_dialog.openFile(gpa, .{
        .title = title,
        .filters = &json_filters,
    }) catch return null;
    defer selection.deinit(gpa);
    if (selection.status != .selected) return null;
    const picked = selection.first() orelse return null;
    return gpa.dupe(u8, picked) catch null;
}

fn saveReal(_: ?*anyopaque, gpa: Allocator, title: []const u8, suggested: []const u8) ?[]const u8 {
    const selection = glinlandui.file_dialog.saveFile(gpa, .{
        .title = title,
        .filters = &json_filters,
        .current_name = suggested,
    }) catch return null;
    defer selection.deinit(gpa);
    if (selection.status != .selected) return null;
    const picked = selection.first() orelse return null;
    return gpa.dupe(u8, picked) catch null;
}
