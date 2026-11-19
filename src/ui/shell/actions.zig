//! Every click that reaches a ViewModel, in one place: the view declares, these raise the intent.
const glinlandui = @import("glinlandui");

const view_model = @import("../shell/view_model.zig");
const KurirViewModel = view_model.KurirViewModel;
const env_vm = @import("../env/view_model.zig");
const editor_vm = @import("../editor/view_model.zig");
const runner_vm = @import("../runner/view_model.zig");

pub fn onRow(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.onRowSelect(index);
}

pub fn onNewToggle(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.toggleNewMenu();
}

pub fn onNewPick(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickNewMenu(index);
}

pub fn onWsToggle(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.toggleWorkspaceMenu();
}

pub fn onWsPick(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickWorkspaceMenu(index);
}

pub fn onMethodToggle(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.toggleMethods();
}

// The dropdown hands back the row's index; the facade turns it into the verb.
pub fn onMethodPick(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickMethod(index);
}

pub fn onCopyCurl(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.copyAsCurl();
}

pub fn onSend(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.send();
}

pub fn onAddCollection(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addCollection();
}

pub fn onAddFolder(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addFolder();
}

pub fn onAddRequest(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addRequest();
}

pub fn onDelete(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.deleteSelected();
}

pub fn onAddWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addWorkspace();
}

pub fn onNextWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.nextWorkspace();
}

pub fn onDeleteWorkspace(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.deleteWorkspace();
}

pub fn onImport(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.importCollection();
}

pub fn onExport(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.exportSelected();
}

pub fn onAddHeader(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addHeader();
}

pub fn onRemoveHeader(ctx: ?*anyopaque) void {
    const header_ctx: *KurirViewModel.HeaderCtx = @ptrCast(@alignCast(ctx.?));
    header_ctx.editor.removeHeader(header_ctx.index);
}

pub fn onToggleHeader(ctx: ?*anyopaque) void {
    const header_ctx: *KurirViewModel.HeaderCtx = @ptrCast(@alignCast(ctx.?));
    header_ctx.editor.toggleHeader(header_ctx.index);
}

pub fn onHeadersTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.headers);
}

pub fn onBodyTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.body);
}

pub fn onVarsTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.vars);
}

pub fn onScriptsTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setEditorTab(.scripts);
}

// The Scripts tab's rail: the context is the button's own, built once on the panel.
pub fn onScriptPhase(ctx: ?*anyopaque) void {
    const phase_ctx: *KurirViewModel.PhaseCtx = @ptrCast(@alignCast(ctx.?));
    phase_ctx.editor.setPhase(phase_ctx.phase);
}

// The environments: the picker at the request's row, and the manager page it opens.
pub fn onEnvToggle(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.toggleEnvPicker();
}

pub fn onEnvPick(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickEnvironmentRow(index);
}

pub fn onEnvClose(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.closeEnvManager();
}

pub fn onEnvNew(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.addEnvironment();
}

// The pane's Delete: the environment itself goes, and the workspace keeps the rest.
pub fn onEnvRemove(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.removeEnvironment();
}

// A name in the manager's left list: an environment, or a collection whose own variables it shows.
pub fn onEnvSelect(ctx: ?*anyopaque) void {
    const list: *env_vm.Env.ListCtx = @ptrCast(@alignCast(ctx.?));
    list.env.select(list.group, list.index);
}

pub fn onEnvAddVariable(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.env.addVariable();
}

pub fn onEnvRemoveVariable(ctx: ?*anyopaque) void {
    const var_ctx: *env_vm.Env.VarCtx = @ptrCast(@alignCast(ctx.?));
    var_ctx.env.removeVariable(var_ctx.index);
}

pub fn onEnvToggleSecret(ctx: ?*anyopaque) void {
    const var_ctx: *env_vm.Env.VarCtx = @ptrCast(@alignCast(ctx.?));
    var_ctx.env.toggleSecret(var_ctx.index);
}

// The request's own variables, which only the Vars tab edits.
pub fn onAddRequestVar(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.editor.addRequestVar();
}

pub fn onRemoveRequestVar(ctx: ?*anyopaque) void {
    const var_ctx: *editor_vm.Editor.VarCtx = @ptrCast(@alignCast(ctx.?));
    var_ctx.editor.removeRequestVar(var_ctx.index);
}

pub fn onResponseBodyTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setResponseTab(.body);
}

pub fn onResponseHeadersTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setResponseTab(.headers);
}

pub fn onResponseHistoryTab(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.setResponseTab(.history);
}

// One history row: the context carries the result's serial, so an eviction cannot point it at another one.
pub fn onHistoryRow(ctx: ?*anyopaque) void {
    const click: *KurirViewModel.HistoryClick = @ptrCast(@alignCast(ctx.?));
    click.vm.pinHistory(click.serial);
}

// The Body tab's mode selector: the context is the button's own, built once on the panel.
pub fn onBodyMode(ctx: ?*anyopaque) void {
    const mode_ctx: *KurirViewModel.BodyModeCtx = @ptrCast(@alignCast(ctx.?));
    mode_ctx.editor.setBodyMode(mode_ctx.mode);
}

pub fn onBodyLanguage(ctx: ?*anyopaque) void {
    const language_ctx: *KurirViewModel.BodyLanguageCtx = @ptrCast(@alignCast(ctx.?));
    language_ctx.editor.setBodyLanguage(language_ctx.language);
}

pub fn onAddBodyPart(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.editor.addBodyPart();
}

pub fn onQuitAction(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickQuitAction(index);
}

pub fn onPickTab(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickTab(index);
}

pub fn onCloseTab(ctx: ?*anyopaque, index: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.closeTab(index);
}

// The card a tab raises: the engine names the action, the model decides what it means.
pub fn onPickTabMenu(ctx: ?*anyopaque, index: usize, action: glinlandui.components.tabs.Action) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pickTabMenu(index, action);
}

// A tab dragged onto another: the bar keeps the order the model holds.
pub fn onMoveTab(ctx: ?*anyopaque, from: usize, to: usize) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.moveTab(from, to);
}

pub fn onPrettifyBody(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.editor.prettifyBody();
}

pub fn onRemoveBodyPart(ctx: ?*anyopaque) void {
    const part_ctx: *KurirViewModel.BodyPartCtx = @ptrCast(@alignCast(ctx.?));
    part_ctx.editor.removeBodyPart(part_ctx.index);
}

pub fn onToggleBodyPart(ctx: ?*anyopaque) void {
    const part_ctx: *KurirViewModel.BodyPartCtx = @ptrCast(@alignCast(ctx.?));
    part_ctx.editor.toggleBodyPart(part_ctx.index);
}

// ---- the runner page -----------------------------------------------------------------------------------

pub fn onRunnerRun(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerRun();
}

pub fn onRunnerStop(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerStop();
}

pub fn onRunnerClose(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerClose();
}

pub fn onRunnerData(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerToggleCode();
}

pub fn onRunnerAddSend(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerAddSend();
}

pub fn onRunnerAddTest(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerAddTest();
}

// FLOW shows the spec's tests by name, or the spec itself.
pub fn onRunnerCode(ctx: ?*anyopaque) void {
    const vm: *KurirViewModel = @ptrCast(@alignCast(ctx.?));
    vm.runnerToggleCode();
}
