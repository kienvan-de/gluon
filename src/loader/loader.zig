//! The declarative component loader (§5.2): configuration reconciliation and
//! hot module replacement, layered over the orchestrator.
//!
//! Paper correspondence:
//!   - §5.2.1 (Declarative Configuration): the orchestrator is driven from a
//!     declarative description of which components should be loaded with which
//!     config. Reconciliation diffs the desired configuration against the
//!     running one and emits the minimal set of orchestration steps.
//!   - §4.4 (Configuration): each revision is a composite of the calculus
//!     rules. Disabling is an O-Retire; every other revision retires the fiber,
//!     lets the lifecycle deactivate it, removes the entry (children before
//!     parent), and reinserts at a fresh fiber with the new effect function —
//!     "re-enabling an entry instantiates a fresh fiber". The composite is held
//!     to its endpoint, not its steps (Thm 80): the system quiesces where a
//!     load of the revised configuration from scratch would have left it.
//!   - §5.2.2 (Hot Module Replacement): swap a component's code at runtime by
//!     the same retire→remove→reinsert composite, preserving the logical entry
//!     identity (the config key) across the swap while the fiber identity is
//!     fresh.
//!
//! A ConfigEntry is keyed by a stable logical name (the entry identity that
//! survives revision). The loader tracks which fiber currently realizes each
//! entry and reconciles on apply().

const std = @import("std");
const lifecycle = @import("../component/lifecycle.zig");
const comp = @import("../component/component.zig");

pub const Orchestrator = lifecycle.Orchestrator;
pub const Component = comp.Component;
pub const FiberId = comp.FiberId;

/// A declarative request to run `component`, identified by a stable `name`.
/// `enabled` toggles the entry without removing it from the configuration.
pub const ConfigEntry = struct {
    name: []const u8,
    component: Component,
    enabled: bool = true,
};

/// Tracks the running realization of each configured entry.
const Realized = struct {
    component: Component,
    enabled: bool,
    fiber: ?FiberId, // null when disabled or not yet loaded
};

