//! Every click that reaches a ViewModel, in one place: the view declares, these raise the intent.
const glinlandui = @import("glinlandui");

const view_model = @import("../shell/view_model.zig");
const KurirViewModel = view_model.KurirViewModel;

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
