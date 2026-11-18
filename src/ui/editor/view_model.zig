//! The request editor's ViewModel: method, URL, headers, body. Edits land in the document, never in a copy.
const std = @import("std");
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;

const postman = @import("../../data/model/postman.zig");
const env_mod = @import("../../domain/env.zig");
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
// The Scripts tab: one multiline field per phase, the clip they scroll in, and the rail's two buttons.
pub const pre_field_id = "kurir.script.pre";
pub const post_field_id = "kurir.script.post";
pub const script_scroll_id = "kurir.script.scroll";
pub const phase_pre_id = "kurir.script.phase.pre";
pub const phase_post_id = "kurir.script.phase.post";
pub const header_key_prefix = "kurir.header.key";
pub const header_value_prefix = "kurir.header.value";
pub const part_key_prefix = "kurir.body.part.key";
pub const part_value_prefix = "kurir.body.part.value";
// The Vars tab: this request's own names and values, which no other request resolves.
pub const var_name_prefix = "kurir.var.name";
pub const var_value_prefix = "kurir.var.value";
// The mode and language selectors: each button's id, so a click and a test can address it by name.
pub const mode_prefix = "kurir.body.mode";
pub const language_prefix = "kurir.body.language";
pub const curl_copy_id = "kurir.curl.copy";

// The environment picker at the right of the request's row, and the two verbs its card always carries.
pub const env_trigger_id = "kurir.env.trigger";
pub const env_menu_id = "kurir.env.menu";
pub const env_menu_field_id = "kurir.env.field";
pub const env_menu_list_id = "kurir.env.menu.list";
pub const no_environment = "No environment";
pub const manage_environments = "Manage environments...";

pub const body_pad: f32 = 10;
pub const line_height: f32 = 20;

