//! The accumulator (φ) of the paper's effect context ∂Γ (Definition 2).
//!
//! Paper correspondence:
//!   - Definition 2  (Effect Context ∂Γ):  the accumulator φ : Γ → Γ is the
//!     composite of the inverses of every effect performed so far, and the
//!     function that recovers the context to its initial state.
//!   - Definition 1  (Twisted Composition): (f₁,g₁) ∘ (f₂,g₂) = (f₁∘f₂, g₂∘g₁);
//!     inverses accumulate in the OPPOSITE order of forward maps — i.e. LIFO.
//!   - Definition 3  (track):   folds a new inverse g onto φ  as  φ ∘ g.
//!   - Definition 6  (recover): applies φ to the state, resetting φ to id.
//!   - Theorem 7     (soundness invariant): starting from (γ₀, id), recover
//!     carries every reachable state back to γ₀.
//!   - Theorem 16    (LIFO revert): reverting in reverse order of application
//!     hands each inverse the state its own application produced.
//!
//! Zig correctness note (plan C1): Zig has no closures, so an inverse `g` is a
//! context-pointer + fn-pointer pair with explicit ownership. The accumulator
//! is NOT a composed function; it is an intrusive singly-linked LIFO stack of
//! Inverse nodes. `recover` walks it head→tail (newest first) and frees each.

const std = @import("std");

/// A single revertible action: the inverse `g` of a tracked effect
/// (Definition 8's second component), carrying its captured environment.
///
/// `call` performs the undo. `deinit` releases the captured `state`.
/// `Ctx` is left generic so this module has no dependency on the concrete
/// context type yet (Phase 1 keeps layers decoupled).
pub fn Inverse(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        /// Captured environment the inverse needs to undo its effect.
        state: *anyopaque,
        /// Undo action: applies the inverse to the context.
        call: *const fn (state: *anyopaque, ctx: *Ctx) void,
        /// Releases `state`. Called by the accumulator after `call`, or on
        /// drop when an accumulator is discarded without recovering.
        deinit: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,

        fn invoke(self: Self, ctx: *Ctx) void {
            self.call(self.state, ctx);
        }

        fn release(self: Self, allocator: std.mem.Allocator) void {
            self.deinit(self.state, allocator);
        }
    };
}

/// The accumulator φ for a context type `Ctx`.
///
/// Represented as an intrusive LIFO stack: `track` pushes (prepend), so the
/// most recently tracked inverse is undone first. This realizes the twisted
/// composition order of Definition 1 (`φ ∘ g`, newest applied first on
/// recover) and the LIFO guarantee of Theorem 16.
pub fn Accumulator(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const Inv = Inverse(Ctx);

        const Node = struct {
            inverse: Inv,
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        /// Head of the LIFO stack = most recently tracked inverse.
        head: ?*Node,
        len: usize,

        /// The initial effect context (γ₀, id): an empty accumulator is `id`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .head = null, .len = 0 };
        }

        /// Whether φ = id (nothing tracked, or fully recovered).
        pub fn isIdentity(self: Self) bool {
            return self.head == null;
        }

        /// Definition 3 (track): fold an inverse onto φ as `φ ∘ g`.
        /// Prepend so recover applies the newest inverse first (LIFO).
        pub fn track(self: *Self, inverse: Inv) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .inverse = inverse, .next = self.head };
            self.head = node;
            self.len += 1;
        }

        /// Definition 6 (recover): apply φ to `ctx`, then reset φ to id.
        /// Walks newest→oldest, invokes each inverse, frees captured state.
        pub fn recover(self: *Self, ctx: *Ctx) void {
            var cur = self.head;
            while (cur) |node| {
                const next = node.next;
                node.inverse.invoke(ctx);
                node.inverse.release(self.allocator);
                self.allocator.destroy(node);
                cur = next;
            }
            self.head = null;
            self.len = 0;
        }

        /// Release every tracked inverse WITHOUT invoking it. Used when an
        /// accumulator is discarded (e.g. derived-realization recovery, or
        /// teardown of a context whose effects were already reverted).
        pub fn deinit(self: *Self) void {
            var cur = self.head;
            while (cur) |node| {
                const next = node.next;
                node.inverse.release(self.allocator);
                self.allocator.destroy(node);
                cur = next;
            }
            self.head = null;
            self.len = 0;
        }
    };
}

