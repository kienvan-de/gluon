//! The lifecycle scheduler seam (roadmap #6, step 2) — a Gluon-owned
//! abstraction isolating `std.Io` from the orchestrator.
//!
//! The orchestrator speaks only this vocabulary (spawn / await / cancel), so
//! the churn-exposed `std.Io` surface lives behind one backend. See
//! plan/async-inertia-design.md.
//!
//! Backends:
//!   - `.blocking` (this file): runs each task inline on spawn; await/cancel
//!     just return the stored result. ZERO `std.Io` dependency — this is the
//!     synchronous, run-to-completion schedule the paper proves is one valid
//!     schedule among all (every §4.3 result quantifies over schedules).
//!   - `.evented` (step 3): wraps `std.Io` async/await/cancel.
//!
//! Closure-free (plan C1): a task is a `{run, state}` pair; the result is a
//! `TaskResult`. A `CancelToken` is the cooperative cancelation point a running
//! task polls at step boundaries (the paper's "abort at an iteration boundary",
//! §4.2.2 L-Divert). In `.blocking` the token never trips mid-run.

const std = @import("std");

/// The result a lifecycle task produces: success, or a lifecycle error.
/// Kept as an explicit error union (not `anyerror`) to match the orchestrator's
/// LifecycleError without importing it here (decoupling).
pub const TaskResult = error{
    OutOfMemory,
    NoSuchFiber,
    NonCommutativeProvision,
}!void;

/// A running task's body: performs the transition work, polling `token` at step
/// boundaries so it can abort cooperatively (L-Divert). Closure-free: `state`
/// carries whatever the body needs (typically an orchestrator + fiber pair).
pub const TaskFn = *const fn (state: *anyopaque, token: *const CancelToken) TaskResult;

/// A cooperative cancelation point. A running task calls `requested()` at step
/// boundaries; if true, it should stop and unwind (leaving its accumulator to
/// recover whatever was installed — Cor 69). In `.blocking`, `requested()` is
/// always false during a run (there is no concurrent canceler).
pub const CancelToken = struct {
    flag: *const bool,

    pub fn requested(self: *const CancelToken) bool {
        return self.flag.*;
    }
};

/// A handle to an in-flight (or, in `.blocking`, already-complete) task.
/// Opaque to the orchestrator beyond await/cancel via the Scheduler.
pub const Task = struct {
    /// Backend-private handle. For `.blocking` it points at a BlockingTask.
    handle: *anyopaque,
};

/// The scheduler seam. The orchestrator holds one and routes every lifecycle
/// transition through spawn/await/cancel.
pub const Scheduler = struct {
    const Self = @This();

    vtable: *const VTable,
    context: *anyopaque,

    pub const VTable = struct {
        /// Start `run(state, token)` as a task. `.blocking` runs it inline and
        /// returns a completed Task; `.evented` spawns it concurrently.
        spawn: *const fn (context: *anyopaque, run: TaskFn, state: *anyopaque) std.mem.Allocator.Error!Task,
        /// Block until `task` completes; return its result. Frees the task.
        awaitTask: *const fn (context: *anyopaque, task: Task) TaskResult,
        /// Request cooperative cancelation, then await; return the (possibly
        /// partial) result. Frees the task.
        cancelTask: *const fn (context: *anyopaque, task: Task) TaskResult,
        /// Run `run(state, token)` to completion for a MUST-COMPLETE,
        /// allocation-free operation (e.g. teardown/recover). It cannot fail to
        /// schedule: `.blocking` runs it inline; `.evented` runs it on the
        /// current fiber so an async teardown still suspends but no task handle
        /// is allocated. Returns the body's result.
        run: *const fn (context: *anyopaque, run: TaskFn, state: *anyopaque) TaskResult,
    };

    pub fn spawn(self: Self, runFn: TaskFn, state: *anyopaque) !Task {
        return self.vtable.spawn(self.context, runFn, state);
    }
    pub fn awaitTask(self: Self, task: Task) TaskResult {
        return self.vtable.awaitTask(self.context, task);
    }
    pub fn cancelTask(self: Self, task: Task) TaskResult {
        return self.vtable.cancelTask(self.context, task);
    }
    /// Run a must-complete, allocation-free body to completion (teardown).
    pub fn run(self: Self, runFn: TaskFn, state: *anyopaque) TaskResult {
        return self.vtable.run(self.context, runFn, state);
    }
};

