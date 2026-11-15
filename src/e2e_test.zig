// The headless E2E suite: the real App, driven through the real widgets, with a fake transport instead of a socket.
const std = @import("std");
const glinlandui = @import("glinlandui");
const kurirw = @import("kurirw");

const testing = std.testing;
const Driver = glinlandui.testing.Driver;
const App = kurirw.app.App;
const postman = kurirw.postman;
const store_mod = kurirw.store;
const http_mod = kurirw.http;
const view_model = kurirw.view_model;

const viewport = Driver.Viewport{ .width = 1280, .height = 840 };

// A booted app: the window's root function, the driver that clicks it, and the fake that answers requests.
const Harness = struct {
    app: *App,
    driver: Driver,
    env: std.process.Environ.Map,
    home: []u8,
    arena: *std.heap.ArenaAllocator,
    fake: *http_mod.Fake,

    fn boot(gpa: std.mem.Allocator, home: []const u8) !Harness {
        var env = std.process.Environ.Map.init(gpa);
        try env.put("HOME", home);

        const app = try gpa.create(App);
        app.* = .{};
        try app.start(gpa, testing.io, env);

        var driver = try Driver.initOwned(gpa, app, App.content);
        errdefer driver.deinit();
        try driver.start(viewport);

        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        const fake = try gpa.create(http_mod.Fake);
        fake.* = http_mod.Fake.init(arena.allocator());
        app.vm().transport_override = fake.transport();

        return .{ .app = app, .driver = driver, .env = env, .home = try gpa.dupe(u8, home), .arena = arena, .fake = fake };
    }

    fn stop(self: *Harness, gpa: std.mem.Allocator) void {
        self.driver.deinit();
        self.app.deinit();
        gpa.destroy(self.app);
        self.arena.deinit();
        gpa.destroy(self.arena);
        gpa.destroy(self.fake);
        self.env.deinit();
        gpa.free(self.home);
    }
};

// A scratch HOME under the test's own temp directory, so a reload reads the same file it wrote.
const Scratch = struct {
    tmp: testing.TmpDir,
    home: []u8,

    fn make(gpa: std.mem.Allocator) !Scratch {
        var tmp = testing.tmpDir(.{});
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .home = try std.fs.path.join(gpa, &.{ buf[0..len], "home" }) };
    }

    fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.home);
        self.tmp.cleanup();
    }

    // A sibling file in the same scratch tree, for the import and export panels.
    fn file(self: *Scratch, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &buf);
        return std.fs.path.join(gpa, &.{ buf[0..len], name });
    }
};

// A send answers on its own task: pump frames until it lands, then draw the answer.
fn settle(h: *Harness) !void {
    var spins: usize = 0;
    while (h.app.vm().uiState().sending) : (spins += 1) {
        if (spins > 5_000) return error.RequestNeverAnswered;
        std.Io.sleep(testing.io, .fromMilliseconds(2), .awake) catch {};
        h.driver.frame();
    }
    h.driver.frame();
}

// Open the trigger if needed, then click the verb's row: a list row is a Clay pair id, so it is hit by box.
fn pickMethod(h: *Harness, index: usize) !void {
    if (!h.app.vm().uiState().method_open) try h.driver.click(view_model.method_trigger_id);
    if (!h.app.vm().uiState().method_open) return error.MenuDidNotOpen;
    const row = glinlandui.frame.bounds(glinlandui.components.list.rowId(view_model.method_list_id, index)) orelse
        return error.ElementNotFound;
    h.driver.clickAt(row.x + row.width * 0.5, row.y + row.height * 0.5);
}

// The "+ New" menu: the button opens the card, and a list row is a Clay pair id, so it is hit by its box.
fn newMenu(h: *Harness, index: usize) !void {
    if (!h.app.vm().uiState().new_menu_open) try h.driver.click(view_model.new_trigger_id);
    if (!h.app.vm().uiState().new_menu_open) return error.MenuDidNotOpen;
    try pickCardRow(h, view_model.new_list_id, index);
}

// The workspace menu behind the gear, same shape.
fn workspaceMenu(h: *Harness, index: usize) !void {
    if (!h.app.vm().uiState().ws_menu_open) try h.driver.click(view_model.ws_trigger_id);
    if (!h.app.vm().uiState().ws_menu_open) return error.MenuDidNotOpen;
    try pickCardRow(h, view_model.ws_list_id, index);
}

