//! Effect iterators ℑΓ (Definition 17) and the execute engine (Algorithm 1).
//!
//! Paper correspondence:
//!   - Definition 17 (Effect Iterator ℑΓ):
//!       ℑΓ ≔ μℑ. Γ → Γ × (Γ → Γ) × Maybe(ℑ)
//!     Each iteration, applied to γ, yields a triple (δ, g, o):
//!       • δ : the new context;
//!       • g : the inverse of the current effect;
//!       • o : the continuation — Nothing ends iteration, Just(i') continues.
//!     The witness holds each iteration to the same equation as Def 8: g(δ)=γ.
//!   - Definition 18 (effectiter): composes each inverse onto φ in application
//!     order, so φ reverts the effects in LIFO order (Theorem 16).
//!   - A plain effect function (Def 8) is the degenerate iterator whose first
//!     iteration already yields Nothing (Eq. 19).
//!   - §5.1.1 Algorithm 1 (execute): drives the iterator, folds each yielded
//!     inverse into one composite recover, and consults a caller-supplied guard
//!     before each step. Once the guard trips, iteration stops and only the
//!     inverses accumulated so far remain — the step-boundary interruption of
//!     §4.2.2 (L-Divert), realized by the Maybe(ℑ) continuation + guard.
//!
//! Zig note (plan C1/C2): no closures, no async. The iterator is an explicit
//! object with a `next` fn pointer over mutable state; the guard is a
//! fn-pointer + state pair the engine polls at each step boundary.

const std = @import("std");
const acc = @import("accumulator.zig");

/// One step produced by an effect iterator (the (δ, g, o) triple of Def 17).
/// The forward map has already mutated `ctx` in place; `inverse` reverts THIS
/// step; `done` is the Maybe continuation (true = Nothing, false = Just(next)).
pub fn Step(comptime Ctx: type) type {
    return struct {
        inverse: acc.Inverse(Ctx),
        done: bool,
    };
}

/// An effect iterator ℑΓ (Definition 17), closure-free.
///
/// `next` advances one iteration: it performs the forward map on `ctx`, returns
/// the step's inverse and whether iteration is finished. `deinit` releases the
/// iterator's own captured state once driving is complete.
pub fn Iterator(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        state: *anyopaque,
        next_fn: *const fn (state: *anyopaque, allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Step(Ctx),
        deinit_fn: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,

        pub fn next(self: Self, allocator: std.mem.Allocator, ctx: *Ctx) !Step(Ctx) {
            return self.next_fn(self.state, allocator, ctx);
        }
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            self.deinit_fn(self.state, allocator);
        }
    };
}

/// A guard the engine polls before each step (Algorithm 1's `guard()`).
/// Returning false stops iteration at the next boundary — the realization of
/// L-Divert's step-boundary interruption and ctx.effect's `armed` self-disposal.
pub const Guard = struct {
    state: *anyopaque,
    poll: *const fn (state: *anyopaque) bool,

    pub fn active(self: Guard) bool {
        return self.poll(self.state);
    }

    /// A guard that is always active (never interrupts).
    pub fn always() Guard {
        const Impl = struct {
            fn poll(_: *anyopaque) bool {
                return true;
            }
        };
        return .{ .state = undefined, .poll = Impl.poll };
    }
};

/// Algorithm 1 (execute): drive `iter` to completion (or until `guard` trips),
/// tracking each yielded inverse onto `accumulator` in application order.
/// After this returns, `accumulator` holds the composite recover (φ) that
/// undoes the installed effects in LIFO order (Definition 18, Theorem 16).
///
/// Interruption semantics: the guard is polled BEFORE each step. If it is
/// inactive, iteration stops immediately and only the inverses accumulated so
/// far remain tracked — matching Alg 1 lines 4–7 and the §4.2.2 boundary.
pub fn execute(
    comptime Ctx: type,
    iter: Iterator(Ctx),
    guard: Guard,
    allocator: std.mem.Allocator,
    ctx: *Ctx,
    accumulator: *acc.Accumulator(Ctx),
) !void {
    while (guard.active()) {
        const step = try iter.next(allocator, ctx);
        try accumulator.track(step.inverse);
        if (step.done) break;
    }
}

