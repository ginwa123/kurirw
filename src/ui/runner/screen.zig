//! The runner's page: the tests its Playwright spec declares on the left, their run on the right.
const std = @import("std");
const glinlandui = @import("glinlandui");

const box = glinlandui.components.box.box;
const spacer = glinlandui.components.box.spacer;
const textField = glinlandui.components.input.textField;
const scroll = glinlandui.components.scroll.scroll;
const label = glinlandui.components.text.label;
const props = glinlandui.props;
const frame = glinlandui.frame;

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

// How tall the spec field opens: the code is a screen's worth of tests, not a scroll of one line.
const spec_min_h: f32 = 320;
// The pane's own height for the code: it fills the FLOW column and scrolls.
const spec_pad: f32 = 8;

// The page's own widgets: bound on the first frame that declares them.
fn views(scope: *Scope) *views_mod.Views.Runner {
    const v = &scope.views.runner;
    if (v.started) return v;
    const session = &scope.vm.session;
    const vm = scope.vm;
    v.spec = session.fieldStyle(.{ .text = runner_vm.spec_field_id }, @src());
    v.spec.multiline = true;
    v.spec.pad = props.Pad.all(spec_pad);
    v.spec.h = .grow;
    v.spec.bind();
    v.spec.on_change = .{ .f = runner_vm.Runner.onSpecTyped, .ctx = &vm.runner };
    // The spec is not JSON, so the editor colours nothing; the field still gives it lines and a caret.
    v.spec_code = @import("../code_editor.zig").CodeEditor.init(session.gpa);
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
    // The title IS the runner: the document's own name, so the page and the tree never disagree.
    const name = if (scope.state.runner_name.len > 0) scope.state.runner_name else "Runner";
    label(.{ .label = .{ .text = name, .size = t.type_scale.title, .color = t.colors.text } });
    label(.{ .label = .{ .text = "playwright spec", .size = t.type_scale.body, .color = t.colors.text_dim } });
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

// ---- the left column: the spec's tests by name, or the spec itself ------------------------------------------

fn programPane(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.program" },
        .direction = .column,
        .w = .{ .fixed = 420 },
        .h = .grow,
        .gap = .{ .px = 6 },
    }, scope, programChildren);
}

fn programChildren(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.program.bar" },
        .direction = .row,
        .w = .grow,
        .child_align = .{ .y = .center },
        .gap = .{ .px = 6 },
    }, scope, programBarChildren);
    if (scope.state.runner_code_open) {
        specPane(scope);
    } else {
        testList(scope);
    }
    // The one line the page says about the runtime, so a missing install is never a silent no-op.
    if (scope.state.runner_engine.len > 0) {
        label(.{ .label = .{
            .text = scope.state.runner_engine,
            .size = scope.theme.type_scale.caption,
            .color = if (std.mem.startsWith(u8, scope.state.runner_engine, "playwright:")) scope.theme.colors.text_done else theme_mod.danger,
        }, .wrap = true });
    }
}

fn programBarChildren(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "FLOW", .size = t.type_scale.caption, .color = t.colors.text_done } });
    spacer(.{ .text = "kurir.runner.program.gap" });
    smallButton(scope, runner_vm.send_id, "+ Send", 64, actions.onRunnerAddSend);
    smallButton(scope, runner_vm.test_id, "+ Test", 64, actions.onRunnerAddTest);
    smallButton(scope, runner_vm.code_id, if (scope.state.runner_code_open) "Tests" else "Code", 64, actions.onRunnerCode);
}

// The tests the spec declares, by name, one row each.
fn testList(scope: *Scope) void {
    if (scope.state.runner_tests.len == 0) {
        box(.{
            .src = @src(),
            .id = .{ .text = "kurir.runner.tests.empty" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .gap = .{ .px = 6 },
            .pad = props.Pad.all(6),
        }, scope, testListEmpty);
        return;
    }
    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.tests" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
    }, scope, testRows);
}