fn pickCardRow(h: *Harness, list_id: []const u8, index: usize) !void {
    const row = glinlandui.frame.bounds(glinlandui.components.list.rowId(list_id, index)) orelse
        return error.ElementNotFound;
    h.driver.clickAt(row.x + row.width * 0.5, row.y + row.height * 0.5);
}

test "the acceptance path: a workspace, a collection, a folder, a request, send, and the response on screen" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    // An empty first run tells the user what to do next.
    try h.driver.expectText("No collections yet.");
    try testing.expectEqual(@as(usize, 0), h.app.vm().uiState().rows.len);

    // A collection, a folder and a request, each through the button the view declares.
    try newMenu(&h, 0);
    try newMenu(&h, 2);
    try newMenu(&h, 1);
    try testing.expectEqual(@as(usize, 3), h.app.vm().uiState().rows.len);
    try h.driver.expectText("Request 1");

    // A URL typed into the real field, one keystroke at a time.
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/v1/charges");
    try testing.expectEqualStrings("https://api.example.com/v1/charges", h.app.vm().uiState().url);

    // POST from the method dropdown, then Send.
    try pickMethod(&h, 1);
    try testing.expectEqualStrings("POST", h.app.vm().uiState().method);
    try testing.expect(!h.app.vm().uiState().method_open);

    h.fake.status = 201;
    h.fake.body = "{\"id\":7,\"paid\":true}";
    try h.driver.click("kurir.send");
    try settle(&h);

    // What was sent, and what the pane then draws.
    try testing.expectEqualStrings("POST", h.fake.last_method);
    try testing.expectEqualStrings("https://api.example.com/v1/charges", h.fake.last_url);
    try h.driver.expectText("201 Created");
    try h.driver.expectText("  \"id\": 7,");
    try testing.expectEqual(kurirw.state.ResponseKind.ok, h.app.vm().uiState().response.kind);
}

test "a slow request does not block the frame: the window keeps drawing and the button says so" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/slow");

    // A server that takes its time.
    h.fake.delay_ms = 120;
    h.fake.io = testing.io;
    h.fake.body = "{\"slow\":true}";

    try h.driver.click("kurir.send");

    // The click returned with the request still out, and the frame that drew it could read the state.
    try testing.expect(h.app.vm().uiState().sending);
    try h.driver.expectText("Sending...");

    // The window is alive while it waits: a pointer move draws another frame, and the request is still out.
    h.driver.move(640, 420);
    try testing.expect(h.app.vm().uiState().sending);

    try settle(&h);
    try testing.expect(!h.app.vm().uiState().sending);
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().response.body, "slow") != null);
    try h.driver.expectText("200 OK");
}

test "a one-megabyte answer is kept whole and drawn from the top" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/big");

    // One megabyte of JSON the size of the demo file, with the same shape: many short lines.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "[\n");
    while (body.items.len < 1024 * 1024) {
        try body.appendSlice(gpa, "  { \"name\": \"Adeel Solangi\", \"language\": \"Sindhi\", \"id\": \"V59OF92YF627HFY0\" },\n");
    }
    try body.appendSlice(gpa, "]\n");
    h.fake.body = body.items;

    try h.driver.click("kurir.send");
    try settle(&h);

    const state = h.app.vm().uiState();
    try testing.expectEqual(kurirw.state.ResponseKind.ok, state.response.kind);
    // Every byte is there: a body is not capped, whatever its size.
    try testing.expect(state.response.body.len >= 1024 * 1024);
    try testing.expect(state.response.lines.len > 10_000);
    // And the pane draws the top of it, not twenty-five thousand text runs: "[" then the first record.
    try h.driver.expectText("[");
    try h.driver.expectText("  { \"name\": \"Adeel Solangi\", \"language\": \"Sindhi\", \"id\": \"V59OF92YF627HFY0\" },");
}

