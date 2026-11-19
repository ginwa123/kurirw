//! The runner's page: the flow program on the left, its run on the right.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const textField = glinlandui.components.input.textField;
const scroll = glinlandui.components.scroll.scroll;
const label = glinlandui.components.text.label;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme/theme.zig");
const scope_mod = @import("../shell/scope.zig");
const views_mod = @import("../shell/views.zig");
const widgets = @import("../shell/widgets.zig");
const actions = @import("../shell/actions.zig");
const runner_vm = @import("view_model.zig");

const smallButton = widgets.smallButton;
const Scope = scope_mod.Scope;
const Color = glinlandui.Color;

// The page's own widgets: styled and bound on the first frame that declares them.
fn views(scope: *Scope) *views_mod.Views.Runner {
    const v = &scope.views.runner;
    if (v.started) return v;
    const session = &scope.vm.session;
    const vm = scope.vm;
    v.iterations = session.fieldStyle(.{ .text = runner_vm.iterations_id }, @src());
    v.iterations.bind();
    v.iterations.on_change = .{ .f = runner_vm.Runner.onIterationsTyped, .ctx = &vm.runner };
    v.delay = session.fieldStyle(.{ .text = runner_vm.delay_id }, @src());
    v.delay.bind();
    v.delay.on_change = .{ .f = runner_vm.Runner.onDelayTyped, .ctx = &vm.runner };
    v.started = true;
    return v;
}

pub fn page(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = runner_vm.page_id },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.surface,
        .border = .all(1, scope.theme.colors.divider),
        .pad = props.Pad.all(14),
        .gap = .{ .px = 10 },
    }, scope, pageChildren);
}

fn pageChildren(scope: *Scope) void {
    header(scope);
    body(scope);
    summary(scope);
}

fn header(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.header" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 8 },
    }, scope, headerChildren);
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "Runner", .size = t.type_scale.title, .color = t.colors.text } });
    label(.{ .label = .{ .text = "flow", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{ .text = phaseLabel(scope.state.runner_phase), .size = t.type_scale.caption, .color = phaseColor(scope) } });
    spacer(.{ .text = "kurir.runner.header.spacer" });
    smallButton(scope, runner_vm.close_id, "Close", 64, actions.onRunnerClose);
}

fn phaseLabel(phase: state_mod.RunnerPhase) []const u8 {
    return switch (phase) {
        .idle => "ready",
        .running => "running",
        .stopping => "stopping",
        .finished => "finished",
        .stopped => "stopped",
    };
}

fn phaseColor(scope: *Scope) Color {
    return switch (scope.state.runner_phase) {
        .idle, .stopping => scope.theme.colors.text_dim,
        .running => theme_mod.accent,
        .finished => if (scope.state.runner_failed > 0) theme_mod.danger else theme_mod.accent,
        .stopped => theme_mod.warn,
    };
}

fn body(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.body" },
        .direction = .row,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 14 },
    }, scope, bodyChildren);
}

fn bodyChildren(scope: *Scope) void {
    programPane(scope);
    resultPane(scope);
}

// The left column: the program, its buttons, and the diagnostic when a line does not parse.
fn programPane(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.program" },
        .direction = .column,
        .w = .{ .fixed = 380 },
        .h = .grow,
        .gap = .{ .px = 6 },
    }, scope, programChildren);
}

fn programChildren(scope: *Scope) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.program.bar" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 6 },
    }, scope, programBarChildren);
    _ = t;

    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.program.text" },
        .w = .grow,
        .h = .grow,
    }, scope, scriptLines);

    if (scope.state.runner_error.len > 0) {
        label(.{ .label = .{
            .text = scope.state.runner_error,
            .size = scope.theme.type_scale.caption,
            .color = theme_mod.danger,
        } });
    }
}

fn programBarChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "FLOW", .size = t.type_scale.caption, .color = t.colors.text_done } });
    spacer(.{ .text = "kurir.runner.program.gap" });
    smallButton(scope, runner_vm.send_id, "+ Send", 64, actions.onRunnerAddSend);
    smallButton(scope, runner_vm.delay_step_id, "+ Delay", 68, actions.onRunnerAddDelay);
    smallButton(scope, runner_vm.loop_id, "Loop data", 84, actions.onRunnerLoop);
}

// The script, one label a line: it is WRITTEN from the program, which is what the buttons edit.
fn scriptLines(scope: *Scope) void {
    const text = scope.state.runner_flow;
    if (text.len == 0) {
        label(.{ .label = .{
            .text = "Pick a request in the tree, then press + Send.",
            .size = scope.theme.type_scale.caption,
            .color = scope.theme.colors.text_dim,
        } });
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const shown: []const u8 = if (line.len == 0) " " else line;
        const tone = if (std.mem.startsWith(u8, shown, "send ")) scope.theme.colors.text else scope.theme.colors.text_dim;
        label(.{ .label = .{ .text = shown, .size = scope.theme.type_scale.caption, .color = tone } });
    }
}

// The right column: the options, the two buttons, the table, then the summary below it.
fn resultPane(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.results" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 8 },
    }, scope, resultChildren);
}

fn resultChildren(scope: *Scope) void {
    optionsRow(scope);
    controlsRow(scope);
    tableHeader(scope);
    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.table" },
        .w = .grow,
        .h = .grow,
    }, scope, tableRows);
}

fn optionsRow(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.options" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 8 },
    }, scope, optionsChildren);
}

