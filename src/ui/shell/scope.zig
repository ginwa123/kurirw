//! What a composable reads (theme, model, this frame's state) and the layout metrics the panels share.
const std = @import("std");
const glinlandui = @import("glinlandui");

const state_mod = @import("../../state.zig");
const view_model = @import("../shell/view_model.zig");

const UiState = state_mod.UiState;
const KurirViewModel = view_model.KurirViewModel;
const Theme = glinlandui.theme.Theme;

// The fixed metrics of the frame: one row band, one indent step, and the editor's two heights.
pub const editor_h: u32 = 320;
pub const row_h: u32 = 26;
pub const indent: u16 = 14;
pub const body_min_h: f32 = 170;
pub const max_body_lines: usize = 4000;

pub const Scope = struct {
    theme: Theme,
    vm: *KurirViewModel,
    state: UiState,
};

test "the layout constants describe one row band per tree row" {
    try std.testing.expectEqual(@as(u32, 26), row_h);
    try std.testing.expect(editor_h > row_h * 3);
}
