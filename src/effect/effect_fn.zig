//! Effect functions 𝔈Γ (Definition 8) and effect composition ⋄ (Definition 9).
//!
//! Paper correspondence:
//!   - Definition 8  (Effect Function 𝔈Γ):  e : Γ → Γ × (Γ → Γ).
//!     Applied to a context γ, an effect yields a pair (δ, g):
//!       • δ : the new context after the forward map;
//!       • g : the inverse of THIS effect, valid at the state it was applied.
//!     The witness (𝔈Γ*) holds g to one equation: g(δ) = γ — the inverse
//!     reverts the effect only at the state where it was applied.
//!   - Definition 9  (Effect Composition ⋄):
//!       (f ⋄ g)(γ) = let (δ,s) = g(γ) in let (ε,t) = f(δ) in (ε, s ∘ t)
//!     The right operand runs first; inverses accumulate so that recover
//!     undoes them in LIFO order (s after t  ⇒  t undone before s).
//!   - Theorem 10 (⋄ is a monoid with unit η = γ ↦ (γ, id)).
//!   - Theorem 11 (a uniform inverse g with g∘f = id witnesses at every state).
//!
//! Zig correctness note (plan C1): no closures. An effect is a value carrying
//! its captured config plus a fn pointer that, applied to a context, performs
//! the forward map AND returns a heap-owned Inverse (Def 8's g).

const std = @import("std");
const acc = @import("accumulator.zig");

/// The result of applying an effect once: the forward map has already mutated
/// `ctx` in place (in-place realization, Definition 23); `inverse` is the
/// heap-owned undo that reverts THIS application.
pub fn Applied(comptime Ctx: type) type {
    return struct {
        inverse: acc.Inverse(Ctx),
    };
}

/// An effect function e : Γ → Γ × (Γ → Γ) (Definition 8), closure-free.
///
/// `state` is the captured environment (config, target key, etc.).
/// `apply` performs the forward map on `ctx` and returns the inverse witnessing
/// g(δ) = γ. It may fail (host effects can refuse — the §4.4 Failure extension).
/// `deinit` releases `state` once the effect value itself is dropped (distinct
/// from the inverse's lifetime, which the accumulator owns after apply).
pub fn Effect(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const Inv = acc.Inverse(Ctx);

        state: *anyopaque,
        apply_fn: *const fn (state: *anyopaque, allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Inv,
        deinit_fn: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,

        /// Apply the effect: run the forward map on `ctx`, return its inverse.
        /// The returned inverse is heap-owned and must be tracked onto an
        /// accumulator (or invoked+released by the caller).
        pub fn apply(self: Self, allocator: std.mem.Allocator, ctx: *Ctx) !Inv {
            return self.apply_fn(self.state, allocator, ctx);
        }

        /// Release the effect's captured state. Does NOT touch any inverse the
        /// effect produced — those are owned by whatever tracked them.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            self.deinit_fn(self.state, allocator);
        }
    };
}

/// The unit effect η = γ ↦ (γ, id) (Theorem 10): forward map is identity, and
/// its inverse is a no-op. Carries no captured state.
pub fn unit(comptime Ctx: type) Effect(Ctx) {
    const Impl = struct {
        fn apply(_: *anyopaque, _: std.mem.Allocator, _: *Ctx) anyerror!acc.Inverse(Ctx) {
            return .{
                .state = undefined,
                .call = noopCall,
                .deinit = noopDeinit,
            };
        }
        fn noopCall(_: *anyopaque, _: *Ctx) void {}
        fn noopDeinit(_: *anyopaque, _: std.mem.Allocator) void {}
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };
    return .{
        .state = undefined,
        .apply_fn = Impl.apply,
        .deinit_fn = Impl.deinit,
    };
}

/// Apply a whole sequence of effects left-to-right, tracking each inverse onto
/// `accumulator`. This is the operational reading of iterated ⋄ (Definition 9)
/// used by component loading (Alg 1): running the sequence builds φ so that a
/// later recover undoes them in LIFO order (Theorem 16).
///
/// On failure of effect i, the inverses of effects 0..i-1 remain tracked on the
/// accumulator (the caller decides whether to recover) — matching the §4.4
/// Failure route where a raise leaves the accumulator built up to the failing
/// step.
pub fn applySequence(
    comptime Ctx: type,
    effects: []const Effect(Ctx),
    allocator: std.mem.Allocator,
    ctx: *Ctx,
    accumulator: *acc.Accumulator(Ctx),
) !void {
    for (effects) |e| {
        const inv = try e.apply(allocator, ctx);
        try accumulator.track(inv);
    }
}

// ───────────────────────────── Tests ─────────────────────────────

const TestCtx = struct { value: i64 };