// ───────────────────────── .blocking backend ─────────────────────────

/// A completed task: the result captured when spawn ran the body inline.
const BlockingTask = struct {
    result: TaskResult,
};

/// The synchronous, run-to-completion scheduler. Spawning runs the body
/// immediately with a never-tripping cancel token; await/cancel return the
/// captured result. No `std.Io`, no concurrency.
pub const Blocking = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// A stable `false` the never-tripping CancelToken points at.
    never: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Obtain a Scheduler bound to this Blocking backend. The returned
    /// Scheduler borrows `self`, which must outlive it.
    pub fn scheduler(self: *Self) Scheduler {
        return .{ .vtable = &vtable, .context = self };
    }

    const vtable = Scheduler.VTable{
        .spawn = spawnImpl,
        .awaitTask = awaitImpl,
        .cancelTask = cancelImpl,
        .run = runImpl,
    };

    fn runImpl(context: *anyopaque, runFn: TaskFn, state: *anyopaque) TaskResult {
        const self: *Self = @ptrCast(@alignCast(context));
        const token = CancelToken{ .flag = &self.never };
        return runFn(state, &token); // inline, no allocation
    }

    fn spawnImpl(context: *anyopaque, run: TaskFn, state: *anyopaque) std.mem.Allocator.Error!Task {
        const self: *Self = @ptrCast(@alignCast(context));
        const bt = try self.allocator.create(BlockingTask);
        const token = CancelToken{ .flag = &self.never };
        bt.* = .{ .result = run(state, &token) }; // run inline, to completion
        return .{ .handle = bt };
    }

    fn awaitImpl(context: *anyopaque, task: Task) TaskResult {
        const self: *Self = @ptrCast(@alignCast(context));
        const bt: *BlockingTask = @ptrCast(@alignCast(task.handle));
        defer self.allocator.destroy(bt);
        return bt.result;
    }

    fn cancelImpl(context: *anyopaque, task: Task) TaskResult {
        // In .blocking the body already ran to completion before spawn
        // returned, so there is nothing to interrupt; return its result.
        return awaitImpl(context, task);
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const Counter = struct {
    n: u32 = 0,
    saw_cancel: bool = false,
    fn run(state: *anyopaque, token: *const CancelToken) TaskResult {
        const self: *Counter = @ptrCast(@alignCast(state));
        self.n += 1;
        self.saw_cancel = token.requested();
    }
};

test "blocking scheduler runs the task inline on spawn" {
    var backend = Blocking.init(std.testing.allocator);
    const sched = backend.scheduler();

    var c = Counter{};
    const task = try sched.spawn(Counter.run, &c);
    try std.testing.expectEqual(@as(u32, 1), c.n); // already ran before await
    try sched.awaitTask(task);
    try std.testing.expectEqual(@as(u32, 1), c.n);
    try std.testing.expect(!c.saw_cancel); // token never trips in .blocking
}

test "blocking scheduler: await returns the task result" {
    var backend = Blocking.init(std.testing.allocator);
    const sched = backend.scheduler();

    const Failing = struct {
        fn run(_: *anyopaque, _: *const CancelToken) TaskResult {
            return error.NoSuchFiber;
        }
    };
    var dummy: u8 = 0;
    const task = try sched.spawn(Failing.run, &dummy);
    try std.testing.expectError(error.NoSuchFiber, sched.awaitTask(task));
}

test "blocking scheduler: cancel returns the (already complete) result" {
    var backend = Blocking.init(std.testing.allocator);
    const sched = backend.scheduler();
    var c = Counter{};
    const task = try sched.spawn(Counter.run, &c);
    try sched.cancelTask(task); // nothing to interrupt; returns success
    try std.testing.expectEqual(@as(u32, 1), c.n);
}

fn schedulerUnderOom(allocator: std.mem.Allocator) !void {
    var backend = Blocking.init(allocator);
    const sched = backend.scheduler();
    var c = Counter{};
    const task = try sched.spawn(Counter.run, &c);
    try sched.awaitTask(task);
}

test "OOM safety: blocking spawn/await leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, schedulerUnderOom, .{});
}
