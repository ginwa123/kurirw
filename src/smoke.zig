//! A one-shot smoke: one REAL kabelweb request from `KURIR_SMOKE_URL`, `_METHOD` and `_BODY`, printed.
const std = @import("std");
const kurirw = @import("kurirw");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const url = init.environ_map.get("KURIR_SMOKE_URL") orelse "http://127.0.0.1:8099/";
    const method = init.environ_map.get("KURIR_SMOKE_METHOD") orelse "GET";
    const body = init.environ_map.get("KURIR_SMOKE_BODY") orelse "";

    var real = kurirw.http.Real.init(gpa);
    defer real.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const result = real.transport(arena_state.allocator()).perform(.{
        .method = method,
        .url = url,
        .body = body,
        .headers = &.{.{ .name = "accept", .value = "*/*" }},
    });

    if (result.failed) {
        std.debug.print("{s} {s} -> FAILED {s}: {s}\n", .{ method, url, result.error_title, result.error_message });
        return error.RequestFailed;
    }
    std.debug.print("{s} {s} -> {d} {s} in {d} ms, {d} bytes, {d} headers\n", .{
        method,
        url,
        result.status,
        result.reason,
        result.time_ms,
        result.body.len,
        result.headers.len,
    });
    if (result.body.len > 0) std.debug.print("---\n{s}\n", .{result.body[0..@min(result.body.len, 2000)]});
}