// ───────────────────────────── Tests ─────────────────────────────

const TestCtx = struct { value: i64 };

/// An iterator that applies a fixed slice of deltas, one per iteration,
/// yielding Nothing after the last. Each step's inverse subtracts its delta.
const DeltaIter = struct {
    deltas: []const i64,
    pos: usize,

    fn make(allocator: std.mem.Allocator, deltas: []const i64) !Iterator(TestCtx) {
        const self = try allocator.create(DeltaIter);
        self.* = .{ .deltas = deltas, .pos = 0 };
        return .{ .state = self, .next_fn = nextFn, .deinit_fn = deinitFn };
    }

    fn nextFn(state: *anyopaque, allocator: std.mem.Allocator, ctx: *TestCtx) anyerror!Step(TestCtx) {
        const self: *DeltaIter = @ptrCast(@alignCast(state));
        const d = self.deltas[self.pos];
        ctx.value += d;
        self.pos += 1;

        const inv_state = try allocator.create(i64);
        inv_state.* = d;
        const inverse = acc.Inverse(TestCtx){ .state = inv_state, .call = invCall, .deinit = invDeinit };
        return .{ .inverse = inverse, .done = self.pos >= self.deltas.len };
    }
    fn invCall(state: *anyopaque, ctx: *TestCtx) void {
        const d: *i64 = @ptrCast(@alignCast(state));
        ctx.value -= d.*;
    }
    fn invDeinit(state: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*i64, @ptrCast(@alignCast(state))));
    }
    fn deinitFn(state: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*DeltaIter, @ptrCast(@alignCast(state))));
    }
};

test "Definition 17/18: iterator runs to completion and φ recovers (Thm 7)" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 0 };
    var accumulator = acc.Accumulator(TestCtx).init(allocator);
    defer accumulator.deinit();

    const iter = try DeltaIter.make(allocator, &.{ 4, 8, 15, 16 });
    defer iter.deinit(allocator);

    try execute(TestCtx, iter, Guard.always(), allocator, &ctx, &accumulator);
    try std.testing.expectEqual(@as(i64, 43), ctx.value);
    try std.testing.expectEqual(@as(usize, 4), accumulator.len);

    accumulator.recover(&ctx);
    try std.testing.expectEqual(@as(i64, 0), ctx.value);
}

test "Algorithm 1: guard interrupts at a step boundary, keeping prior inverses" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 0 };
    var accumulator = acc.Accumulator(TestCtx).init(allocator);
    defer accumulator.deinit();

    const iter = try DeltaIter.make(allocator, &.{ 10, 20, 30, 40 });
    defer iter.deinit(allocator);

    // Guard trips after 2 steps have been tracked (polls before each step).
    const Counting = struct {
        remaining: usize,
        fn poll(state: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(state));
            if (self.remaining == 0) return false;
            self.remaining -= 1;
            return true;
        }
    };
    var g = Counting{ .remaining = 2 };
    const guard = Guard{ .state = &g, .poll = Counting.poll };

    try execute(TestCtx, iter, guard, allocator, &ctx, &accumulator);
    // Only two steps ran before the guard went inactive.
    try std.testing.expectEqual(@as(i64, 30), ctx.value);
    try std.testing.expectEqual(@as(usize, 2), accumulator.len);

    // The inverses accumulated so far still recover those two effects.
    accumulator.recover(&ctx);
    try std.testing.expectEqual(@as(i64, 0), ctx.value);
}

test "Eq. 19: a single-step iterator is the degenerate effect function" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 100 };
    var accumulator = acc.Accumulator(TestCtx).init(allocator);
    defer accumulator.deinit();

    const iter = try DeltaIter.make(allocator, &.{-25});
    defer iter.deinit(allocator);

    try execute(TestCtx, iter, Guard.always(), allocator, &ctx, &accumulator);
    try std.testing.expectEqual(@as(i64, 75), ctx.value);
    try std.testing.expectEqual(@as(usize, 1), accumulator.len);
}