/// The declarative loader. Owns an orchestrator and the current realized set.
pub const Loader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    orch: Orchestrator,
    /// entry name → its current realization.
    entries: std.StringHashMapUnmanaged(Realized),

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .orch = try Orchestrator.init(allocator),
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.allocator);
        self.orch.deinit();
    }

    /// Whether two component definitions are "the same code" for HMR purposes.
    /// We compare the apply function pointer and the declared interface; a
    /// change in any means a material revision requiring a reload (§5.2.1
    /// "reloads only on a material change").
    fn sameCode(a: Component, b: Component) bool {
        if (a.apply != b.apply) return false;
        if (a.inject.len != b.inject.len or a.provide.len != b.provide.len) return false;
        for (a.inject, b.inject) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return false;
        for (a.provide, b.provide) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return false;
        return true;
    }

    /// §5.2.1 reconcile: bring the running system to match `desired`. Computes
    /// the minimal composite of orchestration steps:
    ///   - new entry (enabled)         → load
    ///   - entry removed from desired   → retire + remove
    ///   - entry disabled               → retire + remove (keep tracked)
    ///   - entry re-enabled             → load a fresh fiber
    ///   - entry code changed (HMR)     → retire + remove old, load new
    ///   - entry unchanged              → no-op (reloads only on material change)
    /// The endpoint is what matters (Thm 80): the quiescent state equals a
    /// from-scratch load of `desired`.
    pub fn reconcile(self: *Self, desired: []const ConfigEntry) !void {
        // 1. Apply additions / changes / enable-disable for each desired entry.
        for (desired) |entry| {
            const existing = self.entries.getPtr(entry.name);
            if (existing) |cur| {
                try self.reconcileExisting(entry, cur);
            } else {
                // New entry.
                var realized = Realized{ .component = entry.component, .enabled = entry.enabled, .fiber = null };
                if (entry.enabled) {
                    realized.fiber = try self.orch.load(entry.component, comp.root);
                }
                try self.entries.put(self.allocator, entry.name, realized);
            }
        }

        // 2. Remove entries no longer present in `desired`.
        try self.pruneAbsent(desired);
    }

    fn reconcileExisting(self: *Self, entry: ConfigEntry, cur: *Realized) !void {
        const code_changed = !sameCode(cur.component, entry.component);

        if (code_changed) {
            // §5.2.2 HMR: retire+remove the old fiber, load a fresh one.
            try self.teardownEntry(cur);
            cur.component = entry.component;
            cur.enabled = entry.enabled;
            if (entry.enabled) {
                cur.fiber = try self.orch.load(entry.component, comp.root);
            }
            return;
        }

        // Same code: handle enable/disable transitions.
        if (cur.enabled and !entry.enabled) {
            // Disable: retire + remove, keep the entry tracked.
            try self.teardownEntry(cur);
            cur.enabled = false;
        } else if (!cur.enabled and entry.enabled) {
            // Re-enable: instantiate a FRESH fiber (§4.4 Configuration).
            cur.enabled = true;
            cur.fiber = try self.orch.load(entry.component, comp.root);
        }
        // else: unchanged → no-op.
    }

    fn pruneAbsent(self: *Self, desired: []const ConfigEntry) !void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            var still_desired = false;
            for (desired) |e| {
                if (std.mem.eql(u8, e.name, kv.key_ptr.*)) {
                    still_desired = true;
                    break;
                }
            }
            if (!still_desired) try to_remove.append(self.allocator, kv.key_ptr.*);
        }

        for (to_remove.items) |name| {
            const cur = self.entries.getPtr(name).?;
            try self.teardownEntry(cur);
            _ = self.entries.remove(name);
        }
    }

    /// Retire the entry's fiber, let the lifecycle deactivate it, then remove
    /// it from the registry (children before parent is handled by the cascade).
    fn teardownEntry(self: *Self, cur: *Realized) !void {
        if (cur.fiber) |fid| {
            try self.orch.unloadFiber(fid); // O-Retire + deactivate
            // The fiber is now inactive; remove it (O-Remove) and free it.
            self.orch.removeFiber(fid) catch {};
            cur.fiber = null;
        }
    }

    /// Query: is a configured entry currently backed by an ACTIVE fiber?
    pub fn isActive(self: *Self, name: []const u8) bool {
        const cur = self.entries.get(name) orelse return false;
        const fid = cur.fiber orelse return false;
        const fiber = self.orch.registry.get(fid) orelse return false;
        return fiber.phase == .active;
    }
};

// ───────────────────── Tests (integration) ─────────────────────────
// Shared component factories live in src/testing/fixtures.zig.

const store_mod = @import("../coeffect/store.zig");
const fixtures = @import("../testing/fixtures.zig");
const Key = store_mod.Key;
const provider = fixtures.provider;

test "§5.2.1 reconcile: a new enabled entry is loaded and activated" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.reconcile(&.{.{ .name = "db", .component = provider("db", 1) }});
    try std.testing.expect(loader.isActive("db"));
    try std.testing.expect(loader.orch.isProvided(Key.of(u32, "db")));
}

test "§5.2.1 reconcile: removing an entry unloads it" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.reconcile(&.{.{ .name = "db", .component = provider("db", 1) }});
    try std.testing.expect(loader.isActive("db"));

    // Reconcile to an empty configuration: the entry is retired and removed.
    try loader.reconcile(&.{});
    try std.testing.expect(!loader.isActive("db"));
    try std.testing.expect(!loader.orch.isProvided(Key.of(u32, "db")));
}

