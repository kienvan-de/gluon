//! The unified context Γ∞ (Definition 28) — the single entity every effect and
//! coeffect is mediated through (the Context Paradigm, §3.3).
//!
//! Paper correspondence:
//!   - Definition 28 (Context Γ∞ ≔ μΓ. Γ × (Γ → Γ) × Σ): a recursive type whose
//!     three projections are the current state, the accumulator (this level's
//!     recover φ), and the coeffect context Σ. We realize the recursion with a
//!     parent pointer: a derived/child context links to the one it came from.
//!   - §5.1.1 (ctx.effect): the sole primitive through which the context is
//!     mutated. It tracks an effect's inverse onto this context's accumulator
//!     and (per §5.1.1 "parent composition") a child's dispose is prepended to
//!     the parent's — the recursive ∂²Γ structure (handled when child contexts
//!     land in the fiber slice).
//!   - §5.1.2 (ctx.get / ctx.set): coeffect access. set(k,v) has type 𝔈Σ
//!     (Definition 20), so provision is an ordinary tracked effect: this slice
//!     makes ctx.set install a binding AND track its restriction inverse, so
//!     recover withdraws it.
//!
//! Reactive notification (notify, Alg 3) and the fiber lifecycle sit above this
//! and arrive in later slices; here the Context is the substrate they act on.

const std = @import("std");
const acc = @import("../effect/accumulator.zig");
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

pub const Key = store_mod.Key;
pub const Store = store_mod.Store;
pub const StoreError = store_mod.StoreError;

/// The unified context. Owns a coeffect store and an accumulator (φ). A context
/// may be derived from a parent (for isolation/interception child contexts);
/// derived contexts share the parent's store by reference and keep their own
/// accumulator, mirroring the ∂-tower of Definition 28.
pub const Context = struct {
    const Self = @This();
    const Accumulator = acc.Accumulator(Self);
    const Inverse = acc.Inverse(Self);

    allocator: std.mem.Allocator,
    /// Σ — the coeffect store. Owned by the root; borrowed by derived contexts.
    store: *Store,
    owns_store: bool,
    /// φ — this level's accumulator of inverses (LIFO recover).
    dispose: Accumulator,
    /// The context this one was derived from, or null at the root.
    parent: ?*Self,

    /// Create a root context with a freshly owned store.
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const store = try allocator.create(Store);
        store.* = Store.init(allocator);
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .store = store,
            .owns_store = true,
            .dispose = Accumulator.init(allocator),
            .parent = null,
        };
        return self;
    }

    /// Tear down: recover all tracked effects (withdrawing this context's
    /// bindings), then free the owned store if this is the root.
    pub fn deinit(self: *Self) void {
        self.dispose.recover(self);
        if (self.owns_store) {
            self.store.deinit();
            self.allocator.destroy(self.store);
        }
        self.allocator.destroy(self);
    }

    // ── Coeffect access (§5.1.2) ──────────────────────────────────

    /// ctx.get(V, key) — read σ(ρ(k)) (Definition 20).
    pub fn get(self: *Self, comptime V: type, key: Key) !V {
        return self.store.get(V, key);
    }

    /// ctx.set(V, key, value) — provision a binding. Since set ∈ 𝔈Σ
    /// (Definition 20), this installs the value AND tracks its restriction
    /// inverse onto this context's accumulator, so recover withdraws it.
    pub fn set(self: *Self, comptime V: type, key: Key, value: V) !void {
        try self.store.set(V, key, value);
        errdefer self.store.restrict(key) catch {};

        // The inverse: restrict the key, undoing this provision.
        const inv_state = try self.allocator.create(Key);
        inv_state.* = key;
        const Impl = struct {
            fn call(state: *anyopaque, ctx: *Self) void {
                const k: *Key = @ptrCast(@alignCast(state));
                ctx.store.restrict(k.*) catch {};
            }
            fn deinit(state: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*Key, @ptrCast(@alignCast(state))));
            }
        };
        try self.dispose.track(.{ .state = inv_state, .call = Impl.call, .deinit = Impl.deinit });
    }

    /// Whether `key` currently resolves to a bound value in Σ.
    pub fn has(self: *const Self, key: Key) bool {
        return self.store.has(key);
    }

    /// ctx.isolate(key, realm) — Definition 25. Derived realization: adjusts ρ
    /// with nothing to track on σ (recovery discards the adjustment with the
    /// context). Acts on the shared store, so a child context sees it too.
    pub fn isolate(self: *Self, key: Key, realm: store_mod.Realm) !void {
        try self.store.isolate(key, realm);
    }

    // ── Effect tracking (§5.1.1) ─────────────────────────────

    pub const Iterator = effect_iter.Iterator(Self);
    pub const Guard = effect_iter.Guard;

    /// ctx.effect(iter, guard) — Algorithm 1. Drive an effect iterator to
    /// completion (or until `guard` trips), tracking every yielded inverse onto
    /// THIS context's accumulator. After this returns, ctx.dispose holds the
    /// composite recover for the installed effects (LIFO, Theorem 16).
    ///
    /// This is the sole mutation primitive of §5.1.1: ctx.set is a special case
    /// (a single-step provision effect), and component instantiation (Alg 4)
    /// will likewise reduce to a ctx.effect call.
    pub fn effect(self: *Self, iter: Iterator, guard: Guard) !void {
        return effect_iter.execute(Self, iter, guard, self.allocator, self, &self.dispose);
    }

    // ── Derived child contexts (§5.1.1 parent composition, ∂²Γ) ──────

    /// Derive a child context sharing this context's store. The child keeps its
    /// own accumulator; disposing the child recovers only the child's effects.
    /// A child's dispose is prepended to the parent's accumulator (§5.1.1
    /// "parent composition"): unloading the parent cascades to the child, which
    /// is the recursive ∂²Γ structure of Definition 28.
    ///
    /// The returned child is owned by the parent after this call: the parent's
    /// accumulator holds the inverse that disposes and destroys it.
    pub fn derive(self: *Self) !*Self {
        const child = try self.allocator.create(Self);
        child.* = .{
            .allocator = self.allocator,
            .store = self.store, // shared by reference
            .owns_store = false,
            .dispose = Accumulator.init(self.allocator),
            .parent = self,
        };

        // Prepend the child's teardown to the parent's accumulator: when the
        // parent recovers, it recovers the child's effects then frees it.
        const Impl = struct {
            fn call(state: *anyopaque, _: *Self) void {
                const c: *Self = @ptrCast(@alignCast(state));
                c.dispose.recover(c);
            }
            fn deinit(state: *anyopaque, allocator: std.mem.Allocator) void {
                // Runs after `call` (or on drop): free the child shell. Its
                // accumulator is already empty after recover; if dropped
                // without recover, release remaining inverses first.
                const c: *Self = @ptrCast(@alignCast(state));
                c.dispose.deinit();
                allocator.destroy(c);
            }
        };
        try self.dispose.track(.{ .state = child, .call = Impl.call, .deinit = Impl.deinit });
        return child;
    }
};