pub const Editor = struct {
    session: *Session = undefined,

    header_ctxs: [state_mod.max_headers * 2]HeaderCtx = undefined,

    // The two table modes edit one key/value row per part, with the same fields a header row uses.
    part_ctxs: [state_mod.max_body_parts * 2]PartCtx = undefined,

    // The request's own variables, one field per column of a row of the Vars tab.
    var_ctxs: [state_mod.max_vars * 2]VarCtx = undefined,

    // The Scripts tab's phase, and the rail's two buttons.
    script_phase: state_mod.ScriptPhase = .pre,
    phase_ctxs: [2]PhaseCtx = undefined,
    // What the last run said: its print lines merged onto one, and the line that stopped it when there was one.
    script_log: []const u8 = "",
    script_error: []const u8 = "",

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

    // A row of the Vars tab: this request's own variables, which nothing else resolves.
    pub const VarCtx = struct {
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

    // One of the Scripts tab's two phases: the rail's button and the field it shows.
    pub const PhaseCtx = struct {
        editor: *Editor,
        phase: state_mod.ScriptPhase,
    };

    // "Copy as cURL": the selected request as a command that reproduces it in a terminal.
    pub fn copyAsCurl(self: *Editor) void {
        const path = self.session.selection orelse return self.session.failNow("Select a request first, then copy it as cURL.");
        const node = self.session.nodeAt(path) orelse return self.session.failNow("That selection is gone. Select a request again.");
        if (!postman.isRequest(node.*)) return self.session.failNow("That is a folder or a collection. Select a request to copy as cURL.");
        const arena = self.session.docArena();
        const command = curl_transfer.command(arena, node.*) catch return self.session.failNow("This request cannot be written as a curl command.");
        // A shell knows nothing about `{{token}}`, so the command carries the values the variables hold.
        const text = env_mod.expand(arena, command, self.session.variableScope(arena)) catch command;
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

    pub fn onVarTyped(raw: ?*anyopaque, text: []const u8) void {
        const ctx: *VarCtx = @ptrCast(@alignCast(raw.?));
        ctx.editor.session.focus = .none;
        if (ctx.value_side) {
            ctx.editor.onVarValueChange(ctx.index, text);
        } else {
            ctx.editor.onVarNameChange(ctx.index, text);
        }
    }

    pub fn start(self: *Editor, session: *Session) void {
        self.session = session;

        var i: usize = 0;
        // The intents' contexts are built ONCE: a click is dispatched long after the frame that registered it.
        while (i < state_mod.max_headers) : (i += 1) {
            self.header_ctxs[i * 2] = .{ .editor = self, .index = i, .value_side = false };
            self.header_ctxs[i * 2 + 1] = .{ .editor = self, .index = i, .value_side = true };
        }

        // The part table is a header table over a different array: same columns, same contexts.
        i = 0;
        while (i < state_mod.max_body_parts) : (i += 1) {
            self.part_ctxs[i * 2] = .{ .editor = self, .index = i, .value_side = false };
            self.part_ctxs[i * 2 + 1] = .{ .editor = self, .index = i, .value_side = true };
        }

        // The Vars tab is the same two-column table again, over the request's own variables.
        i = 0;
        while (i < state_mod.max_vars) : (i += 1) {
            self.var_ctxs[i * 2] = .{ .editor = self, .index = i, .value_side = false };
            self.var_ctxs[i * 2 + 1] = .{ .editor = self, .index = i, .value_side = true };
        }

        // The selector's contexts are built once: a button's click is dispatched long after the declare.
        for (modes, 0..) |mode, index| self.mode_ctxs[index] = .{ .editor = self, .mode = mode };
        for (state_mod.raw_languages, 0..) |language, index| self.language_ctxs[index] = .{ .editor = self, .language = language };

        self.phase_ctxs = .{ .{ .editor = self, .phase = .pre }, .{ .editor = self, .phase = .post } };
    }

    pub fn deinit(self: *Editor) void {
        self.clearScriptRun();
    }

    // Nothing is pushed into a field: the view declares the state's value every frame, and the field adopts it.
    pub fn load(self: *Editor) void {
        // A run belonged to the request that is no longer on screen.
        self.clearScriptRun();
    }

    // The editor's slice of the frame: what the selected request holds.
    pub fn snapshot(self: *Editor, u: *UiState, arena: Allocator) void {
        u.editor_tab = self.tab;
        u.method_open = self.menu_open;
        u.script_phase = self.script_phase;
        u.script_log = self.script_log;
        u.script_error = self.script_error;
        const node = if (self.session.selection) |path| self.session.nodeAt(path) else null;
        if (node) |item| {
            if (Session.kind(item.*) != .request) return;
            // The Scripts tab edits one phase at a time, so only that phase's text reaches the field.
            u.script_code = postman.scriptOf(item.*, if (self.script_phase == .pre) .pre else .post);
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

            // The request's own variables: the Vars tab edits them, and only this request resolves them.
            u.request_var_count = postman.varCount(item.*);
            var var_rows: std.ArrayList(state_mod.PairRow) = .empty;
            var var_index: usize = 0;
            while (var_index < u.request_var_count) : (var_index += 1) {
                const pair = postman.varAt(item.*, var_index);
                var_rows.append(arena, .{ .name = pair.name, .value = pair.value }) catch break;
            }
            u.request_vars = var_rows.toOwnedSlice(arena) catch &.{};
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

    // The Scripts tab's rail: which phase the code field edits.
    pub fn setPhase(self: *Editor, phase: state_mod.ScriptPhase) void {
        self.script_phase = phase;
        self.session.focus = .none;
        self.session.touch();
    }

    // Typing writes the script into the request: a script is document data, saved with Ctrl/Cmd+S like the body.
    pub fn setScript(self: *Editor, phase: state_mod.ScriptPhase, source: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        const kind: postman.ScriptKind = if (phase == .pre) .pre else .post;
        postman.setScript(self.session.doc_arena.allocator(), node, kind, source) catch return;
        self.session.commit();
    }

    // What a run said: one line of print output, and the line that stopped it when there was one.
    pub fn recordScriptRun(self: *Editor, log: []const u8, failure: []const u8) void {
        const gpa = self.session.gpa;
        self.clearScriptRun();
        self.script_log = if (log.len > 0) gpa.dupe(u8, log) catch "" else "";
        self.script_error = if (failure.len > 0) gpa.dupe(u8, failure) catch "" else "";
        self.session.touch();
    }

    // The record belongs to the request on screen: a new selection, or a new run, starts from nothing.
    pub fn clearScriptRun(self: *Editor) void {
        const gpa = self.session.gpa;
        if (self.script_log.len > 0) gpa.free(self.script_log);
        if (self.script_error.len > 0) gpa.free(self.script_error);
        self.script_log = "";
        self.script_error = "";
    }

    pub fn onPreTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.setScript(.pre, text);
    }

    pub fn onPostTyped(raw: ?*anyopaque, text: []const u8) void {
        const self: *Editor = @ptrCast(@alignCast(raw.?));
        self.setScript(.post, text);
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

    // ---- the request's own variables (the Vars tab) ---------------------------------------------------------

    pub fn addRequestVar(self: *Editor) void {
        const node = self.session.selectedRequest() orelse return self.session.failNow("Select a request first, then add a variable.");
        if (postman.varCount(node.*) >= state_mod.max_vars) {
            return self.session.fail("This request holds at most {d} variables.", .{state_mod.max_vars});
        }
        const index = postman.addVar(self.session.docArena(), node) catch return;
        self.session.commit();
        frame.setFocus(varFieldName(index, false));
    }

    pub fn removeRequestVar(self: *Editor, index: usize) void {
        const node = self.session.selectedRequest() orelse return;
        postman.removeVar(node, index);
        self.session.commit();
    }

    pub fn onVarNameChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setVarName(self.session.docArena(), node, index, text) catch return;
        self.session.commit();
    }

    pub fn onVarValueChange(self: *Editor, index: usize, text: []const u8) void {
        const node = self.session.selectedRequest() orelse return;
        postman.setVarValue(self.session.docArena(), node, index, text) catch return;
        self.session.commit();
    }

    // The name of a Vars row's column, so a click and a test can address it.
    pub fn varFieldName(index: usize, value_side: bool) []const u8 {
        return if (value_side)
            glinlandui.props.Id.at(var_value_prefix, index).str()
        else
            glinlandui.props.Id.at(var_name_prefix, index).str();
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