test "each endpoint keeps its own result, so the pane follows the selection" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);

    // Endpoint one, sent.
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/one");
    h.fake.status = 200;
    h.fake.body = "{\"which\":\"one\"}";
    try h.driver.click("kurir.send");
    try settle(&h);
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().response.body, "one") != null);

    // Endpoint two was never sent, so it shows the empty pane — not endpoint one's body.
    try newMenu(&h, 1);
    try testing.expectEqual(kurirw.state.ResponseKind.none, h.app.vm().uiState().response.kind);

    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/two");
    h.fake.body = "{\"which\":\"two\"}";
    try h.driver.click("kurir.send");
    try settle(&h);
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().response.body, "two") != null);

    // Back on the first endpoint: its own result is still there.
    h.app.vm().select(kurirw.state.Path.empty.child(0).child(0));
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().response.body, "one") != null);

    // Deleting an endpoint drops every cached result, because a path can now mean another request.
    h.app.vm().select(kurirw.state.Path.empty.child(0).child(1));
    h.app.vm().deleteSelected();
    h.app.vm().select(kurirw.state.Path.empty.child(0).child(0));
    try testing.expectEqual(kurirw.state.ResponseKind.none, h.app.vm().uiState().response.kind);
}

test "the method is a dropdown: it opens under its trigger, picks a verb, and closes when the pointer leaves" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try testing.expectEqualStrings("GET", h.app.vm().uiState().method);
    try testing.expect(!h.app.vm().uiState().method_open);

    // Opened by the ONE trigger, with the whole verb list drawn in the card.
    try h.driver.click(view_model.method_trigger_id);
    try testing.expect(h.app.vm().uiState().method_open);
    try h.driver.expectText("OPTIONS");

    try pickMethod(&h, 3);
    try testing.expectEqualStrings("PATCH", h.app.vm().uiState().method);
    try testing.expect(!h.app.vm().uiState().method_open);

    // A menu with no scrim closes itself when the pointer is no longer on it.
    try h.driver.click(view_model.method_trigger_id);
    try testing.expect(h.app.vm().uiState().method_open);
    h.driver.move(640, 780);
    try testing.expect(!h.app.vm().uiState().method_open);
}

test "the sidebar resizes by dragging its line, collapses past the threshold, and reopens with a click" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try testing.expectApproxEqAbs(@as(f32, 300), h.app.vm().uiState().sidebar_width, 0.01);

    // The grab line sits on the panel's trailing edge, 300..307, and spans the window.
    h.driver.pressAt(303, 300);
    h.driver.move(383, 300);
    h.driver.releaseAt(383, 300);
    try testing.expectApproxEqAbs(@as(f32, 380), h.app.vm().uiState().sidebar_width, 0.01);
    try testing.expect(!h.app.vm().uiState().sidebar_collapsed);

    // Dragged far past the minimum it closes, instead of becoming a sliver the tool rows no longer fit in.
    h.driver.pressAt(383, 300);
    h.driver.move(40, 300);
    h.driver.releaseAt(40, 300);
    try testing.expect(h.app.vm().uiState().sidebar_collapsed);
    try testing.expectApproxEqAbs(@as(f32, 0), h.app.vm().uiState().sidebar_width, 0.01);

    // The line is still at the window's edge while the panel is shut, and a click reopens at the width it had.
    h.driver.pressAt(3, 300);
    h.driver.releaseAt(3, 300);
    try testing.expect(!h.app.vm().uiState().sidebar_collapsed);
    try testing.expectApproxEqAbs(@as(f32, 380), h.app.vm().uiState().sidebar_width, 0.01);
}

test "the filter box narrows the tree as it is typed, and the empty state says why" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.name_field_id);
    try h.driver.typeText("List charges");
    try newMenu(&h, 1);
    try h.driver.click(view_model.name_field_id);
    try h.driver.typeText("Ping");
    try testing.expectEqual(@as(usize, 3), h.app.vm().uiState().rows.len);

    // Typed into the real field: one match and the collection that holds it.
    try h.driver.click(view_model.filter_field_id);
    try h.driver.typeText("charges");
    const narrowed = h.app.vm().uiState();
    try testing.expect(narrowed.filter_active);
    try testing.expectEqual(@as(usize, 2), narrowed.rows.len);
    try h.driver.expectText("List charges");

    // A query that matches nothing explains itself instead of drawing a blank panel.
    try h.driver.typeText("zzz");
    try testing.expectEqual(@as(usize, 0), h.app.vm().uiState().rows.len);
    try h.driver.expectText("Nothing matches that filter.");
}

