//! The interface the UI talks to for the document: how it is read, how it is written. A vtable, like `Transport`.
const std = @import("std");
const glinlandui = @import("glinlandui");

const postman = @import("../../data/model/postman.zig");

const Ctx = glinlandui.Ctx;

pub const Allocator = std.mem.Allocator;
pub const Value = postman.Value;

// What a read found: the document, whether it came from somewhere, and why not when it did not.
pub const Loaded = struct {
    doc: Value = .{ .null = {} },
    from_disk: bool = false,
    error_name: []const u8 = "",
};

pub const Workspace = struct {
    ctx: Ctx = Ctx.none,
    load_fn: *const fn (Ctx, alloc: Allocator, workspace_id: []const u8) Loaded,
    save_fn: *const fn (Ctx, alloc: Allocator, doc: Value) anyerror!void,

    pub fn load(self: Workspace, alloc: Allocator, workspace_id: []const u8) Loaded {
        return self.load_fn(self.ctx, alloc, workspace_id);
    }

    pub fn save(self: Workspace, alloc: Allocator, doc: Value) !void {
        return self.save_fn(self.ctx, alloc, doc);
    }
};
