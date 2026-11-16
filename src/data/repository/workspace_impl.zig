//! The document on disk: `$KURIR_HOME/workspaces.json`, else `$HOME/.kurir/workspaces.json`.
const std = @import("std");
const glinlandui = @import("glinlandui");

const store = @import("../local/workspace_store.zig");
const domain = @import("../../domain/repository/workspace.zig");

const Ctx = glinlandui.Ctx;

pub const Allocator = std.mem.Allocator;

pub const FileStore = struct {
    io: std.Io,
    path: []const u8,

    pub fn init(io: std.Io, path: []const u8) FileStore {
        return .{ .io = io, .path = path };
    }

    // The interface the UI holds. It points back at this struct, so the FileStore must outlive the view.
    pub fn workspace(self: *FileStore) domain.Workspace {
        return .{ .ctx = Ctx.from(self), .load_fn = load, .save_fn = save };
    }

    fn load(ctx: Ctx, alloc: Allocator, workspace_id: []const u8) domain.Loaded {
        const self = ctx.get(FileStore);
        const found = store.load(self.io, alloc, self.path, workspace_id);
        return .{ .doc = found.doc, .from_disk = found.from_disk, .error_name = found.error_name };
    }

    fn save(ctx: Ctx, alloc: Allocator, doc: domain.Value) anyerror!void {
        const self = ctx.get(FileStore);
        return store.save(self.io, alloc, self.path, doc);
    }
};