test "the + New and workspace menus open, act, and close when the pointer leaves" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    // The card lists every intent the old toolbar had, then one of them runs.
    try h.driver.click(view_model.new_trigger_id);
    try testing.expect(h.app.vm().uiState().new_menu_open);
    try h.driver.expectText("Collection");
    try h.driver.expectText("Import");
    try newMenu(&h, 0);
    try testing.expectEqual(@as(usize, 1), h.app.vm().uiState().rows.len);
    try testing.expect(!h.app.vm().uiState().new_menu_open);

    // The pointer leaving the button and its card closes the card: there is no scrim.
    try h.driver.click(view_model.new_trigger_id);
    try testing.expect(h.app.vm().uiState().new_menu_open);
    h.driver.move(1200, 760);
    try testing.expect(!h.app.vm().uiState().new_menu_open);

    // The workspace menu: a new workspace switches to it, so the tree changes with it.
    try h.driver.click(view_model.ws_trigger_id);
    try testing.expect(h.app.vm().uiState().ws_menu_open);
    try h.driver.expectText("New workspace");
    // The card hangs from the header row and stays inside the panel: a narrow anchor clips its rows.
    const card = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.ws.panel")) orelse return error.CardNotDrawn;
    try testing.expect(card.width >= 140);
    try testing.expect(card.x >= 0 and card.x + card.width <= h.app.vm().uiState().sidebar_width + 1);
    try workspaceMenu(&h, 0);
    try testing.expectEqual(@as(usize, 2), h.app.vm().uiState().workspace_count);
    try testing.expectEqual(@as(usize, 0), h.app.vm().uiState().rows.len);
}

test "typing past the bottom of the body scrolls it: the caret never leaves the viewport" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click("kurir.tab.body");
    try h.driver.click(view_model.body_id);

    const box = glinlandui.frame.bounds(glinlandui.frame.clayId(view_model.body_scroll_id)) orelse
        return error.BodyScrollMissing;
    // The editor shows far fewer lines than the caret is about to sit past.
    try testing.expectEqual(@as(f32, 0), glinlandui.components.scroll.view(view_model.body_scroll_id).y);

    // 40 Enters: the caret ends on line 40, well below a viewport of ~18 lines.
    var i: usize = 0;
    while (i < 40) : (i += 1) _ = try h.driver.key(28);

    const scrolled = glinlandui.components.scroll.view(view_model.body_scroll_id);
    try testing.expect(scrolled.y > 0);

    // One more frame: the offset the reveal set is applied by the next layout, which is the one we then measure.
    h.driver.frame();

    // The caret's own line is inside the viewport, not below it.
    const line = h.app.vm().editor.body_field.caretLine();
    try testing.expectEqual(@as(usize, 40), line);
    const row = glinlandui.frame.bounds(glinlandui.components.input.lineBoxId(view_model.body_id, line)) orelse
        return error.LineBoxMissing;
    // The line's top is inside the viewport and at least half of the line shows; the scroll's own padding is the rest.
    try testing.expect(row.y >= box.y - 0.51);
    try testing.expect(row.y + row.height * 0.5 <= box.y + box.height + 0.51);
}

test "the response pane resizes by dragging the line above it, and clamps at both ends" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);

    const line = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.split")) orelse return error.SplitMissing;
    const editor = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.editor")) orelse return error.EditorMissing;
    const pane = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.response")) orelse return error.PaneMissing;

    // The line sits between the two panes, and the response starts at the height the state asked for.
    try testing.expectApproxEqAbs(editor.y + editor.height, line.y, 0.51);
    try testing.expectApproxEqAbs(line.y + line.height, pane.y, 0.51);
    try testing.expectApproxEqAbs(@as(f32, 320), pane.height, 0.51);

    // Drag the line up 120: the response grows by that much and the editor gives the room up.
    const grab_x = line.x + line.width * 0.5;
    const grab_y = line.y + line.height * 0.5;
    h.driver.pressAt(grab_x, grab_y);
    h.driver.move(grab_x, grab_y - 120);
    h.driver.releaseAt(grab_x, grab_y - 120);
    try testing.expectApproxEqAbs(@as(f32, 440), h.app.vm().uiState().response_h, 0.51);

    // Past the window's room it stops, so the editor keeps its floor rather than being squeezed out.
    const moved = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.split")) orelse return error.SplitMissing;
    h.driver.pressAt(grab_x, moved.y + moved.height * 0.5);
    h.driver.move(grab_x, moved.y + 900);
    h.driver.releaseAt(grab_x, moved.y + 900);
    try testing.expectApproxEqAbs(@as(f32, 120), h.app.vm().uiState().response_h, 0.51);

    // And the pane the frame drew is the height the state says, not a stale one.
    const shrunk = glinlandui.frame.bounds(glinlandui.frame.clayId("kurir.response")) orelse return error.PaneMissing;
    try testing.expectApproxEqAbs(@as(f32, 120), shrunk.height, 0.51);
}