fn testListEmpty(scope: *Scope) void {
    const t = scope.theme;
    label(.{ .label = .{ .text = "No tests yet.", .size = t.type_scale.body, .color = t.colors.text_dim } });
    label(.{ .label = .{
        .text = "Pick a request in the tree and press + Send, or press + Test and write the code.",
        .size = t.type_scale.caption,
        .color = t.colors.text_done,
    }, .wrap = true });
}

fn testRows(scope: *Scope) void {
    for (scope.state.runner_tests, 0..) |test_case, index| {
        box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.runner.test", index) },
            .direction = .row,
            .w = .grow,
            .h = .{ .fixed = 24 },
            .child_align = .{ .y = .center },
            .gap = .{ .px = 8 },
            .pad = props.Pad.axes(2, 6),
            .radius = props.Radius.all(4),
            .hover_bg = scope.theme.colors.hover,
        }, &TestRowCtx{ .theme = scope.theme, .test_case = test_case, .index = index }, testRowChildren);
    }
}

const TestRowCtx = struct {
    theme: glinlandui.theme.Theme,
    test_case: state_mod.RunnerTest,
    index: usize,
};

fn testRowChildren(ctx: *const TestRowCtx) void {
    const t = ctx.theme;
    label(.{ .label = .{ .text = "test", .size = t.type_scale.caption, .color = theme_mod.accent } });
    label(.{ .label = .{ .text = ctx.test_case.name, .size = t.type_scale.body, .color = t.colors.text } });
    spacer(.{ .text = frame.elementId("kurir.runner.test.fill", ctx.index) });
    label(.{ .label = .{
        .text = frame.formatText("line {d}", .{ctx.test_case.line}),
        .size = t.type_scale.caption,
        .color = t.colors.text_done,
    } });
}

// The spec itself: a multiline field, scrolling with its caret.
fn specPane(scope: *Scope) void {
    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.spec.scroll" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
    }, scope, specField);
}

fn specField(scope: *Scope) void {
    const v = views(scope);
    const field = &v.spec;
    field.value = scope.state.runner_flow;
    field.w = .grow;
    field.h = .{ .fixed = spec_min_h };
    v.spec_code.textField(field);
}

// ---- the right column: the run -----------------------------------------------------------------------------

fn resultPane(scope: *Scope) void {
    box(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.results" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .gap = .{ .px = 6 },
    }, scope, resultChildren);
}

fn resultChildren(scope: *Scope) void {
    controlsRow(scope);
    tableHeader(scope);
    scroll(.{
        .src = @src(),
        .id = .{ .text = "kurir.runner.table" },
        .w = .grow,
        .h = .grow,
    }, scope, tableRows);
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
        .text = frame.formatText("{d} tests   {d} passed   {d} failed   {d} skipped   {d} ms", .{
            scope.state.runner_total,
            scope.state.runner_ok,
            scope.state.runner_failed,
            scope.state.runner_skipped,
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
    label(.{ .label = .{ .text = "TEST", .size = t.type_scale.caption, .color = t.colors.text_done } });
    spacer(.{ .text = "kurir.runner.th.fill" });
    headerCell(scope, "STATUS", 0);
    headerCell(scope, "TIME", 1);
}

// A header with the width its column has, so the labels line up over the rows.
fn headerCell(scope: *Scope, text: []const u8, slot: usize) void {
    const t = scope.theme;
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.runner.th.cell", slot) },
        .direction = .row,
        .w = .{ .fixed = if (slot == 0) 60 else 54 },
        .h = .{ .fixed = 18 },
        .child_align = .{ .x = .right, .y = .center },
    }, &HeaderText{ .theme = t, .text = text }, headerTextChild);
}

const HeaderText = struct {
    theme: glinlandui.theme.Theme,
    text: []const u8,
};

