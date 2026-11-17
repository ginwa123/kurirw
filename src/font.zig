//! Kurir's one face: Source Sans 3 — the family Source Sans Pro grew into — embedded so every platform draws the same text.
const std = @import("std");
const glinlandui = @import("glinlandui");

// The face itself, in the binary: a build has no assets directory to look for at run time.
pub const bytes: []const u8 = @embedFile("assets/SourceSans3-Regular.ttf");

// Install it as the process-wide face, before the first frame, so no width was measured with the toolkit's bundled one.
pub fn install(alloc: std.mem.Allocator) !void {
    try glinlandui.text.installFaceBytes(alloc, bytes);
}

test "the embedded face parses and is the one measuring text" {
    // page_allocator: the face is process-wide and belongs to the process until a host's shutdown hands it back.
    try install(std.heap.page_allocator);
    try std.testing.expect(glinlandui.text.fontAvailable());
    try std.testing.expect(glinlandui.text.runWidth("Kurir", 14) > 0);
    // A proportional face: "i" and "W" advance differently, which the monospace it replaces cannot do.
    try std.testing.expect(glinlandui.text.runWidth("i", 14) < glinlandui.text.runWidth("W", 14));
}
