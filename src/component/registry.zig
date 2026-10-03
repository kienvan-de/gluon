//! The registry F_γ (Definition 50) — the set of fibers a state carries, from
//! which the coeffect context is read off.
//!
//! Paper correspondence:
//!   - Definition 50 (Registry F_γ : 𝔑 ⇀ 𝔉Γ): a finite partial function whose
//!     parent pointers form a tree rooted at `root`.
//!   - Eq. 46 (σ_γ): the coeffect context is DERIVED, not stored — it is what
//!     the ACTIVE fibers jointly provide:
//!       σ_γ ≔ ⋃ { σ_m | m active }
//!     Each key has one possible provider (provider_k), fixed by the disjoint
//!     provisions (O-Insert single-source discipline).
//!   - Definition 53 (provided-by / target view): a declared key resolves to
//!     the fiber that provides it, and only while that fiber is ACTIVE. This is
//!     what makes a withdrawal visible to dependents one step before it happens
//!     (a provider entering UNLOADING stops providing).
//!
//! Here the registry maps a key name → the id of the fiber whose provision
//! carries it (the single possible provider, fixed at insert), plus a liveness
//! check that a key is "provided" only when its provider is ACTIVE.

const std = @import("std");
const comp = @import("component.zig");
const store_mod = @import("../coeffect/store.zig");

pub const FiberId = comp.FiberId;
pub const Fiber = comp.Fiber;
pub const Component = comp.Component;
pub const Key = store_mod.Key;

pub const RegistryError = error{
    /// O-Insert: a key in the new provision already has a possible provider.
    ProvisionConflict,
    /// O-Remove: the fiber still has children (tree well-formedness).
    HasChildren,
    /// The named fiber is absent.
    NoSuchFiber,
};