test "the empty state itself is a button: clicking it creates the first collection" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try h.driver.expectText("No collections yet.");
    try h.driver.click("kurir.tree.empty");
    try testing.expectEqual(@as(usize, 1), h.app.vm().uiState().rows.len);
    try h.driver.expectText("Collection 1");
}

test "a refused connection says so on screen, and never leaves the pane blank" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("http://127.0.0.1:1/");

    h.fake.failure_name = "ConnectionRefused";
    try h.driver.click("kurir.send");
    try settle(&h);

    try h.driver.expectText("ConnectionRefused");
    const state = h.app.vm().uiState();
    try testing.expectEqual(kurirw.state.ResponseKind.failed, state.response.kind);
    try testing.expect(state.response.error_message.len > 20);
    try testing.expect(state.status_is_error);
}

test "a request with no URL explains itself instead of sending an empty one" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click("kurir.send");
    try settle(&h);

    try testing.expectEqual(@as(usize, 0), h.fake.sends);
    const state = h.app.vm().uiState();
    try testing.expect(state.status_is_error);
    try testing.expect(std.mem.indexOf(u8, state.status, "no URL") != null);
}

test "the body is a multiline field: Enter types a line with the caret on it, Ctrl+Enter sends" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/v1/charges");

    // The body tab, then the field itself: a click places the caret and takes the keyboard.
    try h.driver.click("kurir.tab.body");
    try h.driver.click(view_model.body_id);
    try h.driver.typeText("ab");
    try testing.expectEqualStrings("ab", h.app.vm().uiState().body);

    // Enter types a line rather than submitting, and the caret is drawn on the line it created.
    _ = try h.driver.key(28);
    try testing.expectEqualStrings("ab\n", h.app.vm().uiState().body);
    try testing.expect(caretOnLine(&h.driver, 1));
    try testing.expect(!caretOnLine(&h.driver, 0));

    // Ctrl+Enter is the send gesture, and it keeps the draft where it was.
    _ = h.driver.host.onKeyEvent(29, true);
    _ = try h.driver.key(28);
    _ = h.driver.host.onKeyEvent(29, false);
    try settle(&h);
    try testing.expectEqual(@as(usize, 1), h.fake.sends);
    try testing.expectEqualStrings("ab\n", h.app.vm().uiState().body);
    try h.driver.expectText("200 OK");
}

test "paste goes through the field's clipboard and lands in the model, newlines and all" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click("kurir.tab.body");
    try h.driver.click(view_model.body_id);

    // A scripted pasteboard: the real one belongs to the machine running the test.
    h.app.vm().editor.body_field.clipboard = .{ .read_fn = clipRead, .write_fn = clipWrite };
    clipSet("{\n  \"a\": 1\n}");

    _ = h.driver.host.onKeyEvent(29, true);
    _ = try h.driver.key(47);
    _ = h.driver.host.onKeyEvent(29, false);

    try testing.expectEqualStrings("{\n  \"a\": 1\n}", h.app.vm().uiState().body);
    // And the draft the field shows is the same text.
    try testing.expectEqualStrings("{\n  \"a\": 1\n}", h.app.vm().editor.body_field.text());
}

var clip_buf: [512]u8 = undefined;
var clip_len: usize = 0;

fn clipSet(text: []const u8) void {
    clip_len = @min(text.len, clip_buf.len);
    @memcpy(clip_buf[0..clip_len], text[0..clip_len]);
}

fn clipRead(_: ?*anyopaque, buf: []u8) []const u8 {
    const n = @min(clip_len, buf.len);
    @memcpy(buf[0..n], clip_buf[0..n]);
    return buf[0..n];
}

