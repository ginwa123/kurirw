//! The Env panel: the workspace's environments, which one is active, and the manager that edits them.
const std = @import("std");
const glinlandui = @import("glinlandui");
const InputField = glinlandui.components.input.Field;
const props = glinlandui.props;

const env = @import("../../domain/env.zig");
const store = @import("../../data/local/workspace_store.zig");
const local_env = @import("../../data/local/env_store.zig");
const postman = @import("../../data/model/postman.zig");
const state_mod = @import("../state.zig");
const session_mod = @import("../shell/session.zig");

const Allocator = std.mem.Allocator;
const Session = session_mod.Session;
const UiState = state_mod.UiState;
const Variable = env.Variable;

// How many rows the manager's two lists can draw: the environments, and the workspace's collections.
const max_list: usize = 32;

pub const picker_trigger_id = "kurir.env.picker";
pub const picker_list_id = "kurir.env.picker.list";
pub const picker_menu_id = "kurir.env.picker.menu";
pub const manager_id = "kurir.env.manager";
pub const close_id = "kurir.env.close";
pub const new_id = "kurir.env.new";
pub const delete_id = "kurir.env.delete";
pub const add_variable_id = "kurir.env.addvar";
pub const name_prefix = "kurir.env.name";
pub const initial_prefix = "kurir.env.initial";
pub const current_prefix = "kurir.env.current";
pub const secret_prefix = "kurir.env.secret";
// The environment's own name, which the right pane edits: a rename is not a new environment.
pub const env_name_id = "kurir.env.rename";
pub const env_row_prefix = "kurir.env.row";
pub const collection_row_prefix = "kurir.env.collection";

// One environment: the name the picker shows, and the variables it holds.
const Environment = struct {
    name: []const u8 = "",
    vars: std.ArrayList(Variable) = .empty,
};

// One workspace's environments, with the one that sends.
const Set = struct {
    workspace_id: []const u8 = "",
    active: []const u8 = "",
    environments: std.ArrayList(Environment) = .empty,
};