fn optionsChildren(scope: *Scope) void {
    const t = scope.theme;
    numberField(scope, "Iterations", &views(scope).iterations, scope.state.runner_iterations, 52);
    numberField(scope, "Delay ms", &views(scope).delay, scope.state.runner_delay, 60);
    label(.{ .label = .{
        .text = frame.formatText("Env: {s}", .{scope.state.runner_env}),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });
    label(.{ .label = .{
        .text = frame.formatText("Data: {s}", .{scope.state.runner_data}),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });
    smallButton(scope, runner_vm.data_id, "Data file", 76, actions.onRunnerData);
}

fn numberField(scope: *Scope, title: []const u8, field: *glinlandui.components.input.Field, value: []const u8, width: u32) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = title, .size = t.type_scale.caption, .color = t.colors.text_dim } });
    field.value = value;
    field.w = .{ .fixed = @floatFromInt(width) };
    field.h = .{ .fixed = 26 };
    field.pad = props.Pad.axes(4, 8);
    textField(field);
}

fn controlsRow(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.controls" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 8 },
    }, scope, controlsChildren);
}

fn controlsChildren(scope: *Scope) void {
    const t = scope.theme;
    const busy = scope.state.runner_phase == .running or scope.state.runner_phase == .stopping;
    smallButton(scope, runner_vm.run_id, "Run", 84, actions.onRunnerRun);
    smallButton(scope, runner_vm.stop_id, "Stop", 64, actions.onRunnerStop);
    label(.{ .label = .{
        .text = frame.formatText("{d} steps   {d} sent   {d} failed   {d} ms", .{
            scope.state.runner_selected,
            scope.state.runner_done,
            scope.state.runner_failed,
            scope.state.runner_ms,
        }),
        .size = t.type_scale.caption,
        .color = if (busy) theme_mod.accent else t.colors.text_dim,
    } });
}

fn tableHeader(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.table.header" },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.axes(4, 4),
        .child_align = .{ .y = .center },
        .gap = .{ .px = 6 },
    }, scope, tableHeaderChildren);
}

fn tableHeaderChildren(scope: *Scope) void {
    const t = scope.theme;
    const headers = [_][]const u8{ "ITER", "STEP", "STATUS", "TIME", "TESTS", "RESULT" };
    for (headers, 0..) |text, index| {
        label(.{ .label = .{ .text = text, .size = t.type_scale.caption, .color = t.colors.text_done } });
        spacer(.{ .text = frame.elementId("kurir.runner.th.spacer", index) });
    }
}

fn tableRows(scope: *Scope) void {
    // One counter for the whole frame: two rows must not declare the same cell id.
    scope.vm.runner.draw_cell = 0;
    for (scope.state.runner_rows, 0..) |_, index| {
        scope.vm.runner.draw_row = index;
        box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.runner.row", index) },
            .direction = .row,
            .w = .grow,
            .pad = props.Pad.axes(4, 4),
            .child_align = .{ .y = .center },
            .gap = .{ .px = 6 },
        }, scope, resultRow);
    }
    if (scope.state.runner_rows.len == 0) {
        label(.{ .label = .{
            .text = if (scope.state.runner_phase == .idle) "Press Run to execute the flow." else "Waiting for the first answer...",
            .size = scope.theme.type_scale.caption,
            .color = scope.theme.colors.text_dim,
        } });
    }
}

fn resultRow(scope: *Scope) void {
    const t = scope.theme;
    const index = scope.vm.runner.draw_row;
    if (index >= scope.state.runner_rows.len) return;
    const row = scope.state.runner_rows[index];
    cell(scope, frame.formatText("{d}", .{row.iteration}), 18, t.colors.text_dim);
    cell(scope, row.name, 96, t.colors.text);
    cell(scope, if (row.status == 0) "-" else frame.formatText("{d}", .{row.status}), 30, theme_mod.statusColor(row.status));
    cell(scope, frame.formatText("{d} ms", .{row.time_ms}), 34, t.colors.text_dim);
    cell(scope, if (row.tests_total == 0) "-" else frame.formatText("{d}/{d}", .{ row.tests_passed, row.tests_total }), 52, t.colors.text_dim);
    const result = if (row.ok) "ok" else row.failure;
    cell(scope, result, 0, if (row.ok) theme_mod.success else theme_mod.danger);
}

fn cell(scope: *Scope, text: []const u8, width: f32, color: Color) void {
    const t = scope.theme;
    const slot = scope.vm.runner.draw_cell;
    scope.vm.runner.draw_cell += 1;
    label(.{ .label = .{ .text = text, .size = t.type_scale.caption, .color = color } });
    if (width <= 0) {
        spacer(.{ .text = frame.elementId("kurir.runner.cell.fill", slot) });
        return;
    }
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.runner.cell.gap", slot) },
        .w = .{ .fixed = width },
        .h = .{ .fixed = 1 },
    }, scope, nothing);
}

fn summary(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.summary" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 16 },
        .pad = props.Pad.axes(6, 0),
    }, scope, summaryChildren);
}

fn summaryChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = frame.formatText("{d} run", .{scope.state.runner_done}), .size = t.type_scale.caption, .color = t.colors.text } });
    label(.{ .label = .{ .text = frame.formatText("{d} ok", .{scope.state.runner_ok}), .size = t.type_scale.caption, .color = theme_mod.success } });
    label(.{ .label = .{
        .text = frame.formatText("{d} failed", .{scope.state.runner_failed}),
        .size = t.type_scale.caption,
        .color = if (scope.state.runner_failed > 0) theme_mod.danger else t.colors.text_dim,
    } });
    label(.{ .label = .{ .text = frame.formatText("{d} ms total", .{scope.state.runner_ms}), .size = t.type_scale.caption, .color = t.colors.text_dim } });
    spacer(.{ .text = "kurir.runner.summary.fill" });
    label(.{ .label = .{ .text = "the script is generated from the program", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn nothing(_: *Scope) void {}
