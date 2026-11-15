//! Kurir as a MODULE: `@import("kurirw")` is the whole app — its state, its intents, its view, and its window.
pub const app = @import("app.zig");
pub const view = @import("ui/shell/screen.zig");
pub const view_model = @import("ui/shell/view_model.zig");
pub const state = @import("ui/state.zig");
pub const theme = @import("ui/theme/theme.zig");
pub const postman = @import("data/model/postman.zig");
pub const store = @import("data/local/workspace_store.zig");
pub const http = @import("data/remote/http_client.zig");
pub const workspace = @import("domain/repository/workspace.zig");
pub const file_store = @import("data/repository/workspace_impl.zig");
pub const send_request = @import("domain/usecase/send_request.zig");
pub const import_collection = @import("domain/usecase/import_collection.zig");
pub const export_collection = @import("domain/usecase/export_collection.zig");
pub const container = @import("di/container.zig");

// Every file's own tests, collected without adding an anonymous one, so the suite counts real tests.
comptime {
    _ = @import("ui/state.zig");
    _ = @import("ui/theme/theme.zig");
    _ = @import("data/model/postman.zig");
    _ = @import("data/local/workspace_store.zig");
    _ = @import("data/remote/http_client.zig");
    _ = @import("ui/shell/view_model.zig");
    _ = @import("ui/shell/screen.zig");
    _ = @import("ui/shell/scope.zig");
    _ = @import("ui/shell/widgets.zig");
    _ = @import("ui/shell/actions.zig");
    _ = @import("ui/sidebar/screen.zig");
    _ = @import("ui/editor/screen.zig");
    _ = @import("ui/response/screen.zig");
    _ = @import("app.zig");
    _ = @import("ui/shell/session.zig");
    _ = @import("ui/sidebar/view_model.zig");
    _ = @import("ui/editor/view_model.zig");
    _ = @import("ui/response/view_model.zig");
    _ = @import("data/local/file_picker.zig");
    _ = @import("domain/usecase/send_request.zig");
    _ = @import("domain/usecase/import_collection.zig");
    _ = @import("domain/usecase/export_collection.zig");
    _ = @import("domain/repository/workspace.zig");
    _ = @import("data/repository/workspace_impl.zig");
    _ = @import("di/container.zig");
}