// ───────────────────────────── Tests ─────────────────────────────

test "ctx.set installs a binding and ctx.get reads it" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const k = Key.of(u32, "answer");
    try ctx.set(u32, k, 42);
    try std.testing.expect(ctx.has(k));
    try std.testing.expectEqual(@as(u32, 42), try ctx.get(u32, k));
}

test "Definition 20: ctx.set is a revertible effect — recover withdraws it" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const a = Key.of(u32, "a");
    const b = Key.of(u32, "b");
    try ctx.set(u32, a, 1);
    try ctx.set(u32, b, 2);
    try std.testing.expect(ctx.has(a) and ctx.has(b));

    // Recovering the accumulator withdraws both bindings (LIFO: b then a).
    ctx.dispose.recover(ctx);
    try std.testing.expect(!ctx.has(a) and !ctx.has(b));
}

test "deinit recovers tracked provisions (no leak)" {
    // The store holds heap-boxed values; if ctx.set's inverse did not run on
    // deinit, the testing allocator would report a leak.
    const ctx = try Context.init(std.testing.allocator);
    const k = Key.of([]const u8, "name");
    try ctx.set([]const u8, k, "gluon");
    ctx.deinit(); // must recover (restrict) before freeing the store
}

test "ctx.isolate redirects a key through the shared store" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const k = Key.of(u32, "tenant");
    try ctx.set(u32, k, 10);
    try ctx.isolate(k, "realm-b");
    try std.testing.expect(!ctx.has(k)); // fresh realm, unbound
    try ctx.set(u32, k, 20);
    try std.testing.expectEqual(@as(u32, 20), try ctx.get(u32, k));
}

