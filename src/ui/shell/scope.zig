//! What a composable reads (theme, model, this frame's state, the widgets) and the layout metrics the panels share.
const std = @import("std");
const glinlandui = @import("glinlandui");

const state_mod = @import("../state.zig");
const view_model = @import("../shell/view_model.zig");
const views_mod = @import("views.zig");

const UiState = state_mod.UiState;
const KurirViewModel = view_model.KurirViewModel;
const Theme = glinlandui.theme.Theme;

// The fixed metrics of the frame: one tree row band (a single line) and one indent step.
pub const row_h: u32 = 26;
pub const indent: u16 = 12;
pub const body_min_h: f32 = 170;
pub const max_body_lines: usize = 4000;

pub const Scope = struct {
    theme: Theme,
    vm: *KurirViewModel,
    state: UiState,
    // The widgets: view state, owned by the App. A panel declares into its own slice of this and never reads another's.
    views: *views_mod.Views,
};

test "the layout constants describe one row band per tree row" {
    try std.testing.expectEqual(@as(u32, 26), row_h);
    try std.testing.expect(indent > 0);
}
