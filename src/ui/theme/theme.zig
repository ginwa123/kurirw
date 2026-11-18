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

// The text selection's band and ink: a saturated step of the accent's own hue, so a selected run reads as selected on any field tone.
pub const select_bg = Color.hexC("#356f8f");
pub const select_fg = Color.hexC("#f4f7f4");

// One sRGB channel as a linear-light fraction, which is the space a contrast ratio is computed in.
fn linearChannel(v: u8) f32 {
    const s = @as(f32, @floatFromInt(v)) / 255;
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
}

// WCAG relative luminance: 0 for black, 1 for white, and the one number both contrast checks rest on.
pub fn luminance(c: Color) f32 {
    return 0.2126 * linearChannel(c.r()) + 0.7152 * linearChannel(c.g()) + 0.0722 * linearChannel(c.b());
}

// The WCAG contrast ratio of two colours: 1:1 for the same tone, 21:1 for black on white.
pub fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

// How far apart a colour's brightest and dimmest channels are: a grey sits at 0, and a colour a person can see does not.
fn channelSpread(c: Color) u8 {
    return @max(c.r(), @max(c.g(), c.b())) - @min(c.r(), @min(c.g(), c.b()));
}

// The tab strip's three fills: the bar is the page, a hovered tab one step up, the open tab the brightest of the three.
pub const tab_hover = Color.lerp(app_theme.colors.background, app_theme.colors.surface_variant, 0.6);
pub const tab_active = app_theme.colors.surface_variant;

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

test "a selected run reads as selected, and its ink stays readable" {
    // AA for body text: a selected run is never harder to read than the field around it.
    try testing.expect(contrast(select_fg, select_bg) >= 4.5);
    // The band is a band: three times the field surface, which the old grey-on-grey did not reach.
    try testing.expect(contrast(select_bg, app_theme.colors.surface) >= 3.0);
    try testing.expect(contrast(select_bg, app_theme.colors.surface_variant) >= 3.0);
    // A selection is a COLOUR: no grey can pass the spread, and the ink is a light neutral rather than a hue.
    try testing.expect(channelSpread(select_bg) >= 60);
    try testing.expect(channelSpread(select_fg) < 40);
    // The caret keeps a tone of its own on top of it, so the two signs of a selection do not merge.
    try testing.expect(!same(select_bg, app_theme.colors.primary));
}

test "contrast is the WCAG ratio, and luminance orders black under white" {
    try testing.expect(luminance(Color.hexC("#000000")) < 0.001);
    try testing.expect(luminance(Color.hexC("#ffffff")) > 0.99);
    // The two fixed ends of the ratio the formula promises.
    try testing.expectApproxEqAbs(@as(f32, 21.0), contrast(Color.hexC("#000000"), Color.hexC("#ffffff")), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), contrast(select_bg, select_bg), 0.001);
    // The ratio is symmetric: swapping the two colours cannot change it.
    try testing.expectApproxEqAbs(contrast(select_fg, select_bg), contrast(select_bg, select_fg), 0.001);
}