test "§4.4 Configuration: disable then re-enable instantiates a fresh fiber" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    const entry_on = ConfigEntry{ .name = "db", .component = provider("db", 1), .enabled = true };
    const entry_off = ConfigEntry{ .name = "db", .component = provider("db", 1), .enabled = false };

    try loader.reconcile(&.{entry_on});
    try std.testing.expect(loader.isActive("db"));

    try loader.reconcile(&.{entry_off});
    try std.testing.expect(!loader.isActive("db"));
    try std.testing.expect(!loader.orch.isProvided(Key.of(u32, "db")));

    try loader.reconcile(&.{entry_on});
    try std.testing.expect(loader.isActive("db")); // fresh fiber active again
}

test "§5.2.2 HMR: changing a component's code swaps the running fiber" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    const kdb = Key.of(u32, "db");
    // v1 provides db=1.
    try loader.reconcile(&.{.{ .name = "db", .component = provider("db", 1) }});
    const fid_v1 = loader.entries.get("db").?.fiber.?;
    try std.testing.expectEqual(@as(u32, 1), try loader.orch.root_ctx.get(u32, kdb));

    // v2 provides db=2 (different apply fn ptr via different comptime value).
    try loader.reconcile(&.{.{ .name = "db", .component = provider("db", 2) }});
    const fid_v2 = loader.entries.get("db").?.fiber.?;

    // The code changed, so the fiber was swapped (fresh id) and the new value
    // is in effect — the entry identity ("db") survived the swap.
    try std.testing.expect(fid_v1 != fid_v2);
    try std.testing.expectEqual(@as(u32, 2), try loader.orch.root_ctx.get(u32, kdb));
    try std.testing.expect(loader.isActive("db"));
}

test "§5.2.1 reconcile is idempotent: re-applying unchanged config is a no-op" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    const config = [_]ConfigEntry{.{ .name = "db", .component = provider("db", 1) }};
    try loader.reconcile(&config);
    const fid1 = loader.entries.get("db").?.fiber;
    try loader.reconcile(&config); // unchanged → no reload
    const fid2 = loader.entries.get("db").?.fiber;
    try std.testing.expectEqual(fid1, fid2); // same fiber, not reloaded
}

test "Theorem 80: reconcile endpoint equals a from-scratch load" {
    // Build a system by a sequence of reconciles, then compare the active set
    // and bindings to a fresh loader given the final config directly.
    const final_config = [_]ConfigEntry{
        .{ .name = "a", .component = provider("a", 1) },
        .{ .name = "b", .component = provider("b", 2) },
    };

    var incremental = try Loader.init(std.testing.allocator);
    defer incremental.deinit();
    try incremental.reconcile(&.{.{ .name = "a", .component = provider("a", 1) }});
    try incremental.reconcile(&.{
        .{ .name = "a", .component = provider("a", 1) },
        .{ .name = "x", .component = provider("x", 9) },
    });
    try incremental.reconcile(&final_config); // drops x, adds b

    var scratch = try Loader.init(std.testing.allocator);
    defer scratch.deinit();
    try scratch.reconcile(&final_config);

    // Same quiescent state: a and b active, x gone, in both.
    try std.testing.expectEqual(incremental.isActive("a"), scratch.isActive("a"));
    try std.testing.expectEqual(incremental.isActive("b"), scratch.isActive("b"));
    try std.testing.expect(incremental.isActive("a") and incremental.isActive("b"));
    try std.testing.expect(!incremental.orch.isProvided(Key.of(u32, "x")));
    try std.testing.expect(!scratch.orch.isProvided(Key.of(u32, "x")));
}

fn loaderScenario(allocator: std.mem.Allocator) !void {
    var loader = try Loader.init(allocator);
    defer loader.deinit();
    try loader.reconcile(&.{.{ .name = "a", .component = provider("a", 1) }});
    try loader.reconcile(&.{
        .{ .name = "a", .component = provider("a", 1) },
        .{ .name = "b", .component = provider("b", 2) },
    });
    try loader.reconcile(&.{.{ .name = "b", .component = provider("b", 2) }}); // drop a
}

test "OOM safety: full reconcile scenario leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loaderScenario, .{});
}
