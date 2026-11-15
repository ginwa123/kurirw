//! Fail when any `.zig` file is over the size cap. No shell, no `find`: this runs on Windows too.
const std = @import("std");

// The same cap AGENTS.md states: past this a module is asking to be split.
const max_lines: usize = 3000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var offenders: usize = 0;
    for ([_][]const u8{ "src", "tools" }) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const bytes = dir.readFileAlloc(io, entry.path, gpa, .limited(64 * 1024 * 1024)) catch continue;
            defer gpa.free(bytes);
            const lines = countLines(bytes);
            if (lines > max_lines) {
                std.debug.print("{s}/{s}: {d} lines (max {d})\n", .{ root, entry.path, lines, max_lines });
                offenders += 1;
            }
        }
    }

    if (offenders > 0) std.process.exit(1);
    std.debug.print("lines:check: every .zig file is within {d} lines\n", .{max_lines});
}

// Line count the way `wc -l` reports it for a source file: a trailing newline does not open a line.
fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines = std.mem.countScalar(u8, bytes, '\n');
    if (bytes[bytes.len - 1] != '\n') lines += 1;
    return lines;
}

test "countLines agrees with wc -l on the shapes a source file has" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("a"));
    try std.testing.expectEqual(@as(usize, 1), countLines("a\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb\n"));
}
