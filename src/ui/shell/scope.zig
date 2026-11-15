//! What a composable reads (theme, model, this frame's state) and the layout metrics the panels share.
const std = @import("std");
const glinlandui = @import("glinlandui");

const state_mod = @import("../state.zig");
const view_model = @import("../shell/view_model.zig");

const UiState = state_mod.UiState;
const KurirViewModel = view_model.KurirViewModel;
const Theme = glinlandui.theme.Theme;

// The fixed metrics of the frame: one tree row band (a single line) and one indent step.
pub const row_h: u32 = 30;
pub const indent: u16 = 12;
pub const body_min_h: f32 = 170;
pub const max_body_lines: usize = 4000;

pub const Scope = struct {
    theme: Theme,
    vm: *KurirViewModel,
    state: UiState,
};

test "the layout constants describe one row band per tree row" {
    try std.testing.expectEqual(@as(u32, 30), row_h);
    try std.testing.expect(indent > 0);
}