test "KNOWN LIMITATION: set-inverse resolves realm at recover time, not set time" {
    // This documents a semantics subtlety. ctx.set tracks an inverse that
    // restricts `key`; restrict re-resolves ρ(key) when it RUNS. If the realm
    // is reassigned between set and recover, the inverse targets the new
    // realm. The paper (§4.4 Isolation) fixes a fiber's realms at insertion
    // and treats a runtime realm change as a revision, so within one fiber's
    // lifecycle ρ is stable and this cannot occur. We assert the current
    // behavior so a future fiber-level realm freeze is a deliberate change.
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const k = Key.of(u32, "x");
    try ctx.set(u32, k, 1); // realm "x", inverse tracked
    try ctx.isolate(k, "other"); // ρ(x) = "other"
    try ctx.set(u32, k, 2); // realm "other", inverse tracked

    // Both inverses now resolve ρ(k) = "other" at recover time. The first
    // restrict removes "other"; the second finds nothing (restrict is
    // tolerant via `catch {}`), leaving realm "x" still bound.
    ctx.dispose.recover(ctx);
    try ctx.isolate(k, "x");
    try std.testing.expectEqual(@as(u32, 1), try ctx.get(u32, k)); // "x" survived
    // Clean up the leaked "x" binding so the allocator reports no leak.
    try ctx.store.restrict(k);
}

// ── Effect method + child contexts ────────────────────────────

/// A one-step iterator that provisions `key := value` and yields a restrict
/// inverse. Exercises ctx.effect driving a generic effect (not just ctx.set).
const ProvideIter = struct {
    key: Key,
    value: u32,

    fn make(allocator: std.mem.Allocator, key: Key, value: u32) !Context.Iterator {
        const self = try allocator.create(ProvideIter);
        self.* = .{ .key = key, .value = value };
        return .{ .state = self, .next_fn = nextFn, .deinit_fn = deinitFn };
    }
    fn nextFn(state: *anyopaque, allocator: std.mem.Allocator, ctx: *Context) anyerror!effect_iter.Step(Context) {
        const self: *ProvideIter = @ptrCast(@alignCast(state));
        try ctx.store.set(u32, self.key, self.value);
        const inv_key = try allocator.create(Key);
        inv_key.* = self.key;
        const Impl = struct {
            fn call(s: *anyopaque, c: *Context) void {
                c.store.restrict(@as(*Key, @ptrCast(@alignCast(s))).*) catch {};
            }
            fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                a.destroy(@as(*Key, @ptrCast(@alignCast(s))));
            }
        };
        return .{ .inverse = .{ .state = inv_key, .call = Impl.call, .deinit = Impl.deinit }, .done = true };
    }
    fn deinitFn(state: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*ProvideIter, @ptrCast(@alignCast(state))));
    }
};

test "ctx.effect drives an iterator and tracks its inverse (Alg 1)" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const k = Key.of(u32, "port");
    const iter = try ProvideIter.make(ctx.allocator, k, 8080);
    defer iter.deinit(ctx.allocator);

    try ctx.effect(iter, Context.Guard.always());
    try std.testing.expectEqual(@as(u32, 8080), try ctx.get(u32, k));

    ctx.dispose.recover(ctx);
    try std.testing.expect(!ctx.has(k)); // inverse withdrew the provision
}

test "§5.1.1 parent composition: disposing parent recovers child effects" {
    const parent = try Context.init(std.testing.allocator);
    defer parent.deinit();

    const child = try parent.derive();
    // Child and parent share the store.
    try std.testing.expect(child.store == parent.store);

    const ck = Key.of(u32, "child.key");
    try child.set(u32, ck, 1);
    try std.testing.expect(parent.has(ck)); // visible through shared store

    // Recovering the PARENT cascades to the child: the child's binding is
    // withdrawn and the child shell is freed (no leak reported).
    parent.dispose.recover(parent);
    try std.testing.expect(!parent.has(ck));
}

test "derived child is freed on parent deinit without explicit child teardown" {
    // Only the parent is deinited; the child (and its tracked provision) must
    // be recovered and freed via the parent's accumulator.
    const parent = try Context.init(std.testing.allocator);
    const child = try parent.derive();
    try child.set([]const u8, Key.of([]const u8, "c"), "owned-by-child");
    parent.deinit(); // cascades: child recover + free, then store free
}
