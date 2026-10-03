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
const interception = @import("../coeffect/interception.zig");
const event_bus = @import("../event/bus.zig");

pub const Key = store_mod.Key;
pub const Store = store_mod.Store;
pub const StoreError = store_mod.StoreError;
pub const EventBus = event_bus.EventBus;
pub const Handler = event_bus.Handler;
pub const Subscription = event_bus.Subscription;

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
    /// 𝜄 — the context-carried interception metadata (Definition 26). Each
    /// context owns its own table; intercept is derived realization (§5.1.2),
    /// so a derived child gets a fresh table and recovery just discards it.
    intercepts: interception.InterceptTable,

    /// Create a root context with a freshly owned store.
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const store = try allocator.create(Store);
        errdefer allocator.destroy(store);
        store.* = Store.init(allocator);
        errdefer store.deinit();
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .store = store,
            .owns_store = true,
            .dispose = Accumulator.init(allocator),
            .parent = null,
            .intercepts = interception.InterceptTable.init(allocator),
        };
        return self;
    }

    /// Tear down: recover all tracked effects (withdrawing this context's
    /// bindings), discard the interception table (derived realization — no
    /// inverse to run), then free the owned store if this is the root.
    pub fn deinit(self: *Self) void {
        self.dispose.recover(self);
        self.intercepts.deinit();
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
        errdefer self.allocator.destroy(inv_state);
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
        // On track failure: errdefers unwind the store binding and inv_state.
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

    // ── Interception (§5.1.2, Definitions 26/27) ──────────────────

    /// ctx.intercept(key, metadata) — Definition 27. Merge `metadata` onto this
    /// context's carried metadata 𝜄(k), right-biased (enclosing context wins).
    /// Derived realization: adjusts 𝜄 on THIS context only, nothing to track —
    /// recovery discards the context along with the adjustment. Takes ownership
    /// of `metadata`.
    pub fn intercept(
        self: *Self,
        key: Key,
        metadata: *anyopaque,
        merge: interception.Merge,
        free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,
    ) !void {
        try self.intercepts.intercept(key.name, metadata, merge, free);
    }

    /// 𝜄(k): the context-carried metadata for `key`, or null (εₖ) if none.
    /// A component reads this and merges it with its own declared metadata
    /// before applying the provider (Definition 27's σ(k)(μ ⊕ₖ 𝜄(k))). The
    /// provider application itself is the component's concern; the context
    /// supplies the carried half of the merge.
    pub fn interceptOf(self: *const Self, key: Key) ?*anyopaque {
        return self.intercepts.get(key.name);
    }

    // ── Events (§3.4.2 tagged registry; Def 8 revertible effect) ─────
    //
    // The bus lives in the coeffect store under `bus_key` (its value type must
    // be EventBus). A component provisions it with ctx.set; consumers reach it
    // through ctx.on/ctx.emit. Registering a listener (ctx.on) is a REVERTIBLE
    // effect (Definition 8): it inserts a uniquely-tagged entry and tracks the
    // disposer (bus.off) onto THIS context's accumulator, so unloading the
    // consumer withdraws its listeners (Theorem 7/16, LIFO). Because entries
    // carry unique tags, concurrent registrations commute (§3.4.2) — the bus
    // certifies a tagged_registry witness (event/bus.zig busWitness).

    /// ctx.on(P, bus_key, event, handler) — register a listener for `event` on
    /// the bus bound at `bus_key`, expecting payloads of type `P`. Tracks the
    /// removal as an inverse on this context: recover/unload removes it.
    /// Returns the Subscription so the caller may also unsubscribe explicitly.
    pub fn on(
        self: *Self,
        comptime P: type,
        bus_key: Key,
        event: []const u8,
        handler: Handler,
    ) !Subscription {
        const bus = try self.store.get(*EventBus, bus_key);
        const sub = try bus.on(P, event, handler);
        errdefer bus.off(sub);

        // The inverse: remove exactly this subscription (the Def 8 disposer).
        const State = struct { bus: *EventBus, sub: Subscription };
        const inv_state = try self.allocator.create(State);
        errdefer self.allocator.destroy(inv_state);
        inv_state.* = .{ .bus = bus, .sub = sub };
        const Impl = struct {
            fn call(state: *anyopaque, _: *Self) void {
                const s: *State = @ptrCast(@alignCast(state));
                s.bus.off(s.sub);
            }
            fn deinit(state: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*State, @ptrCast(@alignCast(state))));
            }
        };
        try self.dispose.track(.{ .state = inv_state, .call = Impl.call, .deinit = Impl.deinit });
        return sub;
    }

    /// ctx.emit(P, bus_key, event, payload) — dispatch `payload` to every live
    /// listener of `event` on the bus bound at `bus_key`. A read over the
    /// registry: no provision, no inverse tracked. Returns the number of
    /// listeners invoked.
    pub fn emit(
        self: *Self,
        comptime P: type,
        bus_key: Key,
        event: []const u8,
        payload: *const P,
    ) !usize {
        const bus = try self.store.get(*EventBus, bus_key);
        return bus.emit(P, event, payload);
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
        errdefer self.allocator.destroy(child);
        child.* = .{
            .allocator = self.allocator,
            .store = self.store, // shared by reference
            .owns_store = false,
            .dispose = Accumulator.init(self.allocator),
            .parent = self,
            // Derived realization: the child gets its own 𝜄 table. (Inheriting
            // the parent's metadata by merge is a future refinement; a fresh
            // table is the minimal correct derived context.)
            .intercepts = interception.InterceptTable.init(self.allocator),
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
                // without recover, release remaining inverses first. Discard
                // the child's interception table (derived realization).
                const c: *Self = @ptrCast(@alignCast(state));
                c.dispose.deinit();
                c.intercepts.deinit();
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

// ── Allocation-failure safety (thorough review) ──────────────────
//
// checkAllAllocationFailures runs the body with the failing allocator set to
// fail at each allocation index in turn, asserting no leak on any OOM path.

fn setUnderOom(allocator: std.mem.Allocator) !void {
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    try ctx.set(u32, Key.of(u32, "k"), 1);
    try ctx.set([]const u8, Key.of([]const u8, "s"), "v");
}

test "OOM safety: ctx.init + ctx.set leak nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, setUnderOom, .{});
}

fn deriveUnderOom(allocator: std.mem.Allocator) !void {
    const parent = try Context.init(allocator);
    defer parent.deinit();
    const child = try parent.derive();
    try child.set(u32, Key.of(u32, "c"), 7);
}

test "OOM safety: derive + child.set leak nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deriveUnderOom, .{});
}

