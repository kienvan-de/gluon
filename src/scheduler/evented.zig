//! The `.evented` scheduler backend (roadmap #6, step 3) — wraps Zig 0.16's
//! `std.Io` so lifecycle transitions can suspend (async teardown) and be
//! cancelled cooperatively (L-Divert). Isolated here so churn in `std.Io`
//! touches only this file; the orchestrator never imports `std.Io`.
//!
//! Mapping (see plan/async-inertia-design.md §3):
//!   - spawn(run, state)  → io.async(entry, .{boxed}) → Future(TaskResult)
//!   - awaitTask(task)     → future.await(io)
//!   - cancelTask(task)    → set our cooperative flag, then future.cancel(io)
//!   - run(run, state)     → inline (must-complete teardown; suspends via the
//!                           inverses' own `io` use, no task handle allocated)
//!
//! Cancelation is dual: our `CancelToken` is a bool the task body polls at step
//! boundaries (the paper's "abort at an iteration boundary", §4.2.2), AND
//! `future.cancel` places std.Io's cancelation request so any `Io` call in the
//! task also surfaces `error.Canceled`. Setting our flag first guarantees the
//! next step boundary trips even if the body does no `Io` calls.

const std = @import("std");
const sched = @import("scheduler.zig");

pub const Scheduler = sched.Scheduler;
pub const Task = sched.Task;
pub const TaskFn = sched.TaskFn;
pub const TaskResult = sched.TaskResult;
pub const CancelToken = sched.CancelToken;

/// Per-task heap state: the body + its args, the cooperative cancel flag, and
/// the in-flight Future. Boxed so its address is stable across suspension.
const EventedTask = struct {
    run: TaskFn,
    state: *anyopaque,
    cancel_flag: bool,
    future: std.Io.Future(TaskResult),
};

/// The `.evented` backend. Holds an `io: std.Io` (from `std.Io.Threaded`,
/// `std.Io.Evented`, etc.) and an allocator for task handles.
pub const Evented = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn scheduler(self: *Self) Scheduler {
        return .{ .vtable = &vtable, .context = self };
    }

    const vtable = Scheduler.VTable{
        .spawn = spawnImpl,
        .awaitTask = awaitImpl,
        .cancelTask = cancelImpl,
        .run = runImpl,
    };

    /// The async entry point: runs the task body with a CancelToken bound to
    /// the task's own flag. Returns the body's TaskResult (stored in the
    /// Future by std.Io).
    fn entry(et: *EventedTask) TaskResult {
        const token = CancelToken{ .flag = &et.cancel_flag };
        return et.run(et.state, &token);
    }

    fn spawnImpl(context: *anyopaque, run: TaskFn, state: *anyopaque) std.mem.Allocator.Error!Task {
        const self: *Self = @ptrCast(@alignCast(context));
        const et = try self.allocator.create(EventedTask);
        et.* = .{ .run = run, .state = state, .cancel_flag = false, .future = undefined };
        et.future = self.io.async(entry, .{et});
        return .{ .handle = et };
    }

    fn awaitImpl(context: *anyopaque, task: Task) TaskResult {
        const self: *Self = @ptrCast(@alignCast(context));
        const et: *EventedTask = @ptrCast(@alignCast(task.handle));
        defer self.allocator.destroy(et);
        return et.future.await(self.io);
    }

    fn cancelImpl(context: *anyopaque, task: Task) TaskResult {
        const self: *Self = @ptrCast(@alignCast(context));
        const et: *EventedTask = @ptrCast(@alignCast(task.handle));
        defer self.allocator.destroy(et);
        // Trip our cooperative flag first so the next step boundary stops the
        // body even if it makes no Io call, THEN place std.Io's cancelation
        // request and collect the (possibly partial) result.
        et.cancel_flag = true;
        return et.future.cancel(self.io);
    }

    fn runImpl(_: *anyopaque, run: TaskFn, state: *anyopaque) TaskResult {
        // Must-complete teardown: run inline on the current fiber. Any async
        // work inside the body (an inverse that awaits via `io`) suspends the
        // current fiber; no separate task handle is needed. The token never
        // trips here (teardown is not cancelable).
        const never = false;
        const token = CancelToken{ .flag = &never };
        return run(state, &token);
    }
};

// ───────────────────────────── Tests ─────────────────────────────
//
// Driven on std.Io.Threaded so the backend is exercised against a real `Io`.
// These assert the SEAM contract (spawn/await/cancel/run), not lifecycle
// behavior (that is covered via the orchestrator's `.evented` integration
// tests in lifecycle.zig).

const Work = struct {
    ran: bool = false,
    cancel_seen: bool = false,
    fn body(state: *anyopaque, token: *const CancelToken) TaskResult {
        const self: *Work = @ptrCast(@alignCast(state));
        self.ran = true;
        self.cancel_seen = token.requested();
    }
};

test "evented backend: spawn + await runs the task to completion" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = Evented.init(std.testing.allocator, threaded.io());
    const s = backend.scheduler();

    var w = Work{};
    const task = try s.spawn(Work.body, &w);
    try s.awaitTask(task);
    try std.testing.expect(w.ran);
}

test "evented backend: run executes a must-complete body inline" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = Evented.init(std.testing.allocator, threaded.io());
    const s = backend.scheduler();

    var w = Work{};
    try s.run(Work.body, &w);
    try std.testing.expect(w.ran);
    try std.testing.expect(!w.cancel_seen); // teardown is not cancelable
}

test "evented backend: await returns the body result" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = Evented.init(std.testing.allocator, threaded.io());
    const s = backend.scheduler();

    const Failing = struct {
        fn body(_: *anyopaque, _: *const CancelToken) TaskResult {
            return error.NoSuchFiber;
        }
    };
    var dummy: u8 = 0;
    const task = try s.spawn(Failing.body, &dummy);
    try std.testing.expectError(error.NoSuchFiber, s.awaitTask(task));
}