fn clipWrite(_: ?*anyopaque, text: []const u8) void {
    clipSet(text);
}

// The caret bar a multiline field draws on one of its lines.
fn caretOnLine(driver: *Driver, line: usize) bool {
    const caret = glinlandui.components.input.lineCaretId(view_model.body_id, line);
    for (driver.commands()) |cmd| {
        if (cmd.command_type == .rectangle and cmd.id == caret.id) return true;
    }
    return false;
}

test "a reload restores the tree and the request the user was editing" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    {
        var h = try Harness.boot(gpa, scratch.home);
        defer h.stop(gpa);

        try newMenu(&h, 0);
        try newMenu(&h, 1);
        try h.driver.click(view_model.name_field_id);
        try h.driver.typeText("Charge");
        try h.driver.click(view_model.url_field_id);
        try h.driver.typeText("https://api.example.com/v1/charges");
        try pickMethod(&h, 2);
        try testing.expectEqualStrings("PUT", h.app.vm().uiState().method);
    }

    // A fresh process: same HOME, so the same file.
    var again = try Harness.boot(gpa, scratch.home);
    defer again.stop(gpa);

    const state = again.app.vm().uiState();
    try testing.expectEqual(@as(usize, 2), state.rows.len);
    try testing.expectEqualStrings("Collection 1", state.rows[0].label);
    try testing.expectEqualStrings("Charge", state.rows[1].label);
    try testing.expectEqualStrings("PUT", state.method);
    try testing.expectEqualStrings("https://api.example.com/v1/charges", state.url);
    try again.driver.expectText("Charge");
}

test "export writes a Postman v2.1 collection, and import reads it back into the tree" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    const export_path = try scratch.file(gpa, "Payments.postman_collection.json");
    defer gpa.free(export_path);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    // A collection with one real request inside it.
    try newMenu(&h, 0);
    try h.driver.click(view_model.name_field_id);
    try h.driver.typeText("Payments");
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/v1/charges");

    // The file panel is replaced by a scripted answer, so no window is opened.
    var dialogs = DialogsFake{ .save_path = export_path };
    h.app.container.dialogs = .{
        .ctx = &dialogs,
        .open_fn = dialogsOpen,
        .save_fn = dialogsSave,
        .available = true,
    };

    try workspaceMenu(&h, 2);
    try testing.expectEqual(@as(usize, 1), dialogs.saves);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, export_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const exported = try postman.parseTree(arena_state.allocator(), bytes);
    try testing.expect(postman.isCollection(exported));
    try testing.expectEqualStrings("Payments", postman.str(exported.object.get("info").?, "name"));
    try testing.expectEqualStrings(postman.schema_url, postman.str(exported.object.get("info").?, "schema"));
    try testing.expectEqual(@as(usize, 1), postman.itemCount(exported));
    // The request inside it is intact: the URL round-tripped into the Postman url object.
    const request = postman.itemAt(exported, 0).?;
    try testing.expectEqualStrings("https://api.example.com/v1/charges", postman.urlRaw(request.object.get("request").?));

    // Import the same file back: the tree grows by one collection, and the frame shows it.
    var import_dialogs = DialogsFake{ .open_path = export_path };
    h.app.container.dialogs = .{
        .ctx = &import_dialogs,
        .open_fn = dialogsOpen,
        .save_fn = dialogsSave,
        .available = true,
    };
    try newMenu(&h, 3);
    try testing.expectEqual(@as(usize, 1), import_dialogs.opens);
    try testing.expectEqual(@as(usize, 1), store_mod.collectionCount(h.app.vm().session.doc, 0) - 1);
    try h.driver.expectText("Payments");
}

const DialogsFake = struct {
    open_path: []const u8 = "",
    save_path: []const u8 = "",
    opens: usize = 0,
    saves: usize = 0,
};

fn dialogsOpen(ctx: ?*anyopaque, gpa: std.mem.Allocator, title: []const u8) ?[]const u8 {
    _ = title;
    const self: *DialogsFake = @ptrCast(@alignCast(ctx.?));
    self.opens += 1;
    if (self.open_path.len == 0) return null;
    return gpa.dupe(u8, self.open_path) catch null;
}