/// An "add delta" effect: forward map γ ↦ γ+delta, inverse δ ↦ δ-delta.
/// g(f(γ)) = (γ+delta)-delta = γ, so it witnesses at every state (Theorem 11).
const AddEffect = struct {
    delta: i64,

    fn make(allocator: std.mem.Allocator, delta: i64) !Effect(TestCtx) {
        const self = try allocator.create(AddEffect);
        self.* = .{ .delta = delta };
        return .{ .state = self, .apply_fn = applyFn, .deinit_fn = deinitFn };
    }

    fn applyFn(state: *anyopaque, allocator: std.mem.Allocator, ctx: *TestCtx) anyerror!acc.Inverse(TestCtx) {
        const self: *AddEffect = @ptrCast(@alignCast(state));
        ctx.value += self.delta; // forward map (in-place realization)
        // Build the inverse carrying the same delta.
        const inv_state = try allocator.create(i64);
        inv_state.* = self.delta;
        return .{ .state = inv_state, .call = invCall, .deinit = invDeinit };
    }
    fn invCall(state: *anyopaque, ctx: *TestCtx) void {
        const d: *i64 = @ptrCast(@alignCast(state));
        ctx.value -= d.*;
    }
    fn invDeinit(state: *anyopaque, allocator: std.mem.Allocator) void {
        const d: *i64 = @ptrCast(@alignCast(state));
        allocator.destroy(d);
    }
    fn deinitFn(state: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AddEffect = @ptrCast(@alignCast(state));
        allocator.destroy(self);
    }
};

test "Definition 8: an effect applies its forward map and yields an inverse" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 10 };

    const e = try AddEffect.make(allocator, 5);
    defer e.deinit(allocator);

    const inv = try e.apply(allocator, &ctx);
    try std.testing.expectEqual(@as(i64, 15), ctx.value); // forward map ran

    // The witness: applying the inverse at the produced state recovers γ.
    inv.call(inv.state, &ctx);
    inv.deinit(inv.state, allocator);
    try std.testing.expectEqual(@as(i64, 10), ctx.value); // g(δ) = γ
}

test "unit effect η = γ ↦ (γ, id) leaves the context unchanged" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 7 };
    const e = unit(TestCtx);
    defer e.deinit(allocator);
    const inv = try e.apply(allocator, &ctx);
    try std.testing.expectEqual(@as(i64, 7), ctx.value);
    inv.call(inv.state, &ctx);
    inv.deinit(inv.state, allocator);
    try std.testing.expectEqual(@as(i64, 7), ctx.value);
}

test "Definition 9 / Theorem 16: a tracked sequence recovers in LIFO order" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 0 };
    var accumulator = acc.Accumulator(TestCtx).init(allocator);
    defer accumulator.deinit();

    var effects = [_]Effect(TestCtx){
        try AddEffect.make(allocator, 3),
        try AddEffect.make(allocator, 7),
        try AddEffect.make(allocator, 100),
    };
    defer for (effects) |e| e.deinit(allocator);

    try applySequence(TestCtx, &effects, allocator, &ctx, &accumulator);
    try std.testing.expectEqual(@as(i64, 110), ctx.value);

    // Recover: undoes +100, then +7, then +3 — back to γ₀ = 0 (Theorem 7).
    accumulator.recover(&ctx);
    try std.testing.expectEqual(@as(i64, 0), ctx.value);
    try std.testing.expect(accumulator.isIdentity());
}

test "partial sequence failure leaves prior inverses tracked (4.4 Failure)" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 0 };
    var accumulator = acc.Accumulator(TestCtx).init(allocator);
    defer accumulator.deinit();

    // An effect that always fails on apply, after two good ones.
    const FailEffect = struct {
        fn make() Effect(TestCtx) {
            return .{ .state = undefined, .apply_fn = applyFn, .deinit_fn = deinitFn };
        }
        fn applyFn(_: *anyopaque, _: std.mem.Allocator, _: *TestCtx) anyerror!acc.Inverse(TestCtx) {
            return error.EffectRefused;
        }
        fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var effects = [_]Effect(TestCtx){
        try AddEffect.make(allocator, 1),
        try AddEffect.make(allocator, 2),
        FailEffect.make(),
    };
    defer for (effects[0..2]) |e| e.deinit(allocator);

    const result = applySequence(TestCtx, &effects, allocator, &ctx, &accumulator);
    try std.testing.expectError(error.EffectRefused, result);
    try std.testing.expectEqual(@as(i64, 3), ctx.value); // two effects ran
    try std.testing.expectEqual(@as(usize, 2), accumulator.len); // both tracked

    // Recovery of what was installed brings us back to γ₀ (Corollary 69).
    accumulator.recover(&ctx);
    try std.testing.expectEqual(@as(i64, 0), ctx.value);
}
