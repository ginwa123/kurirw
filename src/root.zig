//! Kurir as a MODULE: `@import("kurirw")` is the whole app — its state, its intents, its view, and its window.
pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const view_model = @import("view_model.zig");
pub const state = @import("state.zig");
pub const theme = @import("theme.zig");
pub const postman = @import("model/postman.zig");
pub const store = @import("model/store.zig");
pub const http = @import("model/http.zig");

// Every file's own tests, collected without adding an anonymous one, so the suite counts real tests.
comptime {
    _ = @import("state.zig");
    _ = @import("theme.zig");
    _ = @import("model/postman.zig");
    _ = @import("model/store.zig");
    _ = @import("model/http.zig");
    _ = @import("view_model.zig");
    _ = @import("view.zig");
    _ = @import("app.zig");
}
