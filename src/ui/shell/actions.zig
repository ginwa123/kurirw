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