fn dialogsSave(ctx: ?*anyopaque, gpa: std.mem.Allocator, title: []const u8, suggested: []const u8) ?[]const u8 {
    _ = title;
    _ = suggested;
    const self: *DialogsFake = @ptrCast(@alignCast(ctx.?));
    self.saves += 1;
    if (self.save_path.len == 0) return null;
    return gpa.dupe(u8, self.save_path) catch null;
}

test "a curl command becomes a request in the tree, and the same request copies back out as curl" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    // A collection to import into, created through the button a user presses.
    try newMenu(&h, 0);
    const rows_before = h.app.vm().uiState().rows.len;

    // The import the "+ New → From cURL" row runs, with the clipboard handed in (a test build has no pasteboard).
    const command =
        "curl -X POST https://api.example.com/v1/items \\\n" ++
        "  -H 'content-type: application/json' \\\n" ++
        "  -d '{\"name\":\"widget\"}'";
    h.app.vm().addRequestFromCurlText(command);
    h.driver.frame();

    // The tree grew by one, named after the URL's own last segment.
    try testing.expectEqual(rows_before + 1, h.app.vm().uiState().rows.len);
    try h.driver.expectText("items");

    // The editor shows what the command said, because the document itself carries it.
    try testing.expectEqualStrings("POST", h.app.vm().uiState().method);
    try testing.expectEqualStrings("https://api.example.com/v1/items", h.app.vm().uiState().url);
    try testing.expectEqualStrings("{\"name\":\"widget\"}", h.app.vm().uiState().body);
    try testing.expectEqual(@as(usize, 1), h.app.vm().uiState().headers.len);
    try testing.expectEqualStrings("content-type", h.app.vm().uiState().headers[0].name);

    // And the round trip closes: the cURL button writes the request back out as a command.
    try h.driver.click("kurir.curl.copy");
    const text = h.app.vm().editor.last_curl;
    try testing.expect(std.mem.indexOf(u8, text, "-X POST") != null);
    try testing.expect(std.mem.indexOf(u8, text, "https://api.example.com/v1/items") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--data-raw") != null);
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().status, "Copied as cURL") != null);
}

test "a command that is not curl leaves the tree alone and says why" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    const rows_before = h.app.vm().uiState().rows.len;

    h.app.vm().addRequestFromCurlText("wget https://example.com/");
    h.driver.frame();
    try testing.expectEqual(rows_before, h.app.vm().uiState().rows.len);
    try testing.expect(std.mem.indexOf(u8, h.app.vm().uiState().status, "not a curl command") != null);
}

test "the response body is one text surface: select all, copy, and typing cannot change it" {
    const gpa = std.heap.page_allocator;
    var scratch = try Scratch.make(gpa);
    defer scratch.deinit(gpa);

    var h = try Harness.boot(gpa, scratch.home);
    defer h.stop(gpa);

    try newMenu(&h, 0);
    try newMenu(&h, 1);
    try h.driver.click(view_model.url_field_id);
    try h.driver.typeText("https://api.example.com/v1/items");

    h.fake.status = 200;
    h.fake.body = "{\"id\":7,\"name\":\"widget\"}";
    try h.driver.click("kurir.send");
    try settle(&h);

    const shown = h.app.vm().uiState().response.body;
    try testing.expect(shown.len > 0);

    // Click into the body: it is a field, so it takes the caret and the keyboard like any other.
    try h.driver.click(kurirw.response_vm.body_text_id);
    h.app.vm().response.body_field.clipboard = .{ .write_fn = clipWrite };
    clipSet("");

    // Select all, copy: the whole body reaches the pasteboard.
    _ = h.driver.host.onKeyEvent(29, true);
    _ = try h.driver.key(30);
    _ = try h.driver.key(46);
    _ = h.driver.host.onKeyEvent(29, false);
    try testing.expectEqualStrings(shown, clip_buf[0..clip_len]);

    // And it is READ ONLY: typing, Enter and Backspace leave both the model and the field alone.
    _ = try h.driver.key(31);
    _ = try h.driver.key(28);
    _ = try h.driver.key(14);
    try testing.expectEqualStrings(shown, h.app.vm().uiState().response.body);
    try testing.expectEqualStrings(shown, h.app.vm().response.body_field.text());
}