// ── Events wired into Context (§3.4.2, Def 8) ────────────────

const EvSink = struct {
    sum: u32 = 0,
    fn handler(self: *EvSink) event_bus.Handler {
        return .{ .state = self, .call = call };
    }
    fn call(state: *anyopaque, payload: *const anyopaque) void {
        const self: *EvSink = @ptrCast(@alignCast(state));
        self.sum += @as(*const u32, @ptrCast(@alignCast(payload))).*;
    }
};

test "ctx.on registers a listener and ctx.emit dispatches to it" {
    // Declare the bus FIRST so its deinit runs LAST (after ctx.deinit, which
    // runs the listener disposer against the still-live bus). Defers are LIFO.
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bus_key = Key.of(*EventBus, "app.bus");
    try ctx.set(*EventBus, bus_key, &bus);

    var sink = EvSink{};
    _ = try ctx.on(u32, bus_key, "tick", sink.handler());

    var p: u32 = 9;
    const n = try ctx.emit(u32, bus_key, "tick", &p);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 9), sink.sum);
}

test "Definition 8: ctx.on is a revertible effect — recover withdraws the listener" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bus_key = Key.of(*EventBus, "app.bus");
    try ctx.set(*EventBus, bus_key, &bus);

    var sink = EvSink{};
    _ = try ctx.on(u32, bus_key, "tick", sink.handler());
    try std.testing.expectEqual(@as(usize, 1), bus.count("tick"));

    // Recover this context: the listener's disposer runs (LIFO) and removes it.
    // (The bus-provision inverse also runs, restricting the key.)
    ctx.dispose.recover(ctx);
    try std.testing.expectEqual(@as(usize, 0), bus.count("tick"));

    // After recovery, emitting reaches no one (the listener is gone).
    var p: u32 = 100;
    try std.testing.expectEqual(@as(usize, 0), bus.emit(u32, "tick", &p));
    try std.testing.expectEqual(@as(u32, 0), sink.sum);
}