/// The registry F_γ. Owns its fibers; the caller supplies the allocator.
pub const Registry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    fibers: std.AutoHashMapUnmanaged(FiberId, *Fiber),
    /// key name → the single fiber whose provision carries it (Def 50 note:
    /// one possible provider, fixed by the provisions and not by the state).
    providers: std.StringHashMapUnmanaged(FiberId),
    next_id: FiberId,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .fibers = .empty,
            .providers = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.fibers.valueIterator();
        while (it.next()) |f| {
            f.*.deinit(self.allocator);
            self.allocator.destroy(f.*);
        }
        self.fibers.deinit(self.allocator);
        self.providers.deinit(self.allocator);
    }

    /// Draw a fresh fiber name (an atom, Definition 49/50).
    pub fn freshId(self: *Self) FiberId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn get(self: *const Self, id: FiberId) ?*Fiber {
        return self.fibers.get(id);
    }

    pub fn count(self: *const Self) usize {
        return self.fibers.count();
    }

    /// O-Insert precondition check + provision registration. Registers the
    /// single-source mapping for each provided key; fails if any is taken
    /// (Def 50 / O-Insert last premise: ∀m. p ∩ p_m = ∅).
    fn reserveProvisions(self: *Self, component: Component, id: FiberId) !void {
        // Check all first so a conflict leaves nothing half-registered.
        for (component.provide) |k| {
            if (self.providers.contains(k.name)) return RegistryError.ProvisionConflict;
        }
        for (component.provide) |k| {
            try self.providers.put(self.allocator, k.name, id);
        }
    }

    fn releaseProvisions(self: *Self, component: Component) void {
        for (component.provide) |k| {
            _ = self.providers.remove(k.name);
        }
    }

    /// O-Insert (Definition 52 / §4.2.1): add a fiber. The caller has already
    /// built the Fiber (with its derived ctx); the registry takes ownership and
    /// reserves its provisions. Fails (and frees nothing it did not create) on
    /// a provision conflict.
    pub fn insert(self: *Self, fiber: *Fiber) !void {
        try self.reserveProvisions(fiber.component, fiber.id);
        errdefer self.releaseProvisions(fiber.component);
        try self.fibers.put(self.allocator, fiber.id, fiber);
    }

    /// O-Remove (§4.2.1): drop an inactive, child-free fiber from the registry.
    /// Caller is responsible for having deactivated it first (phase inactive).
    /// Returns the removed fiber so the caller can deinit/free it.
    pub fn remove(self: *Self, id: FiberId) !*Fiber {
        const fiber = self.fibers.get(id) orelse return RegistryError.NoSuchFiber;
        // Tree well-formedness: remove children before their parent.
        var it = self.fibers.valueIterator();
        while (it.next()) |f| {
            if (f.*.parent == id) return RegistryError.HasChildren;
        }
        self.releaseProvisions(fiber.component);
        _ = self.fibers.remove(id);
        return fiber;
    }

    // ── Coeffect resolution (Eq. 46, Definition 53) ───────────────

    /// provider_k(γ): the single fiber whose provision carries `key`, or null
    /// if no component provides it. Fixed by the provisions, not the state.
    pub fn providerOf(self: *const Self, key: Key) ?FiberId {
        return self.providers.get(key.name);
    }

    /// Definition 53 "provided by": a key is provided iff its provider fiber is
    /// present AND ACTIVE. A provider in loading/unloading does NOT provide, so
    /// a withdrawal is visible to dependents one step early.
    pub fn isProvided(self: *const Self, key: Key) bool {
        const pid = self.providers.get(key.name) orelse return false;
        const fiber = self.fibers.get(pid) orelse return false;
        return fiber.phase == .active;
    }

    /// relied(n) (Definition 54): whether some other installed fiber resolves a
    /// key to `n` through its committed view — the guard on L-Unload.
    pub fn reliedUpon(self: *const Self, id: FiberId) bool {
        var it = self.fibers.valueIterator();
        while (it.next()) |fp| {
            const f = fp.*;
            if (f.id == id) continue;
            if (!f.installed()) continue;
            const view = f.committed orelse continue;
            for (view.providers) |p| {
                if (p != null and p.? == id) return true;
            }
        }
        return false;
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const Context = @import("../context/context.zig").Context;

fn dummyApply(_: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    unreachable;
}

fn makeFiber(reg: *Registry, root_ctx: *Context, component: Component, parent: ?FiberId) !*Fiber {
    const id = reg.freshId();
    const child = try root_ctx.derive();
    const fiber = try reg.allocator.create(Fiber);
    fiber.* = Fiber.init(id, component, parent, child);
    return fiber;
}

test "Definition 50: insert registers a fiber and reserves its provisions" {
    const allocator = std.testing.allocator;
    const root_ctx = try Context.init(allocator);
    defer root_ctx.deinit();
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const kdb = Key.of(u32, "db");
    const comp_a = Component{ .inject = &.{}, .provide = &.{kdb}, .apply = dummyApply };
    const fiber = try makeFiber(&reg, root_ctx, comp_a, comp.root);
    try reg.insert(fiber);

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expectEqual(fiber.id, reg.providerOf(kdb).?);
}

test "O-Insert single-source: provision conflict is rejected" {
    const allocator = std.testing.allocator;
    const root_ctx = try Context.init(allocator);
    defer root_ctx.deinit();
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const k = Key.of(u32, "shared");
    const c1 = Component{ .inject = &.{}, .provide = &.{k}, .apply = dummyApply };
    const c2 = Component{ .inject = &.{}, .provide = &.{k}, .apply = dummyApply };

    const f1 = try makeFiber(&reg, root_ctx, c1, comp.root);
    try reg.insert(f1);

    const f2 = try makeFiber(&reg, root_ctx, c2, comp.root);
    // Conflict: "shared" already has a provider. insert fails; f2 not owned.
    try std.testing.expectError(RegistryError.ProvisionConflict, reg.insert(f2));
    f2.deinit(allocator);
    allocator.destroy(f2);
}

test "Definition 53: a key is provided only while its provider is ACTIVE" {
    const allocator = std.testing.allocator;
    const root_ctx = try Context.init(allocator);
    defer root_ctx.deinit();
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const k = Key.of(u32, "svc");
    const c = Component{ .inject = &.{}, .provide = &.{k}, .apply = dummyApply };
    const f = try makeFiber(&reg, root_ctx, c, comp.root);
    try reg.insert(f);

    try std.testing.expect(!reg.isProvided(k)); // inactive provider
    f.phase = .loading;
    try std.testing.expect(!reg.isProvided(k)); // loading does not provide
    f.phase = .active;
    try std.testing.expect(reg.isProvided(k)); // active provides
    f.phase = .unloading;
    try std.testing.expect(!reg.isProvided(k)); // unloading stops providing
}

test "Definition 54: reliedUpon detects a committed dependent" {
    const allocator = std.testing.allocator;
    const root_ctx = try Context.init(allocator);
    defer root_ctx.deinit();
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const k = Key.of(u32, "p");
    const provider_c = Component{ .inject = &.{}, .provide = &.{k}, .apply = dummyApply };
    const consumer_c = Component{ .inject = &.{k}, .provide = &.{}, .apply = dummyApply };

    const provider = try makeFiber(&reg, root_ctx, provider_c, comp.root);
    try reg.insert(provider);
    provider.phase = .active;

    const consumer = try makeFiber(&reg, root_ctx, consumer_c, comp.root);
    try reg.insert(consumer);

    try std.testing.expect(!reg.reliedUpon(provider.id)); // no committed view yet

    // Consumer commits to the provider.
    var providers = [_]?FiberId{provider.id};
    consumer.committed = .{ .providers = &providers, .active = true };
    consumer.phase = .active;
    try std.testing.expect(reg.reliedUpon(provider.id)); // now relied upon

    consumer.committed = null; // avoid dangling slice at deinit
}

test "O-Remove: a fiber with children cannot be removed" {
    const allocator = std.testing.allocator;
    const root_ctx = try Context.init(allocator);
    defer root_ctx.deinit();
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const c = Component{ .inject = &.{}, .provide = &.{}, .apply = dummyApply };
    const parent = try makeFiber(&reg, root_ctx, c, comp.root);
    try reg.insert(parent);
    const child = try makeFiber(&reg, root_ctx, c, parent.id);
    try reg.insert(child);

    try std.testing.expectError(RegistryError.HasChildren, reg.remove(parent.id));

    // Remove child first, then parent.
    const removed_child = try reg.remove(child.id);
    removed_child.deinit(allocator);
    allocator.destroy(removed_child);
    const removed_parent = try reg.remove(parent.id);
    removed_parent.deinit(allocator);
    allocator.destroy(removed_parent);
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}
