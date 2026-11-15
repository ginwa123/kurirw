//! Kurir as a MODULE: `@import("kurirw")` is the whole app — its state, its intents, its view, and its window.
pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const view_model = @import("ui/shell/view_model.zig");
pub const state = @import("state.zig");
pub const theme = @import("ui/theme/theme.zig");
pub const postman = @import("data/model/postman.zig");
pub const store = @import("data/local/workspace_store.zig");
pub const http = @import("data/remote/http_client.zig");

// Every file's own tests, collected without adding an anonymous one, so the suite counts real tests.
comptime {
    _ = @import("state.zig");
    _ = @import("ui/theme/theme.zig");
    _ = @import("data/model/postman.zig");
    _ = @import("data/local/workspace_store.zig");
    _ = @import("data/remote/http_client.zig");
    _ = @import("ui/shell/view_model.zig");
    _ = @import("view.zig");
    _ = @import("app.zig");
    _ = @import("ui/shell/session.zig");
    _ = @import("ui/sidebar/view_model.zig");
    _ = @import("ui/editor/view_model.zig");
    _ = @import("ui/response/view_model.zig");
    _ = @import("data/local/file_picker.zig");
    _ = @import("domain/usecase/send_request.zig");
    _ = @import("domain/usecase/import_collection.zig");
    _ = @import("domain/usecase/export_collection.zig");
}
