//! The window's frame pump: on while a job is in flight, so the frame loop keeps coming to collect it.
const std = @import("std");

pub const Pump = struct {
    ctx: ?*anyopaque = null,
    set_fn: *const fn (?*anyopaque, bool) void = noop,

    pub fn set(self: Pump, on: bool) void {
        self.set_fn(self.ctx, on);
    }

    fn noop(_: ?*anyopaque, _: bool) void {}
};

test "a pump with no window is a no-op, and one with a context reports every change" {
    const Spy = struct {
        const state = struct {
            var on: bool = false;
            var calls: usize = 0;
        };

        fn set(_: ?*anyopaque, on: bool) void {
            state.on = on;
            state.calls += 1;
        }
    };

    const quiet = Pump{};
    quiet.set(true);
    quiet.set(false);

    var ctx: u8 = 0;
    const loud = Pump{ .ctx = &ctx, .set_fn = Spy.set };
    loud.set(true);
    try std.testing.expect(Spy.state.on);
    try std.testing.expectEqual(@as(usize, 1), Spy.state.calls);
    loud.set(false);
    try std.testing.expect(!Spy.state.on);
}
