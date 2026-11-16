//! Every click that reaches a ViewModel, in one place: the view declares, these raise the intent.

const view_model = @import("../shell/view_model.zig");
const KurirViewModel = view_model.KurirViewModel;

pub fn onRow(vm: *KurirViewModel, index: usize) void {
    vm.onRowSelect(index);
}

pub fn onNewToggle(vm: *KurirViewModel) void {
    vm.toggleNewMenu();
}

pub fn onNewPick(vm: *KurirViewModel, index: usize) void {
    vm.pickNewMenu(index);
}

pub fn onWsToggle(vm: *KurirViewModel) void {
    vm.toggleWorkspaceMenu();
}

pub fn onWsPick(vm: *KurirViewModel, index: usize) void {
    vm.pickWorkspaceMenu(index);
}

pub fn onMethodToggle(vm: *KurirViewModel) void {
    vm.toggleMethods();
}

// The dropdown hands back the row's index; the facade turns it into the verb.
pub fn onMethodPick(vm: *KurirViewModel, index: usize) void {
    vm.pickMethod(index);
}

pub fn onCopyCurl(vm: *KurirViewModel) void {
    vm.copyAsCurl();
}

pub fn onSend(vm: *KurirViewModel) void {
    vm.send();
}

pub fn onAddCollection(vm: *KurirViewModel) void {
    vm.addCollection();
}

pub fn onAddFolder(vm: *KurirViewModel) void {
    vm.addFolder();
}

pub fn onAddRequest(vm: *KurirViewModel) void {
    vm.addRequest();
}

pub fn onDelete(vm: *KurirViewModel) void {
    vm.deleteSelected();
}

pub fn onAddWorkspace(vm: *KurirViewModel) void {
    vm.addWorkspace();
}

pub fn onNextWorkspace(vm: *KurirViewModel) void {
    vm.nextWorkspace();
}

pub fn onDeleteWorkspace(vm: *KurirViewModel) void {
    vm.deleteWorkspace();
}

pub fn onImport(vm: *KurirViewModel) void {
    vm.importCollection();
}

pub fn onExport(vm: *KurirViewModel) void {
    vm.exportSelected();
}

pub fn onAddHeader(vm: *KurirViewModel) void {
    vm.addHeader();
}

pub fn onRemoveHeader(header_ctx: *KurirViewModel.HeaderCtx) void {
    header_ctx.editor.removeHeader(header_ctx.index);
}

pub fn onToggleHeader(header_ctx: *KurirViewModel.HeaderCtx) void {
    header_ctx.editor.toggleHeader(header_ctx.index);
}

pub fn onHeadersTab(vm: *KurirViewModel) void {
    vm.setEditorTab(.headers);
}

pub fn onBodyTab(vm: *KurirViewModel) void {
    vm.setEditorTab(.body);
}

pub fn onResponseBodyTab(vm: *KurirViewModel) void {
    vm.setResponseTab(.body);
}

pub fn onResponseHeadersTab(vm: *KurirViewModel) void {
    vm.setResponseTab(.headers);
}