pub const Env = struct {
    session: *Session = undefined,
    path: []const u8 = "",
    // Every workspace's environments, loaded once: the panel shows the one on screen and writes them all back.
    sets: std.ArrayList(Set) = .empty,
    current: ?usize = null,
    // The manager, and which kind of green its right pane is listing.
    manager: bool = false,
    group: state_mod.EnvGroup = .environment,
    selected: usize = 0,
    collection: usize = 0,
    // The picker under its trigger.
    picker: bool = false,
    name_fields: [state_mod.max_env_vars]InputField = undefined,
    initial_fields: [state_mod.max_env_vars]InputField = undefined,
    current_fields: [state_mod.max_env_vars]InputField = undefined,
    var_ctxs: [state_mod.max_env_vars * 3]VarCtx = undefined,
    // The name of the environment the right pane is editing, drawn as the pane's title.
    name_field: InputField = undefined,
    name_ctx: NameCtx = undefined,
    env_ctxs: [max_list]ListCtx = undefined,
    collection_ctxs: [max_list]ListCtx = undefined,

    pub const VarCtx = struct {
        env: *Env,
        index: usize,
        field: Field,
    };

    // Which of a row's three columns a keystroke came from.
    pub const Field = enum { name, initial, current };

    // The right pane's title field: renaming the environment it is showing.
    pub const NameCtx = struct {
        env: *Env,
    };

    pub const ListCtx = struct {
        env: *Env,
        index: usize,
        // Which list the row belongs to: the environments, or the workspace's collections.
        group: state_mod.EnvGroup = .environment,
    };

    pub fn start(self: *Env, session: *Session, path: []const u8) void {
        self.session = session;
        self.path = path;
        var i: usize = 0;
        while (i < state_mod.max_env_vars) : (i += 1) {
            self.name_fields[i] = session.fieldStyle(.at(name_prefix, i), @src());
            self.name_fields[i].bind();
            self.initial_fields[i] = session.fieldStyle(.at(initial_prefix, i), @src());
            self.initial_fields[i].bind();
            self.current_fields[i] = session.fieldStyle(.at(current_prefix, i), @src());
            self.current_fields[i].bind();
            self.var_ctxs[i * 3] = .{ .env = self, .index = i, .field = .name };
            self.var_ctxs[i * 3 + 1] = .{ .env = self, .index = i, .field = .initial };
            self.var_ctxs[i * 3 + 2] = .{ .env = self, .index = i, .field = .current };
            self.name_fields[i].on_change = .{ .f = onTyped, .ctx = &self.var_ctxs[i * 3] };
            self.initial_fields[i].on_change = .{ .f = onTyped, .ctx = &self.var_ctxs[i * 3 + 1] };
            self.current_fields[i].on_change = .{ .f = onTyped, .ctx = &self.var_ctxs[i * 3 + 2] };
        }
        i = 0;
        while (i < max_list) : (i += 1) {
            self.env_ctxs[i] = .{ .env = self, .index = i, .group = .environment };
            self.collection_ctxs[i] = .{ .env = self, .index = i, .group = .collection };
        }
        self.name_field = session.fieldStyle(.{ .text = env_name_id }, @src());
        self.name_field.bind();
        self.name_ctx = .{ .env = self };
        self.name_field.on_change = .{ .f = onNameTyped, .ctx = &self.name_ctx };
        self.restore();
        self.follow();
    }

    // Read the file into our own memory: the panel owns these strings, so an edit never borrows an arena.
    fn restore(self: *Env) void {
        if (self.path.len == 0) return;
        const restored = local_env.load(self.session.docArena(), self.session.io, self.path);
        const gpa = self.session.gpa;
        for (restored.groups) |group| {
            var set = Set{
                .workspace_id = gpa.dupe(u8, group.workspace_id) catch continue,
                .active = gpa.dupe(u8, group.active) catch "",
            };
            for (group.environments) |source| {
                var environment = Environment{ .name = gpa.dupe(u8, source.name) catch continue };
                for (source.vars) |source_var| {
                    environment.vars.append(gpa, .{
                        .name = gpa.dupe(u8, source_var.name) catch continue,
                        .initial = gpa.dupe(u8, source_var.initial) catch continue,
                        .current = gpa.dupe(u8, source_var.current) catch continue,
                        .secret = source_var.secret,
                    }) catch break;
                }
                set.environments.append(gpa, environment) catch {
                    freeEnvironment(gpa, &environment);
                    break;
                };
            }
            self.sets.append(gpa, set) catch {
                for (set.environments.items) |*environment| freeEnvironment(gpa, environment);
                set.environments.deinit(gpa);
                gpa.free(set.workspace_id);
                if (set.active.len > 0) gpa.free(set.active);
                break;
            };
        }
    }

    pub fn deinit(self: *Env) void {
        const gpa = self.session.gpa;
        for (self.sets.items) |*set| {
            for (set.environments.items) |*environment| freeEnvironment(gpa, environment);
            set.environments.deinit(gpa);
            gpa.free(set.workspace_id);
            if (set.active.len > 0) gpa.free(set.active);
        }
        self.sets.deinit(gpa);
        for (&self.name_fields) |*field| field.deinit();
        for (&self.initial_fields) |*field| field.deinit();
        for (&self.current_fields) |*field| field.deinit();
        self.name_field.deinit();
        self.* = undefined;
    }

    // ---- the workspace on screen ----------------------------------------------------------------------------

    fn live(self: *Env) ?*Set {
        self.follow();
        const index = self.current orelse return null;
        return &self.sets.items[index];
    }

    // The set that belongs to the workspace on screen; a workspace nobody has typed in starts with none.
    fn follow(self: *Env) void {
        const id = self.session.workspaceId();
        if (self.current) |index| {
            if (index < self.sets.items.len and std.mem.eql(u8, self.sets.items[index].workspace_id, id)) return;
        }
        for (self.sets.items, 0..) |set, index| {
            if (std.mem.eql(u8, set.workspace_id, id)) {
                self.current = index;
                return;
            }
        }
        const gpa = self.session.gpa;
        self.sets.append(gpa, .{ .workspace_id = gpa.dupe(u8, id) catch "" }) catch {
            self.current = null;
            return;
        };
        self.current = self.sets.items.len - 1;
    }

    // The environment that sends, or null when the workspace has none active.
    pub fn active(self: *Env) ?*Environment {
        const set = if (self.current) |index| &self.sets.items[index] else return null;
        if (set.active.len == 0) return null;
        for (set.environments.items) |*environment| {
            if (std.mem.eql(u8, environment.name, set.active)) return environment;
        }
        return null;
    }

    // What the send rule and the Vars tab resolve against: the active environment's variables, borrowed.
    pub fn activeVars(self: *Env) []const Variable {
        const environment = self.active() orelse return &.{};
        return environment.vars.items;
    }

    pub fn count(self: *Env) usize {
        const set = self.live() orelse return 0;
        return set.environments.items.len;
    }

    pub fn nameAt(self: *Env, index: usize) []const u8 {
        const set = self.live() orelse return "";
        if (index >= set.environments.items.len) return "";
        return set.environments.items[index].name;
    }

    // One row of the picker's card: an environment, then "No environment", then the manager.
    pub fn pickRow(self: *Env, row: usize) void {
        const total = self.count();
        if (row < total) return self.pickActive(self.nameAt(row));
        if (row == total) return self.pickActive("");
        return self.openManager();
    }

    // A name in the manager's left list: an environment, or a collection whose own variables it shows.
    pub fn select(self: *Env, group: state_mod.EnvGroup, index: usize) void {
        switch (group) {
            .environment => self.selectEnvironment(index),
            .collection => self.selectCollection(index),
        }
    }

    // ---- the picker under the trigger -----------------------------------------------------------------------

    pub fn togglePicker(self: *Env) void {
        self.picker = !self.picker;
        self.session.touch();
    }

    pub fn closePicker(self: *Env) void {
        self.picker = false;
        self.session.touch();
    }

    // The menu's rows: the environments, then "No environment", then the manager. An empty name means none.
    pub fn pickActive(self: *Env, name: []const u8) void {
        const set = self.live() orelse return;
        const gpa = self.session.gpa;
        const copy = if (name.len == 0) "" else gpa.dupe(u8, name) catch return;
        if (set.active.len > 0) gpa.free(set.active);
        set.active = copy;
        self.picker = false;
        self.save();
        self.session.setStatus(false, "Sending with {s}.", .{if (name.len > 0) name else "no environment"});
        self.session.touch();
    }

    // ---- the manager -----------------------------------------------------------------------------------------

    pub fn openManager(self: *Env) void {
        self.manager = true;
        self.picker = false;
        self.session.touch();
    }

    pub fn closeManager(self: *Env) void {
        self.manager = false;
        self.session.touch();
    }

    pub fn showEnvironments(self: *Env) void {
        self.group = .environment;
        self.session.touch();
    }

    pub fn selectEnvironment(self: *Env, index: usize) void {
        const set = self.live() orelse return;
        if (index >= set.environments.items.len) return;
        self.group = .environment;
        self.selected = index;
        self.session.touch();
    }

    pub fn selectCollection(self: *Env, index: usize) void {
        self.group = .collection;
        self.collection = index;
        self.session.touch();
    }

    pub fn addEnvironment(self: *Env) void {
        const set = self.live() orelse return;
        if (set.environments.items.len >= state_mod.max_environments) {
            self.session.failNow("This is the last environment slot. Remove one before adding another.");
            return;
        }
        const gpa = self.session.gpa;
        const name = std.fmt.allocPrint(gpa, "Environment {d}", .{set.environments.items.len + 1}) catch return;
        set.environments.append(gpa, .{ .name = name }) catch {
            gpa.free(name);
            return;
        };
        self.group = .environment;
        self.selected = set.environments.items.len - 1;
        // The first environment a workspace gets is the one it sends with, unless one is already active.
        if (set.active.len == 0) set.active = gpa.dupe(u8, name) catch "";
        self.save();
        self.session.touch();
    }

    // The environment the right pane is editing: the selected one of the selected workspace.
    fn selectedEnvironment(self: *Env) ?*Environment {
        const set = self.live() orelse return null;
        if (self.selected >= set.environments.items.len) return null;
        return &set.environments.items[self.selected];
    }

    pub fn addVariable(self: *Env) void {
        if (self.group == .collection) return self.addCollectionVar();
        const environment = self.selectedEnvironment() orelse return;
        if (environment.vars.items.len >= state_mod.max_env_vars) {
            self.session.failNow("This is the last variable slot. Remove one before adding another.");
            return;
        }
        environment.vars.append(self.session.gpa, .{}) catch return;
        self.save();
        glinlandui.frame.setFocus(props.Id.at(name_prefix, environment.vars.items.len - 1).str());
        self.session.touch();
    }

    pub fn removeVariable(self: *Env, index: usize) void {
        if (self.group == .collection) return self.removeCollectionVar(index);
        const environment = self.selectedEnvironment() orelse return;
        if (index >= environment.vars.items.len) return;
        const gpa = self.session.gpa;
        freeVariable(gpa, &environment.vars.items[index]);
        _ = environment.vars.orderedRemove(index);
        self.save();
        self.session.touch();
    }

    pub fn setVariable(self: *Env, index: usize, field: Field, text: []const u8) void {
        if (self.group == .collection) {
            return switch (field) {
                .name => self.setCollectionVarName(index, text),
                .initial, .current => self.setCollectionVarValue(index, text),
            };
        }
        const environment = self.selectedEnvironment() orelse return;
        if (index >= environment.vars.items.len) return;
        const gpa = self.session.gpa;
        const copy = gpa.dupe(u8, text) catch return;
        const variable = &environment.vars.items[index];
        switch (field) {
            .name => {
                gpa.free(variable.name);
                variable.name = copy;
            },
            .initial => {
                gpa.free(variable.initial);
                variable.initial = copy;
            },
            .current => {
                gpa.free(variable.current);
                variable.current = copy;
            },
        }
        self.save();
        self.session.touch();
    }

    pub fn toggleSecret(self: *Env, index: usize) void {
        const environment = self.selectedEnvironment() orelse return;
        if (index >= environment.vars.items.len) return;
        environment.vars.items[index].secret = !environment.vars.items[index].secret;
        self.save();
        self.session.touch();
    }

    // Deleting the environment the manager shows: the workspace keeps the rest, and nothing else sends with it.
    pub fn removeSelected(self: *Env) void {
        const set = self.live() orelse return;
        if (self.selected >= set.environments.items.len) return;
        const gpa = self.session.gpa;
        const environment = &set.environments.items[self.selected];
        // The environment that sent is the one going, so the window sends with none until another is picked.
        if (set.active.len > 0 and std.mem.eql(u8, set.active, environment.name)) {
            gpa.free(set.active);
            set.active = "";
        }
        freeEnvironment(gpa, environment);
        _ = set.environments.orderedRemove(self.selected);
        if (self.selected >= set.environments.items.len and self.selected > 0) self.selected -= 1;
        self.save();
        self.session.setStatus(false, "Environment deleted. The others are untouched.", .{});
        self.session.touch();
    }

    // A rename keeps everything the environment holds, and the active mark follows it to the new name.
    pub fn renameSelected(self: *Env, text: []const u8) void {
        const set = self.live() orelse return;
        if (self.selected >= set.environments.items.len) return;
        const gpa = self.session.gpa;
        const environment = &set.environments.items[self.selected];
        if (std.mem.eql(u8, environment.name, text)) return;
        const copy = gpa.dupe(u8, text) catch return;
        if (set.active.len > 0 and std.mem.eql(u8, set.active, environment.name)) {
            const fresh = gpa.dupe(u8, text) catch "";
            gpa.free(set.active);
            set.active = fresh;
        }
        gpa.free(environment.name);
        environment.name = copy;
        self.save();
        self.session.touch();
    }

    // ---- a collection's own variables: they belong to the document, so an edit marks it unsaved ------------

    fn collectionValue(self: *Env) ?*postman.Value {
        self.follow();
        return store.collectionPtr(&self.session.doc, self.session.workspace, self.collection);
    }

    pub fn addCollectionVar(self: *Env) void {
        const collection = self.collectionValue() orelse return;
        if (postman.varCount(collection.*) >= state_mod.max_vars) return;
        _ = postman.addVar(self.session.docArena(), collection) catch return;
        self.session.commit();
        self.session.touch();
    }

    pub fn removeCollectionVar(self: *Env, index: usize) void {
        const collection = self.collectionValue() orelse return;
        postman.removeVar(collection, index);
        self.session.commit();
        self.session.touch();
    }

    pub fn setCollectionVarName(self: *Env, index: usize, text: []const u8) void {
        const collection = self.collectionValue() orelse return;
        postman.setVarName(self.session.docArena(), collection, index, text) catch return;
        self.session.commit();
        self.session.touch();
    }

    pub fn setCollectionVarValue(self: *Env, index: usize, text: []const u8) void {
        const collection = self.collectionValue() orelse return;
        postman.setVarValue(self.session.docArena(), collection, index, text) catch return;
        self.session.commit();
        self.session.touch();
    }

    // ---- the file, and the frame -----------------------------------------------------------------------------

    // Every edit is written straight away: an environment is configuration, not an unsaved document.
    fn save(self: *Env) void {
        // The send rule borrows the active environment's slice, and an append may have just moved it.
        self.session.env_vars = self.activeVars();
        if (self.path.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.session.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var groups: std.ArrayList(local_env.Group) = .empty;
        for (self.sets.items) |set| {
            var environments: std.ArrayList(local_env.EnvironmentGroup) = .empty;
            for (set.environments.items) |environment| {
                environments.append(arena, .{ .name = environment.name, .vars = environment.vars.items }) catch break;
            }
            groups.append(arena, .{
                .workspace_id = set.workspace_id,
                .active = set.active,
                .environments = environments.items,
            }) catch break;
        }
        local_env.save(arena, self.session.io, self.path, groups.items) catch {
            self.session.setStatus(true, "Could not save the environment file.", .{});
        };
    }

    pub fn snapshot(self: *Env, u: *UiState, arena: Allocator) void {
        self.follow();
        const set = if (self.current) |index| &self.sets.items[index] else null;
        u.env_manager = self.manager;
        u.env_group = self.group;
        u.env_menu = self.picker;
        u.env_active = if (set) |live_set| live_set.active else "";

        var names: std.ArrayList([]const u8) = .empty;
        if (set) |live_set| {
            for (live_set.environments.items) |environment| {
                names.append(arena, environment.name) catch break;
            }
        }
        u.env_names = names.toOwnedSlice(arena) catch &.{};

        // The workspace's collections, so the manager can list their variables beside the environments.
        var collections: std.ArrayList([]const u8) = .empty;
        var index: usize = 0;
        const collection_count = store.collectionCount(self.session.doc, self.session.workspace);
        while (index < collection_count and index < max_list) : (index += 1) {
            const collection = store.collectionAt(self.session.doc, self.session.workspace, index) orelse continue;
            collections.append(arena, postman.str(collection, "name")) catch break;
        }
        u.collection_names = collections.toOwnedSlice(arena) catch &.{};
        if (self.collection >= u.collection_names.len) self.collection = 0;
        u.collection_selected = self.collection;
        if (self.selected >= u.env_names.len) self.selected = 0;
        u.env_selected = self.selected;

        var rows: std.ArrayList(state_mod.EnvRow) = .empty;
        var pairs: std.ArrayList(state_mod.PairRow) = .empty;
        if (self.group == .environment) {
            if (self.selectedEnvironment()) |environment| {
                for (environment.vars.items) |variable| {
                    rows.append(arena, .{
                        .name = variable.name,
                        .initial = variable.initial,
                        .current = variable.current,
                        .secret = variable.secret,
                    }) catch break;
                }
            }
        } else if (self.collectionValue()) |collection| {
            index = 0;
            while (index < postman.varCount(collection.*)) : (index += 1) {
                const pair = postman.varAt(collection.*, index);
                pairs.append(arena, .{ .name = pair.name, .value = pair.value }) catch break;
            }
        }
        u.env_rows = rows.toOwnedSlice(arena) catch &.{};
        u.env_count = u.env_rows.len;
        u.pair_rows = pairs.toOwnedSlice(arena) catch &.{};
        u.pair_count = u.pair_rows.len;
    }
};

fn freeVariable(gpa: Allocator, variable: *Variable) void {
    gpa.free(variable.name);
    gpa.free(variable.initial);
    gpa.free(variable.current);
}

fn freeEnvironment(gpa: Allocator, environment: *Environment) void {
    for (environment.vars.items) |*variable| freeVariable(gpa, variable);
    environment.vars.deinit(gpa);
    gpa.free(environment.name);
}

fn onTyped(raw: ?*anyopaque, text: []const u8) void {
    const ctx: *Env.VarCtx = @ptrCast(@alignCast(raw.?));
    ctx.env.setVariable(ctx.index, ctx.field, text);
}

fn onNameTyped(raw: ?*anyopaque, text: []const u8) void {
    const ctx: *Env.NameCtx = @ptrCast(@alignCast(raw.?));
    ctx.env.renameSelected(text);
}
