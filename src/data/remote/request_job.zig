//! One request, off the frame loop: the Io pool runs it, and the app collects the answer when it lands.
const std = @import("std");
const glinlandui = @import("glinlandui");

const http = @import("http_client.zig");
const body_mod = @import("../model/body.zig");

const Ctx = glinlandui.Ctx;

pub const Allocator = std.mem.Allocator;

pub const Job = struct {
    io: std.Io,
    // Everything the worker allocates (the URL, the headers, the body, the answer) lives here.
    arena_state: std.heap.ArenaAllocator,
    request: http.Request = .{},
    result: http.Result = .{},
    // The body as the pane shows it, re-indented and line-indexed: done here, never on the frame thread.
    shown: body_mod.Shown = .{},
    // The worker stores this LAST, so the frame loop can read `result` without a lock.
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(http.Result) = null,

    pub fn create(gpa: Allocator, io: std.Io) !*Job {
        const job = try gpa.create(Job);
        job.* = .{ .io = io, .arena_state = std.heap.ArenaAllocator.init(gpa) };
        return job;
    }

    pub fn arena(self: *Job) Allocator {
        return self.arena_state.allocator();
    }

    // Hand the request to the pool; a build with no concurrency runs it here, which is still correct.
    pub fn start(self: *Job, transport: http.Transport) void {
        self.future = std.Io.concurrent(self.io, work, .{ self, transport }) catch null;
        if (self.future == null) {
            self.finished.store(false, .release);
            _ = work(self, transport);
        }
    }

    fn work(job: *Job, transport: http.Transport) http.Result {
        const result = transport.perform(job.request);
        if (!result.failed) job.shown = body_mod.format(job.arena_state.child_allocator, job.arena(), result.body);
        job.result = result;
        job.finished.store(true, .release);
        return result;
    }

    // Safe to call from the frame loop: an acquire load, no lock and no waiting.
    pub fn poll(self: *Job) bool {
        return self.finished.load(.acquire);
    }

    // Only called once `poll` is true, so awaiting a finished task returns at once.
    pub fn take(self: *Job) http.Result {
        if (self.future) |*f| return f.await(self.io);
        return self.result;
    }

    // Joins the task before freeing it, so a quit during a request cannot free the arena the worker writes.
    pub fn destroy(self: *Job, gpa: Allocator) void {
        if (self.future) |*f| _ = f.await(self.io);
        self.future = null;
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    // On the way out, a request in flight is left to the operating system: joining would hold the window open.
    pub fn abandon(self: *Job) void {
        _ = self;
    }
};

const testing = std.testing;

// A transport that takes its time, so a job can be observed while it is still running.
const Slow = struct {
    const state = struct {
        var calls: usize = 0;
    };

    fn send(_: Ctx, arena: Allocator, req: http.Request) http.Result {
        _ = req;
        std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
        state.calls += 1;
        return .{
            .status = 200,
            .reason = "OK",
            .body = arena.dupe(u8, "{\"ok\":true}") catch "",
            .time_ms = 30,
        };
    }
};

fn waitFor(job: *Job, budget_ms: usize) !bool {
    var spent: usize = 0;
    while (spent < budget_ms) : (spent += 1) {
        if (job.poll()) return true;
        std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return job.poll();
}

test "a job runs off the calling thread, and poll reports the answer when it lands" {
    const job = try Job.create(testing.allocator, testing.io);
    defer job.destroy(testing.allocator);

    job.request = .{ .method = "GET", .url = "https://api.test/slow" };
    job.start(.{ .arena = job.arena(), .send_fn = Slow.send });

    // The call returned with the request still in flight: that is the whole point of the job.
    try testing.expect(!job.poll());
    try testing.expect(try waitFor(job, 2_000));

    const result = job.take();
    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expectEqualStrings("{\"ok\":true}", result.body);
}

test "destroying a job that is still running waits for it instead of freeing under it" {
    const job = try Job.create(testing.allocator, testing.io);
    job.request = .{ .method = "GET", .url = "https://api.test/slow" };
    job.start(.{ .arena = job.arena(), .send_fn = Slow.send });
    // No poll, no take: destroy has to join the task itself.
    job.destroy(testing.allocator);
}