// ───────────────────────────── Tests ─────────────────────────────
//
// A minimal context: a counter `γ : i64`. Effects add/subtract; each carries
// its own exact inverse, satisfying the witness of Definition 8 (g(f(γ)) = γ).

const TestCtx = struct { value: i64 };

/// A heap-captured "add N" inverse: undoing an effect that added N means
/// subtracting N. Models a per-effect captured environment (plan C1).
const AddInverse = struct {
    delta: i64,

    fn make(allocator: std.mem.Allocator, delta: i64) !Inverse(TestCtx) {
        const self = try allocator.create(AddInverse);
        self.* = .{ .delta = delta };
        return .{ .state = self, .call = call, .deinit = deinitFn };
    }

    fn call(state: *anyopaque, ctx: *TestCtx) void {
        const self: *AddInverse = @ptrCast(@alignCast(state));
        ctx.value -= self.delta; // inverse of "+= delta"
    }

    fn deinitFn(state: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AddInverse = @ptrCast(@alignCast(state));
        allocator.destroy(self);
    }
};

test "empty accumulator is identity" {
    var acc = Accumulator(TestCtx).init(std.testing.allocator);
    defer acc.deinit();
    try std.testing.expect(acc.isIdentity());
}

test "Theorem 7: recover returns context to its initial state" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{ .value = 0 };
    var acc = Accumulator(TestCtx).init(allocator);
    defer acc.deinit();

    // Apply three effects (+5, +10, -3), tracking each exact inverse.
    const deltas = [_]i64{ 5, 10, -3 };
    for (deltas) |d| {
        ctx.value += d;
        try acc.track(try AddInverse.make(allocator, d));
    }
    try std.testing.expectEqual(@as(i64, 12), ctx.value);

    // recover must carry the state back to γ₀ = 0 and reset φ to id.
    acc.recover(&ctx);
    try std.testing.expectEqual(@as(i64, 0), ctx.value);
    try std.testing.expect(acc.isIdentity());
}

test "Theorem 16: inverses are applied in LIFO order" {
    const allocator = std.testing.allocator;
    // Use a non-commutative witness to observe order: record the sequence of
    // deltas as recover applies them, and assert newest-first.
    const Recorder = struct {
        var seq: std.ArrayList(i64) = .empty;
    };
    Recorder.seq = .empty;
    defer Recorder.seq.deinit(allocator);

    const OrderedInverse = struct {
        delta: i64,
        fn make(a: std.mem.Allocator, delta: i64) !Inverse(TestCtx) {
            const s = try a.create(@This());
            s.* = .{ .delta = delta };
            return .{ .state = s, .call = call, .deinit = dfn };
        }
        fn call(state: *anyopaque, ctx: *TestCtx) void {
            const self: *@This() = @ptrCast(@alignCast(state));
            Recorder.seq.append(std.testing.allocator, self.delta) catch unreachable;
            ctx.value -= self.delta;
        }
        fn dfn(state: *anyopaque, a: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(state));
            a.destroy(self);
        }
    };

    var ctx = TestCtx{ .value = 0 };
    var acc = Accumulator(TestCtx).init(allocator);
    defer acc.deinit();

    try acc.track(try OrderedInverse.make(allocator, 1)); // tracked 1st
    try acc.track(try OrderedInverse.make(allocator, 2)); // tracked 2nd
    try acc.track(try OrderedInverse.make(allocator, 3)); // tracked 3rd (newest)

    acc.recover(&ctx);

    // LIFO: newest (3) reverted first, then 2, then 1.
    try std.testing.expectEqualSlices(i64, &.{ 3, 2, 1 }, Recorder.seq.items);
}

test "deinit releases without invoking inverses (no leak, no undo)" {
    const allocator = std.testing.allocator;
    var acc = Accumulator(TestCtx).init(allocator);
    try acc.track(try AddInverse.make(allocator, 42));
    try std.testing.expectEqual(@as(usize, 1), acc.len);
    acc.deinit(); // must free the captured AddInverse without touching a ctx
    try std.testing.expect(acc.isIdentity());
}