test "§5.1.1 parent composition: unloading parent withdraws a child's listener" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const parent = try Context.init(std.testing.allocator);
    defer parent.deinit();

    const bus_key = Key.of(*EventBus, "app.bus");
    try parent.set(*EventBus, bus_key, &bus); // provided at parent, shared store

    const child = try parent.derive();
    var sink = EvSink{};
    _ = try child.on(u32, bus_key, "tick", sink.handler()); // consumer in child
    try std.testing.expectEqual(@as(usize, 1), bus.count("tick"));

    // Recovering the parent cascades to the child (∂²Γ): its listener is removed.
    parent.dispose.recover(parent);
    try std.testing.expectEqual(@as(usize, 0), bus.count("tick"));
}

fn eventUnderOom(allocator: std.mem.Allocator) !void {
    var bus = EventBus.init(allocator);
    defer bus.deinit();
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    const bus_key = Key.of(*EventBus, "app.bus");
    try ctx.set(*EventBus, bus_key, &bus);
    var sink = EvSink{};
    _ = try ctx.on(u32, bus_key, "tick", sink.handler());
    var p: u32 = 1;
    _ = try ctx.emit(u32, bus_key, "tick", &p);
}

test "OOM safety: ctx.on + ctx.emit leak nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, eventUnderOom, .{});
}

// ── Interception wired into Context (Def 26/27) ──────────────────

const Flags = struct {
    bits: u32,
    fn create(a: std.mem.Allocator, bits: u32) !*anyopaque {
        const self = try a.create(Flags);
        self.* = .{ .bits = bits };
        return self;
    }
    fn mergeFn(a: std.mem.Allocator, inherited: ?*anyopaque, incoming: *anyopaque) anyerror!*anyopaque {
        const inc: *Flags = @ptrCast(@alignCast(incoming));
        const base: u32 = if (inherited) |ih| @as(*Flags, @ptrCast(@alignCast(ih))).bits else 0;
        const out = try a.create(Flags);
        out.* = .{ .bits = base | inc.bits }; // union; incoming (right) wins ties
        return out;
    }
    fn freeFn(value: *anyopaque, a: std.mem.Allocator) void {
        a.destroy(@as(*Flags, @ptrCast(@alignCast(value))));
    }
};

test "Definition 27: ctx.intercept carries metadata, interceptOf reads it" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const k = Key.of(u32, "db");
    try std.testing.expectEqual(@as(?*anyopaque, null), ctx.interceptOf(k)); // εₖ

    const m1 = try Flags.create(ctx.allocator, 0b01);
    try ctx.intercept(k, m1, Flags.mergeFn, Flags.freeFn);
    const m2 = try Flags.create(ctx.allocator, 0b10);
    try ctx.intercept(k, m2, Flags.mergeFn, Flags.freeFn);

    const carried: *Flags = @ptrCast(@alignCast(ctx.interceptOf(k).?));
    try std.testing.expectEqual(@as(u32, 0b11), carried.bits); // merged union
}

test "interception is per-context: a derived child has its own 𝜄 table" {
    const parent = try Context.init(std.testing.allocator);
    defer parent.deinit();

    const k = Key.of(u32, "k");
    const pm = try Flags.create(parent.allocator, 0b01);
    try parent.intercept(k, pm, Flags.mergeFn, Flags.freeFn);

    const child = try parent.derive();
    // The child starts with an empty 𝜄 (derived realization): parent's
    // interception does not leak into the child's own table.
    try std.testing.expectEqual(@as(?*anyopaque, null), child.interceptOf(k));
}

fn interceptUnderOom(allocator: std.mem.Allocator) !void {
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    const k = Key.of(u32, "db");
    const m1 = try Flags.create(ctx.allocator, 0b01);
    try ctx.intercept(k, m1, Flags.mergeFn, Flags.freeFn);
    const m2 = try Flags.create(ctx.allocator, 0b10);
    try ctx.intercept(k, m2, Flags.mergeFn, Flags.freeFn);
}

test "OOM safety: ctx.intercept leaks nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, interceptUnderOom, .{});
}
