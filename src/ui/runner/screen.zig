//! The runner's page: the plan on the left, the options, the table and the summary on the right.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const button = glinlandui.components.button.button;
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
    v.iterations.on_change = .{ .f = runner_vm.Runner.onIterationsTyped, .ctx = vm };
    v.delay = session.fieldStyle(.{ .text = runner_vm.delay_id }, @src());
    v.delay.bind();
    v.delay.on_change = .{ .f = runner_vm.Runner.onDelayTyped, .ctx = vm };
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
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.header" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 8 },
    }, scope, headerChildren);
    _ = t;
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "Runner", .size = t.type_scale.title, .color = t.colors.text } });
    label(.{ .label = .{ .text = scope.state.runner_collection, .size = t.type_scale.body, .color = t.colors.text_dim } });
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
    planPane(scope);
    resultPane(scope);
}

// The left column: what the run will send, one tick box per request.
fn planPane(scope: *Scope) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.plan" },
        .direction = .column,
        .w = .{ .fixed = 250 },
        .h = .grow,
        .gap = .{ .px = 4 },
    }, scope, planChildren);
    _ = t;
}

fn planChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "REQUESTS", .size = t.type_scale.caption, .color = t.colors.text_done } });
    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.plan.list" },
        .w = .grow,
        .h = .grow,
    }, scope, planList);
    label(.{ .label = .{
        .text = frame.formatText("{d} of {d} selected", .{ scope.state.runner_selected, scope.state.runner_total }),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });
}

fn planList(scope: *Scope) void {
    for (scope.state.runner_steps, 0..) |step, index| {
        stepRow(scope, step, index);
    }
    if (scope.state.runner_steps.len == 0) {
        label(.{ .label = .{
            .text = "No requests under this selection.",
            .size = scope.theme.type_scale.caption,
            .color = scope.theme.colors.text_dim,
        } });
    }
}

// One request: `[x] POST name`, and a click on it toggles whether the run sends it.
fn stepRow(scope: *Scope, step: state_mod.RunnerStep, index: usize) void {
    const t = scope.theme;
    const tick: []const u8 = if (step.enabled) "[x] " else "[ ] ";
    button(.{
        .id = .{ .text = frame.elementId(runner_vm.step_prefix, index) },
        .label = .{
            .text = frame.formatText("{s}{s} {s}", .{ tick, step.method, step.name }),
            .size = t.type_scale.caption,
            .color = if (step.enabled) t.colors.text else t.colors.text_done,
        },
        .bg = t.colors.surface,
        .hover_bg = t.colors.hover,
        .w = .grow,
        .pad = props.Pad.axes(3, 6),
        .radius = props.Radius.all(3),
        .on_click = .{ .f = actions.onRunnerStep, .ctx = &scope.vm.runner.step_ctxs[index] },
    });
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
        .gap = .{ .px = 10 },
    }, scope, optionsChildren);
}

fn optionsChildren(scope: *Scope) void {
    const t = scope.theme;
    numberField(scope, "Iterations", &views(scope).iterations, scope.state.runner_iterations, 52);
    numberField(scope, "Delay ms", &views(scope).delay, scope.state.runner_delay, 60);
    label(.{ .label = .{
        .text = frame.formatText("Environment: {s}", .{scope.state.runner_env}),
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
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.controls" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 8 },
    }, scope, controlsChildren);
    _ = t;
}

fn controlsChildren(scope: *Scope) void {
    const t = scope.theme;
    const busy = scope.state.runner_phase == .running or scope.state.runner_phase == .stopping;
    smallButton(scope, runner_vm.run_id, if (busy) "Run again" else "Run", 84, actions.onRunnerRun);
    smallButton(scope, runner_vm.stop_id, "Stop", 64, actions.onRunnerStop);
    label(.{ .label = .{
        .text = frame.formatText("{d} sent   {d} failed   {d} ms", .{
            scope.state.runner_done,
            scope.state.runner_failed,
            scope.state.runner_ms,
        }),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });
}

fn tableHeader(scope: *Scope) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.table.header" },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.axes(4, 4),
        .child_align = .{ .y = .center },
        .gap = .{ .px = 6 },
    }, scope, tableHeaderChildren);
    _ = t;
}

fn tableHeaderChildren(scope: *Scope) void {
    const t = scope.theme;
    const headers = [_][]const u8{ "ITER", "METHOD", "REQUEST", "STATUS", "TIME", "RESULT" };
    for (headers, 0..) |text, index| {
        label(.{ .label = .{ .text = text, .size = t.type_scale.caption, .color = t.colors.text_done } });
        spacer(.{ .text = frame.elementId("kurir.runner.th.spacer", index) });
    }
}

// The VM holds which row is being drawn, because a box's children callback takes only the scope.
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
            .text = if (scope.state.runner_phase == .idle) "Press Run to send the ticked requests." else "Waiting for the first answer...",
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
    cell(scope, frame.formatText("{d}", .{row.iteration}), 30, t.colors.text_dim);
    cell(scope, row.method, 54, theme_mod.methodColor(row.method));
    cell(scope, row.name, 300, t.colors.text);
    cell(scope, if (row.status == 0) "-" else frame.formatText("{d}", .{row.status}), 46, theme_mod.statusColor(row.status));
    cell(scope, frame.formatText("{d} ms", .{row.time_ms}), 70, t.colors.text_dim);
    const result = if (row.ok) "ok" else row.failure;
    cell(scope, result, 0, if (row.ok) theme_mod.success else theme_mod.danger);
}

// One value and the room its column takes, so the next column starts where the last one ends.
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
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.summary" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 16 },
        .pad = props.Pad.axes(6, 0),
    }, scope, summaryChildren);
    _ = t;
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
    label(.{ .label = .{ .text = scope.state.runner_note, .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn nothing(_: *Scope) void {}
