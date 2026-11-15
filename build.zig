// Kurir: a Postman-style API client on glinlandui. One executable, one test step, two lint gates.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glinlandui_dep = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });
    // Forwarded to kabelweb: true refuses its no-op stub libcurl, which links but cannot send.
    const require_real_curl = b.option(
        bool,
        "require-real-curl",
        "Fail instead of linking kabelweb's no-op stub libcurl (CI uses this)",
    ) orelse false;
    const kabelweb_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
        .@"require-real-curl" = require_real_curl,
    });
    const glinlandui = glinlandui_dep.module("glinlandui");
    const kabelweb = kabelweb_dep.module("kabelweb");

    const kurirw_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glinlandui", .module = glinlandui },
            .{ .name = "kabelweb", .module = kabelweb },
        },
    });

    const exe = b.addExecutable(.{
        .name = "kurirw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = glinlandui },
                .{ .name = "kurirw", .module = kurirw_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run Kurir");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // A one-request CLI, so the real transport can be proven without opening a window.
    const smoke = b.addExecutable(.{
        .name = "kurirw-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kurirw", .module = kurirw_mod }},
        }),
    });
    const smoke_step = b.step("smoke", "Send one real request (KURIR_SMOKE_URL) through kabelweb");
    const smoke_cmd = b.addRunArtifact(smoke);
    if (b.args) |args| smoke_cmd.addArgs(args);
    smoke_step.dependOn(&smoke_cmd.step);

    // The module's own tests: every file's `test` blocks, reached through src/root.zig.
    const unit_tests = b.addTest(.{ .root_module = kurirw_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // The E2E suite drives the real App headlessly, so it is its own binary and imports the module by name.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glinlandui", .module = glinlandui },
            .{ .name = "kurirw", .module = kurirw_mod },
        },
    });
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const test_step = b.step("test", "Run the unit suite and the headless E2E suite");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_e2e_tests.step);

    const unit_step = b.step("test-unit", "Run only the unit suite");
    unit_step.dependOn(&run_unit_tests.step);

    installLintGates(b, target, optimize, test_step);
}

// The two repo gates: zginlint's style rules, and the 3000-line cap.
fn installLintGates(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_step: *std.Build.Step) void {
    const zginlint_dep = b.dependency("zginlint", .{ .target = target, .optimize = optimize });
    const zginlint_exe = zginlint_dep.artifact("zginlint");
    const install_zginlint = b.addInstallArtifact(zginlint_exe, .{});
    b.step("zginlint", "Build the zginlint CLI into zig-out/bin/zginlint").dependOn(&install_zginlint.step);

    const zginlint_check = b.step("zginlint:check", "Enforce the zginlint rules on the tree (zero findings)");
    const run_zginlint = b.addRunArtifact(zginlint_exe);
    run_zginlint.setCwd(b.path("."));
    run_zginlint.addArgs(&.{ "--max-comment-lines", "1", "src", "build.zig" });
    run_zginlint.has_side_effects = true;
    zginlint_check.dependOn(&run_zginlint.step);

    // A Zig tool rather than a shell pipeline: `sh` + `find` + `awk` do not exist on a Windows runner.
    const lines_check = b.step("lines:check", "Fail if any .zig file exceeds 3000 lines");
    const lines_tool = b.addExecutable(.{
        .name = "check-lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_lines.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_lines = b.addRunArtifact(lines_tool);
    run_lines.setCwd(b.path("."));
    run_lines.has_side_effects = true;
    lines_check.dependOn(&run_lines.step);

    // The tool's own tests run with the unit suite, so a change to it is covered.
    const lines_tests = b.addTest(.{ .root_module = lines_tool.root_module });
    test_step.dependOn(&b.addRunArtifact(lines_tests).step);
}
