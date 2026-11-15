//! The request editor's ViewModel: method, URL, headers, body. Edits land in the document, never in a copy.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const frame = glinlandui.frame;

const postman = @import("../../data/model/postman.zig");
const state_mod = @import("../../state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Session = session_mod.Session;

pub const url_field_id = "kurir.url";
pub const body_id = "kurir.body";
pub const header_key_prefix = "kurir.header.key";
pub const header_value_prefix = "kurir.header.value";

pub const body_pad: f32 = 10;
pub const line_height: f32 = 20;

pub const Editor = struct {
    session: *Session = undefined,

    url_buf: []u8 = &.{},
    url_field: input_mod.Field = undefined,
    header_fields: [state_mod.max_headers * 2]input_mod.Field = undefined,
    header_ctxs: [state_mod.max_headers * 2]HeaderCtx = undefined,

    body_buf: []u8 = &.{},
    // The body is the toolkit's multiline field: Enter types a line, Ctrl/Cmd+Enter sends.
    body_field: input_mod.Field = undefined,
    method_ctxs: [postman.methods.len]MethodCtx = undefined,

    tab: state_mod.Tab = .headers,

    // One method button's context: the panel, and which verb it stands for.
    pub const MethodCtx = struct {
        editor: *Editor,
        method: []const u8 = "",
    };

    pub const HeaderCtx = struct {
        editor: *Editor,
        index: usize,
        // True for the value column, false for the key column.
        value_side: bool,
    };

    pub fn onUrlTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.session.focus = .url;
        self.onUrlChange(text);
    }

    pub fn onUrlFocused(raw: ?*anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.session.focus = .url;
    }

    pub fn onBodyTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.session.focus = .body;
        self.setBody(text);
    }

    pub fn onBodyFocused(raw: ?*anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.session.focus = .body;
    }

    pub fn onHeaderTyped(raw: ?*anyopaque, text: []const u8) void {
        const ctx: *HeaderCtx = @ptrCast(@alignCast(raw.?));
        ctx.editor.session.focus = if (ctx.value_side) .header_value else .header_key;
        if (ctx.value_side) {
            ctx.editor.onHeaderValueChange(ctx.index, text);
        } else {
            ctx.editor.onHeaderKeyChange(ctx.index, text);
        }
    }

    pub fn start(self: *Editor, session: *Session) void {
        self.session = session;
        const gpa = session.gpa;

        self.url_buf = gpa.alloc(u8, state_mod.max_url) catch gpa.alloc(u8, 1) catch return;
        self.body_buf = gpa.alloc(u8, state_mod.max_body) catch gpa.alloc(u8, 1) catch return;

        self.url_field = session.fieldStyle(.{ .text = url_field_id }, @src());
        self.url_field.bindTo(self.url_buf);
        // The body is one multiline field bound to the big buffer; the toolkit draws its own lines and caret.
        self.body_field = session.fieldStyle(.{ .text = body_id }, @src());
        self.body_field.multiline = true;
        self.body_field.pad = glinlandui.props.Pad.all(body_pad);
        self.body_field.bindTo(self.body_buf);

        var i: usize = 0;
        while (i < state_mod.max_headers) : (i += 1) {
            self.header_fields[i * 2] = session.fieldStyle(.at(header_key_prefix, i), @src());
            self.header_fields[i * 2].bind();
            self.header_fields[i * 2 + 1] = session.fieldStyle(.at(header_value_prefix, i), @src());
            self.header_fields[i * 2 + 1].bind();
            self.header_ctxs[i * 2] = .{ .editor = self, .index = i, .value_side = false };
            self.header_ctxs[i * 2 + 1] = .{ .editor = self, .index = i, .value_side = true };
            self.header_fields[i * 2].on_change = .{ .f = onHeaderTyped, .ctx = &self.header_ctxs[i * 2] };
            self.header_fields[i * 2 + 1].on_change = .{ .f = onHeaderTyped, .ctx = &self.header_ctxs[i * 2 + 1] };
        }

        // The intents are set ONCE: a frame only hands each field the model's value.
        self.url_field.on_change = .{ .f = onUrlTyped, .ctx = self };
        self.url_field.on_focus = .{ .f = onUrlFocused, .ctx = self };
        self.body_field.on_change = .{ .f = onBodyTyped, .ctx = self };
        self.body_field.on_focus = .{ .f = onBodyFocused, .ctx = self };
        for (postman.methods, 0..) |method, index| {
            self.method_ctxs[index] = .{ .editor = self, .method = method };
        }
    }

    pub fn deinit(self: *Editor) void {
        if (self.url_buf.len > 0) self.session.gpa.free(self.url_buf);
        if (self.body_buf.len > 0) self.session.gpa.free(self.body_buf);
    }

    // Push the selected node into the fields: on a selection change, never while a field is being typed.
    pub fn load(self: *Editor) void {
        self.url_field.setText("");
        self.body_field.setText("");

        const node = if (self.session.selection) |path| self.session.nodeAt(path) else null;
        if (node) |item| {
            if (Session.isRequest(item.*)) {
                const request = postman.requestView(self.session.gpa, item.*) catch postman.RequestView{};
                defer self.session.gpa.free(request.headers);
                self.url_field.setText(request.url);
                self.body_field.setText(request.body);
            }
        }
    }

    // The editor's slice of the frame: what the selected request holds.
    pub fn snapshot(self: *Editor, u: *UiState, arena: Allocator) void {
        u.editor_tab = self.tab;
        const node = if (self.session.selection) |path| self.session.nodeAt(path) else null;
        if (node) |item| {
            if (Session.kind(item.*) != .request) return;
            const request = postman.requestView(arena, item.*) catch postman.RequestView{};
            u.method = request.method;
            u.url = request.url;
            u.body = request.body;
            u.header_count = request.headers.len;
            var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
            for (request.headers) |header| {
                header_rows.append(arena, .{ .name = header.key, .value = header.value }) catch break;
            }
            u.headers = header_rows.toOwnedSlice(arena) catch &.{};
        }
    }

    // Any click on a text field claims the keyboard; a click on the body gives it back to the editor.
    pub fn setFocus(self: *Editor, which: state_mod.Focus) void {
        self.session.focus = which;
        self.session.touch();
    }

    pub fn setTab(self: *Editor, tab: state_mod.Tab) void {
        self.tab = tab;
        self.session.focus = .none;
        self.session.touch();
    }

    // The name of a header field, so a click and a test can address one column of one row.
    pub fn fieldName(index: usize, value_side: bool) []const u8 {
        return if (value_side)
            glinlandui.props.Id.at(header_value_prefix, index).str()
        else
            glinlandui.props.Id.at(header_key_prefix, index).str();
    }

    pub fn setMethod(self: *Editor, method: []const u8) void {
        const node = self.session.selectedRequest() orelse return self.session.failNow("Select a request first, then pick a method.");
        postman.setMethod(self.session.doc_arena.allocator(), node, method) catch return self.session.failNow("Could not change the method.");
        self.session.commit();
    }

    pub fn onUrlChange(self: *Editor, url: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setUrl(self.session.doc_arena.allocator(), node, url) catch return self.session.failNow("Could not save the URL.");
        self.session.commit();
    }

    pub fn onHeaderKeyChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setHeaderKey(self.session.doc_arena.allocator(), node, index, text) catch return;
        self.session.commit();
    }

    pub fn onHeaderValueChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setHeaderValue(self.session.doc_arena.allocator(), node, index, text) catch return;
        self.session.commit();
    }

    pub fn addHeader(self: *Editor) void {
        const node = self.session.selectedRequest() orelse return self.session.failNow("Select a request first, then add a header.");
        if (postman.headerCount(node.*) >= state_mod.max_headers) {
            return self.session.fail("A request holds at most {d} headers.", .{state_mod.max_headers});
        }
        const index = postman.headerCount(node.*);
        postman.setHeaderKey(self.session.doc_arena.allocator(), node, index, "") catch return;
        postman.setHeaderValue(self.session.doc_arena.allocator(), node, index, "") catch return;
        self.session.commit();
        self.session.focus = .header_key;
        frame.setFocus(fieldName(index, false));
    }

    pub fn removeHeader(self: *Editor, index: usize) void {
        const node = self.session.selectedRequest() orelse return;
        postman.removeHeader(node, index);
        self.session.commit();
    }

    pub fn toggleHeader(self: *Editor, index: usize) void {
        const node = self.session.selectedRequest() orelse return;
        const disabled = postman.headerDisabled(node.*, index);
        postman.setHeaderEnabled(self.session.doc_arena.allocator(), node, index, disabled) catch return;
        self.session.commit();
    }

    pub fn setBody(self: *Editor, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setBodyRaw(self.session.doc_arena.allocator(), node, text) catch return;
        self.session.commit();
    }

    pub fn headerDisabled(self: *Editor, index: usize) bool {
        const node = self.session.selectedRequest() orelse return false;
        return postman.headerDisabled(node.*, index);
    }
};
