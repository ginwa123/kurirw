//! The widget instances the screen declares. A ViewModel keeps STATE; a Field is a view, so it is owned here.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Field = glinlandui.components.input.Field;

const state_mod = @import("../state.zig");
const code_editor = @import("../code_editor.zig");

pub const Views = struct {
    sidebar: Sidebar = .{},
    editor: Editor = .{},
    response: Response = .{},
    env: Env = .{},

    // Give back every run a field grew past its inline buffer, and the colouring buffers with it.
    pub fn deinit(self: *Views) void {
        self.sidebar.deinit();
        self.editor.deinit();
        self.response.deinit();
        self.env.deinit();
    }

    // The left panel: the workspace's name and the filter. The rename box lives in the editor's row (see `Editor.name`).
    pub const Sidebar = struct {
        workspace: Field = undefined,
        filter: Field = undefined,
        // Styled and bound on the first declare: the theme and the engine's text allocator exist only by then.
        started: bool = false,
        // True while the workspace name held the keyboard: a focus it GAINS selects the whole name.
        workspace_focused: bool = false,

        pub fn deinit(self: *Sidebar) void {
            // A field that was never bound holds no run of its own, so freeing it would free garbage.
            if (!self.started) return;
            self.workspace.deinit();
            self.filter.deinit();
        }
    };

    // The request editor: the URL, two key/value tables, the body, the scripts, and the body's own colouring.
    pub const Editor = struct {
        // The selected node's name: it sits in the editor's own row, and renaming is a sidebar intent.
        name: Field = undefined,
        url: Field = undefined,
        headers: [state_mod.max_headers * 2]Field = undefined,
        parts: [state_mod.max_body_parts * 2]Field = undefined,
        vars: [state_mod.max_vars * 2]Field = undefined,
        body: Field = undefined,
        body_code: code_editor.CodeEditor = undefined,
        pre: Field = undefined,
        post: Field = undefined,
        started: bool = false,
        // True while the name box held the keyboard: a focus it GAINS selects the whole name.
        name_focused: bool = false,

        pub fn deinit(self: *Editor) void {
            if (!self.started) return;
            self.name.deinit();
            self.url.deinit();
            self.body.deinit();
            self.body_code.deinit();
            self.pre.deinit();
            self.post.deinit();
            for (&self.headers) |*field| field.deinit();
            for (&self.parts) |*field| field.deinit();
            for (&self.vars) |*field| field.deinit();
        }
    };

    // The response pane: one read-only field, and the colouring a JSON answer gets.
    pub const Response = struct {
        body: Field = undefined,
        body_code: code_editor.CodeEditor = undefined,
        started: bool = false,

        pub fn deinit(self: *Response) void {
            if (!self.started) return;
            self.body.deinit();
            self.body_code.deinit();
        }
    };

    // The environment manager: one row of three columns, plus the pane's title, which IS the name field.
    pub const Env = struct {
        names: [state_mod.max_env_vars]Field = undefined,
        initial: [state_mod.max_env_vars]Field = undefined,
        current: [state_mod.max_env_vars]Field = undefined,
        name: Field = undefined,
        started: bool = false,

        pub fn deinit(self: *Env) void {
            if (!self.started) return;
            for (&self.names) |*field| field.deinit();
            for (&self.initial) |*field| field.deinit();
            for (&self.current) |*field| field.deinit();
            self.name.deinit();
        }
    };
};

// A panel declares its widgets on its first frame, so a view that never got there must free nothing.
test "a view that was never declared frees nothing, and says so" {
    var views: Views = .{};
    views.deinit();
    try std.testing.expect(!views.sidebar.started);
    try std.testing.expect(!views.editor.started);
    try std.testing.expect(!views.response.started);
    try std.testing.expect(!views.env.started);
}
