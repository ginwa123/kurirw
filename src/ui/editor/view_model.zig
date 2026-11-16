//! The request editor's ViewModel: method, URL, headers, body. Edits land in the document, never in a copy.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const frame = glinlandui.frame;

const postman = @import("../../data/model/postman.zig");
const curl_transfer = @import("../../domain/usecase/curl_transfer.zig");
const state_mod = @import("../../ui/state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const UiState = state_mod.UiState;
const Session = session_mod.Session;

pub const url_field_id = "kurir.url";
// The method menu: the trigger is the anchor the card attaches to, and the rows come from the list.
pub const method_trigger_id = "kurir.method";
pub const method_list_id = "kurir.method.options";
pub const method_menu_id = "kurir.method.menu";
pub const body_id = "kurir.body";
pub const body_scroll_id = "kurir.body.scroll";
pub const header_key_prefix = "kurir.header.key";
pub const header_value_prefix = "kurir.header.value";
pub const part_key_prefix = "kurir.body.part.key";
pub const part_value_prefix = "kurir.body.part.value";
// The mode and language selectors: each button's id, so a click and a test can address it by name.
pub const mode_prefix = "kurir.body.mode";
pub const language_prefix = "kurir.body.language";
pub const curl_copy_id = "kurir.curl.copy";

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

    // The two table modes edit one key/value row per part, with the same fields a header row uses.
    part_fields: [state_mod.max_body_parts * 2]input_mod.Field = undefined,
    part_ctxs: [state_mod.max_body_parts * 2]PartCtx = undefined,

    // The body mode selector and the raw language row: one context per button, so a click knows which one it hit.
    mode_ctxs: [modes.len]ModeCtx = undefined,
    language_ctxs: [state_mod.raw_languages.len]LanguageCtx = undefined,

    tab: state_mod.Tab = .headers,
    // The last command the copy button produced, kept so a test can read what the clipboard got.
    last_curl: []const u8 = "",
    // The method dropdown: the panel decides whether its card is declared, the toolkit draws it.
    menu_open: bool = false,

    // The four body modes in the order Postman's radio row shows them.
    pub const modes = [_]postman.BodyMode{ .none, .formdata, .urlencoded, .raw };

    pub const HeaderCtx = struct {
        editor: *Editor,
        index: usize,
        // True for the value column, false for the key column.
        value_side: bool,
    };

    // A part row's column, addressed the same way a header's is.
    pub const PartCtx = struct {
        editor: *Editor,
        index: usize,
        value_side: bool,
    };

    pub const ModeCtx = struct {
        editor: *Editor,
        mode: postman.BodyMode,
    };

    pub const LanguageCtx = struct {
        editor: *Editor,
        language: []const u8,
    };

    // "Copy as cURL": the selected request as a command that reproduces it in a terminal.
    pub fn copyAsCurl(self: *Editor) void {
        const path = self.session.selection orelse return self.session.failNow("Select a request first, then copy it as cURL.");
        const node = self.session.nodeAt(path) orelse return self.session.failNow("That selection is gone. Select a request again.");
        if (!postman.isRequest(node.*)) return self.session.failNow("That is a folder or a collection. Select a request to copy as cURL.");
        const arena = self.session.docArena();
        const text = curl_transfer.command(arena, node.*) catch return self.session.failNow("This request cannot be written as a curl command.");
        glinlandui.clipboard.write(text);
        self.last_curl = text;
        self.session.setStatus(false, "Copied as cURL ({d} bytes). Paste it anywhere a shell runs.", .{text.len});
        self.session.touch();
    }

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

    pub fn onPartTyped(raw: ?*anyopaque, text: []const u8) void {
        const ctx: *PartCtx = @ptrCast(@alignCast(raw.?));
        ctx.editor.session.focus = .body;
        if (ctx.value_side) {
            ctx.editor.onBodyPartValueChange(ctx.index, text);
        } else {
            ctx.editor.onBodyPartKeyChange(ctx.index, text);
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
        // The body scrolls with its caret: typing past the bottom edge follows the line, it does not hide it.
        self.body_field.scroll_id = body_scroll_id;
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

        // The part table is a header table over a different array: same fields, same two columns.
        i = 0;
        while (i < state_mod.max_body_parts) : (i += 1) {
            self.part_fields[i * 2] = session.fieldStyle(.at(part_key_prefix, i), @src());
            self.part_fields[i * 2].bind();
            self.part_fields[i * 2 + 1] = session.fieldStyle(.at(part_value_prefix, i), @src());
            self.part_fields[i * 2 + 1].bind();
            self.part_ctxs[i * 2] = .{ .editor = self, .index = i, .value_side = false };
            self.part_ctxs[i * 2 + 1] = .{ .editor = self, .index = i, .value_side = true };
            self.part_fields[i * 2].on_change = .{ .f = onPartTyped, .ctx = &self.part_ctxs[i * 2] };
            self.part_fields[i * 2 + 1].on_change = .{ .f = onPartTyped, .ctx = &self.part_ctxs[i * 2 + 1] };
        }

        // The selector's contexts are built once: a button's click is dispatched long after the declare.
        for (modes, 0..) |mode, index| self.mode_ctxs[index] = .{ .editor = self, .mode = mode };
        for (state_mod.raw_languages, 0..) |language, index| self.language_ctxs[index] = .{ .editor = self, .language = language };

        // The intents are set ONCE: a frame only hands each field the model's value.
        self.url_field.on_change = .{ .f = onUrlTyped, .ctx = self };
        self.url_field.on_focus = .{ .f = onUrlFocused, .ctx = self };
        self.body_field.on_change = .{ .f = onBodyTyped, .ctx = self };
        self.body_field.on_focus = .{ .f = onBodyFocused, .ctx = self };
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
                defer self.session.gpa.free(request.parts);
                self.url_field.setText(request.url);
                // The raw text is loaded whichever mode is selected, so switching to raw keeps what was typed.
                self.body_field.setText(postman.bodyRawText(item.*));
            }
        }
    }

    // The editor's slice of the frame: what the selected request holds.
    pub fn snapshot(self: *Editor, u: *UiState, arena: Allocator) void {
        u.editor_tab = self.tab;
        u.method_open = self.menu_open;
        const node = if (self.session.selection) |path| self.session.nodeAt(path) else null;
        if (node) |item| {
            if (Session.kind(item.*) != .request) return;
            const request = postman.requestView(arena, item.*) catch postman.RequestView{};
            u.method = request.method;
            u.url = request.url;
            u.body = postman.bodyRawText(item.*);
            u.body_mode = bodyModeOf(item.*, request);
            u.body_language = request.body_language;
            u.body_part_count = request.parts.len;
            var part_rows: std.ArrayList(state_mod.BodyPartRow) = .empty;
            for (request.parts) |row| {
                part_rows.append(arena, .{ .key = row.key, .value = row.value, .disabled = row.disabled }) catch break;
            }
            u.body_parts = part_rows.toOwnedSlice(arena) catch &.{};
            u.header_count = request.headers.len;
            var header_rows: std.ArrayList(state_mod.HeaderRow) = .empty;
            for (request.headers) |header| {
                header_rows.append(arena, .{ .name = header.key, .value = header.value }) catch break;
            }
            u.headers = header_rows.toOwnedSlice(arena) catch &.{};
        }
    }

    // The mode the document is in; raw text with NO mode at all is an old file, and it edits as raw.
    fn bodyModeOf(item: postman.Value, request: postman.RequestView) postman.BodyMode {
        if (request.body_mode.len == 0) return if (postman.bodyRawText(item).len > 0) .raw else .none;
        return postman.BodyMode.fromPostman(request.body_mode);
    }

    // The method dropdown's three intents: open or close it, and take a verb out of it.
    pub fn toggleMethods(self: *Editor) void {
        self.menu_open = !self.menu_open;
        self.session.touch();
    }

    pub fn closeMethods(self: *Editor) void {
        if (!self.menu_open) return;
        self.menu_open = false;
        self.session.touch();
    }

    pub fn pickMethod(self: *Editor, index: usize) void {
        if (index >= postman.methods.len) return;
        self.setMethod(postman.methods[index]);
    }

    // No scrim: the menu closes when the pointer leaves the trigger and the card as one box, so the gap is inside.
    pub fn closeIfPointerAway(self: *Editor) void {
        if (!self.menu_open) return;
        const trigger = frame.bounds(frame.clayId(method_trigger_id)) orelse return;
        const card = frame.bounds(frame.clayId(method_menu_id)) orelse return;
        const left = @min(trigger.x, card.x);
        const top = @min(trigger.y, card.y);
        const right = @max(trigger.x + trigger.width, card.x + card.width);
        const bottom = @max(trigger.y + trigger.height, card.y + card.height);
        if (frame.ptr_x < left or frame.ptr_x > right or frame.ptr_y < top or frame.ptr_y > bottom) {
            self.closeMethods();
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
        self.menu_open = false;
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
        // Typing writes the raw text only: the mode the request sends with is the selector's to change.
        postman.setRawText(self.session.doc_arena.allocator(), node, text) catch return;
        self.session.commit();
    }

    // The Body tab's mode selector: `body.mode` is what a send reads to decide the bytes and the Content-Type.
    pub fn setBodyMode(self: *Editor, mode: postman.BodyMode) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setBodyMode(self.session.doc_arena.allocator(), node, mode.postman()) catch return;
        self.session.commit();
    }

    // The raw body's language, which picks the Content-Type a raw send claims.
    pub fn setBodyLanguage(self: *Editor, language: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setBodyLanguage(self.session.doc_arena.allocator(), node, language) catch return;
        self.session.commit();
    }

    // "Prettify": the raw body re-indented as JSON, or a sentence saying why it cannot be.
    pub fn prettifyBody(self: *Editor) void {
        const node = self.session.selectedRequest() orelse return self.session.failNow("Select a request first, then prettify its body.");
        const text = postman.bodyRawText(node.*);
        if (text.len == 0) return self.session.failNow("This body is empty: there is nothing to prettify.");
        // The tree gets its own arena: a body that does not parse must not cost the document one.
        var tree = std.heap.ArenaAllocator.init(self.session.gpa);
        defer tree.deinit();
        const parsed = postman.parseTree(tree.allocator(), text) catch
            return self.session.failNow("This body is not valid JSON, so it cannot be prettified. Fix the syntax, or switch the mode away from raw.");
        const pretty = postman.write(self.session.docArena(), parsed, true) catch
            return self.session.failNow("Could not lay the body out as JSON.");
        postman.setRawText(self.session.doc_arena.allocator(), node, pretty) catch return;
        self.session.commit();
        self.session.setStatus(false, "Body prettified: {d} bytes.", .{pretty.len});
    }

    pub fn addBodyPart(self: *Editor) void {
        const node = self.session.selectedRequest() orelse return self.session.failNow("Select a request first, then add a row.");
        if (postman.bodyPartCount(node.*) >= state_mod.max_body_parts) {
            return self.session.fail("A {s} body holds at most {d} rows.", .{ postman.bodyMode(node.*), state_mod.max_body_parts });
        }
        const index = postman.addBodyPart(self.session.doc_arena.allocator(), node) catch return;
        self.session.commit();
        self.session.focus = .body;
        frame.setFocus(partFieldName(index, false));
    }

    pub fn removeBodyPart(self: *Editor, index: usize) void {
        const node = self.session.selectedRequest() orelse return;
        postman.removeBodyPart(node, index);
        self.session.commit();
    }

    pub fn toggleBodyPart(self: *Editor, index: usize) void {
        const node = self.session.selectedRequest() orelse return;
        const disabled = postman.bodyPartDisabled(node.*, index);
        postman.setBodyPartEnabled(self.session.doc_arena.allocator(), node, index, disabled) catch return;
        self.session.commit();
    }

    pub fn onBodyPartKeyChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setBodyPartKey(self.session.doc_arena.allocator(), node, index, text) catch return;
        self.session.commit();
    }

    pub fn onBodyPartValueChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setBodyPartValue(self.session.doc_arena.allocator(), node, index, text) catch return;
        self.session.commit();
    }

    pub fn bodyPartDisabled(self: *Editor, index: usize) bool {
        const node = self.session.selectedRequest() orelse return false;
        return postman.bodyPartDisabled(node.*, index);
    }

    // The name of a part field, so a click and a test can address one column of one row.
    pub fn partFieldName(index: usize, value_side: bool) []const u8 {
        return if (value_side)
            glinlandui.props.Id.at(part_value_prefix, index).str()
        else
            glinlandui.props.Id.at(part_key_prefix, index).str();
    }

    pub fn headerDisabled(self: *Editor, index: usize) bool {
        const node = self.session.selectedRequest() orelse return false;
        return postman.headerDisabled(node.*, index);
    }
};
