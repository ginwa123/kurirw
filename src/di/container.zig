//! The one place a dependency is built: the document file, the HTTP client, the dialogs, the theme.
const std = @import("std");

const glinlandui = @import("glinlandui");

const store_mod = @import("../data/local/workspace_store.zig");
const session_store = @import("../data/local/session_store.zig");
const env_store = @import("../data/local/env_store.zig");
const file_picker = @import("../data/local/file_picker.zig");
const http_mod = @import("../data/remote/http_client.zig");
const file_store = @import("../data/repository/workspace_impl.zig");
const theme_mod = @import("../ui/theme/theme.zig");

const Allocator = std.mem.Allocator;

pub const Container = struct {
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    // Where the document lives: computed once, freed once.
    path: []u8 = &.{},
    // The working session beside it: the tabs that were open, and the edits nobody saved yet.
    session_path: []u8 = &.{},
    // The global variables, shared by every workspace and every request.
    env_path: []u8 = &.{},
    // The process environment as the app was started with: the Playwright child inherits it.
    environ: std.process.Environ.Map = undefined,
    file: file_store.FileStore = undefined,
    remote: http_mod.Real = undefined,
    // The file panels import and export open; a test installs its own before `start`.
    dialogs: file_picker.Dialogs = .{},
    theme: glinlandui.theme.Theme = theme_mod.app_theme,

    pub fn init(self: *Container, gpa: Allocator, io: std.Io, environ: anytype) !void {
        self.gpa = gpa;
        self.io = io;
        self.environ = environ;
        self.path = try store_mod.defaultPath(gpa, environ);
        self.session_path = try session_store.pathFor(gpa, self.path);
        self.env_path = try env_store.pathFor(gpa, self.path);
        self.file = file_store.FileStore.init(io, self.path);
        self.remote = http_mod.Real.init(gpa);
    }

    pub fn deinit(self: *Container) void {
        self.remote.deinit();
        if (self.path.len > 0) self.gpa.free(self.path);
        if (self.session_path.len > 0) self.gpa.free(self.session_path);
        if (self.env_path.len > 0) self.gpa.free(self.env_path);
        self.* = undefined;
    }
};
