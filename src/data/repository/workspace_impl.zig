//! The document on disk: `$KURIR_HOME/workspaces.json`, else `$HOME/.kurir/workspaces.json`.
const std = @import("std");

const store = @import("../local/workspace_store.zig");
const domain = @import("../../domain/repository/workspace.zig");

pub const Allocator = std.mem.Allocator;

pub const FileStore = struct {
    io: std.Io,
    path: []const u8,

    pub fn init(io: std.Io, path: []const u8) FileStore {
        return .{ .io = io, .path = path };
    }

    // The interface the UI holds. It points back at this struct, so the FileStore must outlive the view.
    pub fn workspace(self: *FileStore) domain.Workspace {
        return .{ .ctx = self, .load_fn = load, .save_fn = save };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator, workspace_id: []const u8) domain.Loaded {
        const self: *FileStore = @ptrCast(@alignCast(raw.?));
        const found = store.load(self.io, alloc, self.path, workspace_id);
        return .{ .doc = found.doc, .from_disk = found.from_disk, .error_name = found.error_name };
    }

    fn save(raw: ?*anyopaque, alloc: Allocator, doc: domain.Value) anyerror!void {
        const self: *FileStore = @ptrCast(@alignCast(raw.?));
        return store.save(self.io, alloc, self.path, doc);
    }
};