fn headerTextChild(ctx: *const HeaderText) void {
    label(.{ .label = .{ .text = ctx.text, .size = ctx.theme.type_scale.caption, .color = ctx.theme.colors.text_done } });
}

fn tableRows(scope: *Scope) void {
    for (scope.state.runner_rows, 0..) |_, index| {
        scope.vm.runner.draw_row = index;
        box(.{
            .src = @src(),
            .id = .{ .text = frame.elementId("kurir.runner.row", index) },
            .direction = .column,
            .w = .grow,
            .pad = props.Pad.axes(4, 4),
            .gap = .{ .px = 2 },
        }, scope, resultRow);
    }
    if (scope.state.runner_rows.len == 0) {
        label(.{ .label = .{
            .text = if (scope.state.runner_phase == .idle) "Press Run to execute the spec." else "Waiting for Playwright...",
            .size = scope.theme.type_scale.caption,
            .color = scope.theme.colors.text_dim,
        } });
    }
}

// One test: its name and verdict on a line, and the failure's own line under it when there is one.
fn resultRow(scope: *Scope) void {
    const index = scope.vm.runner.draw_row;
    if (index >= scope.state.runner_rows.len) return;
    const row = scope.state.runner_rows[index];
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.runner.row.line", index) },
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = 18 },
        .child_align = .{ .y = .center },
    }, &RowCtx{ .theme = scope.theme, .row = row, .index = index }, rowLine);
    if (row.detail.len == 0) return;
    label(.{ .label = .{
        .text = row.detail,
        .size = scope.theme.type_scale.caption,
        .color = if (row.ok) scope.theme.colors.text_done else theme_mod.danger,
    }, .wrap = true });
}

const RowCtx = struct {
    theme: glinlandui.theme.Theme,
    row: state_mod.RunnerRow,
    index: usize,
};

fn rowLine(ctx: *const RowCtx) void {
    const t = ctx.theme;
    label(.{ .label = .{ .text = ctx.row.name, .size = t.type_scale.caption, .color = t.colors.text } });
    spacer(.{ .text = frame.elementId("kurir.runner.row.fill", ctx.index) });
    const tone = if (ctx.row.skipped) t.colors.text_dim else if (ctx.row.ok) theme_mod.success else theme_mod.danger;
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.runner.row.status", ctx.index) },
        .direction = .row,
        .w = .{ .fixed = 60 },
        .h = .{ .fixed = 18 },
        .child_align = .{ .x = .right, .y = .center },
    }, &StatusCtx{ .theme = t, .text = ctx.row.label, .color = tone }, statusChild);
    box(.{
        .src = @src(),
        .id = .{ .text = frame.elementId("kurir.runner.row.time", ctx.index) },
        .direction = .row,
        .w = .{ .fixed = 54 },
        .h = .{ .fixed = 18 },
        .child_align = .{ .x = .right, .y = .center },
    }, &StatusCtx{ .theme = t, .text = frame.formatText("{d} ms", .{ctx.row.time_ms}), .color = t.colors.text_dim }, statusChild);
}

const StatusCtx = struct {
    theme: glinlandui.theme.Theme,
    text: []const u8,
    color: Color,
};

fn statusChild(ctx: *const StatusCtx) void {
    label(.{ .label = .{ .text = ctx.text, .size = ctx.theme.type_scale.caption, .color = ctx.color } });
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
    label(.{ .label = .{
        .text = frame.formatText("{d} skipped", .{scope.state.runner_skipped}),
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    } });
    label(.{ .label = .{ .text = frame.formatText("{d} ms total", .{scope.state.runner_ms}), .size = t.type_scale.caption, .color = t.colors.text_dim } });
    spacer(.{ .text = "kurir.runner.summary.fill" });
    label(.{ .label = .{ .text = "tests are the spec's own", .size = t.type_scale.caption, .color = t.colors.text_done } });
}

fn nothing(_: *Scope) void {}
