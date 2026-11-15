//! Kurir's palette: the toolkit's Kanagawa Dragon kit plus the tones a request list needs and a theme has no role for.
const std = @import("std");
const glinlandui = @import("glinlandui");
const postman = @import("../../data/model/postman.zig");

pub const Theme = glinlandui.theme.Theme;
pub const Color = glinlandui.Color;

// Dragon, unchanged: a theme is a value the app hands down, so this is the only place the palette lives.
pub const app_theme: Theme = glinlandui.theme.dragon;

// Method tones, one per verb, so a list of endpoints reads like a column of coloured labels.
pub const method_get = Color.hexC("#87a987");
pub const method_post = Color.hexC("#c4b28a");
pub const method_put = Color.hexC("#8ba4b0");
pub const method_patch = Color.hexC("#8992a7");
pub const method_delete = Color.hexC("#c4746e");
pub const method_other = Color.hexC("#a6a69c");

// The three tones nothing in the theme names: a good response, a bad one, and a warning banner.
pub const success = Color.hexC("#87a987");
pub const danger = Color.hexC("#c4746e");
pub const warn = Color.hexC("#c4b28a");

// The sidebar's accent: the badge, the "+ New" button and the selected row's bar are one colour.
pub const accent = success;

// How far a method chip's fill leans towards the verb's own tone. Low enough that a chip is a tint, not a block.
const chip_tint: f32 = 0.28;

// A method chip's fill: the surface moved a step towards the verb's colour, so a column of chips reads as ordered without shouting.
pub fn chipBg(method: []const u8) Color {
    return Color.lerp(app_theme.colors.surface_variant, methodColor(method), chip_tint);
}

// The colour of a method label. An unknown verb is not an error, it is just quiet.
pub fn methodColor(method: []const u8) Color {
    for (postman.methods) |known| {
        if (!std.ascii.eqlIgnoreCase(method, known)) continue;
        if (std.mem.eql(u8, known, "GET")) return method_get;
        if (std.mem.eql(u8, known, "POST")) return method_post;
        if (std.mem.eql(u8, known, "PUT")) return method_put;
        if (std.mem.eql(u8, known, "PATCH")) return method_patch;
        if (std.mem.eql(u8, known, "DELETE")) return method_delete;
        return method_other;
    }
    return method_other;
}

// A status code's tone: 2xx good, 3xx neutral, 4xx and 5xx bad.
pub fn statusColor(status: u16) Color {
    if (status >= 200 and status < 300) return success;
    if (status >= 300 and status < 400) return method_other;
    if (status == 0) return method_other;
    return danger;
}

const testing = std.testing;

fn same(a: Color, b: Color) bool {
    return std.meta.eql(a, b);
}

test "every verb the editor offers has its own tone" {
    try testing.expect(!same(methodColor("GET"), methodColor("POST")));
    try testing.expect(!same(methodColor("PUT"), methodColor("PATCH")));
    try testing.expect(!same(methodColor("DELETE"), methodColor("GET")));
    // HEAD and OPTIONS share the quiet tone on purpose, and an unknown verb is quiet too.
    try testing.expect(same(method_other, methodColor("HEAD")));
    try testing.expect(same(method_other, methodColor("OPTIONS")));
    try testing.expect(same(method_other, methodColor("TRACE")));
    // The lookup normalises, so a stored "get" draws as GET.
    try testing.expect(same(method_get, methodColor("get")));
}

test "a status code picks its tone by class" {
    try testing.expect(same(success, statusColor(200)));
    try testing.expect(same(success, statusColor(204)));
    try testing.expect(same(danger, statusColor(404)));
    try testing.expect(same(danger, statusColor(500)));
    try testing.expect(same(method_other, statusColor(301)));
    try testing.expect(same(method_other, statusColor(0)));
}
