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
const schema_mod = @import("schema.zig");

pub const Orchestrator = lifecycle.Orchestrator;
pub const Component = comp.Component;
pub const FiberId = comp.FiberId;
pub const Config = schema_mod.Config;

/// A declarative request to run `component`, identified by a stable `name`.
/// `enabled` toggles the entry without removing it from the configuration.
/// `config` is an optional validated, type-erased config (built via
/// schema.Config.of) passed to the component's apply (§4.4 Configuration); a
/// change in its value is a material revision that triggers a reload (§5.2.1).
pub const ConfigEntry = struct {
    name: []const u8,
    component: Component,
    enabled: bool = true,
    config: ?Config = null,
};

/// Tracks the running realization of each configured entry.
const Realized = struct {
    component: Component,
    enabled: bool,
    fiber: ?FiberId, // null when disabled or not yet loaded
    /// The loader-owned config currently realized for this entry (copied from
    /// the ConfigEntry on load; freed on teardown/replace). Must outlive the
    /// fiber, which holds a borrowed pointer into it.
    config: ?Config,
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
        // Free any configs the loader still owns before dropping the map.
        var it = self.entries.valueIterator();
        while (it.next()) |r| if (r.config) |c| c.deinit(self.allocator);
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

    /// Whether the config VALUE changed between the running realization and a
    /// desired entry — the material-change diff of §5.2.1 that code-identity
    /// alone misses. both-absent = unchanged; presence toggled = changed;
    /// both-present = compared by Config.eql.
    fn configChanged(cur: ?Config, desired: ?Config) bool {
        if (cur == null and desired == null) return false;
        if (cur == null or desired == null) return true;
        return !cur.?.eql(desired.?);
    }

    /// Load a fiber for an entry, passing its config pointer (if any) to apply.
    fn loadEntry(self: *Self, entry: ConfigEntry) !FiberId {
        const cfg_ptr: ?*anyopaque = if (entry.config) |c| c.ptr else null;
        return self.orch.loadWithConfig(entry.component, comp.root, cfg_ptr);
    }

    /// Adopt an entry's config into a Realized record, freeing any config the
    /// record previously owned. Takes ownership of `desired`'s config.
    fn adoptConfig(self: *Self, cur: *Realized, desired: ConfigEntry) void {
        if (cur.config) |old| old.deinit(self.allocator);
        cur.config = desired.config;
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
                // New entry. Reserve the map slot before loading so a load
                // failure cannot strand an owned config.
                var realized = Realized{ .component = entry.component, .enabled = entry.enabled, .fiber = null, .config = entry.config };
                if (entry.enabled) {
                    realized.fiber = self.loadEntry(entry) catch |err| {
                        if (entry.config) |c| c.deinit(self.allocator);
                        return err;
                    };
                }
                self.entries.put(self.allocator, entry.name, realized) catch |err| {
                    if (realized.fiber) |fid| self.orch.unloadFiber(fid) catch {};
                    if (realized.fiber) |fid| self.orch.removeFiber(fid) catch {};
                    if (entry.config) |c| c.deinit(self.allocator);
                    return err;
                };
            }
        }

        // 2. Remove entries no longer present in `desired`.
        try self.pruneAbsent(desired);
    }

    fn reconcileExisting(self: *Self, entry: ConfigEntry, cur: *Realized) !void {
        // Material change (§5.2.1) = code changed OR config VALUE changed.
        const material = !sameCode(cur.component, entry.component) or configChanged(cur.config, entry.config);

        if (material) {
            // §5.2.2 HMR / §4.4 Configuration revision: retire+remove the old
            // fiber, adopt the new code+config, load a fresh one.
            try self.teardownEntry(cur);
            cur.component = entry.component;
            cur.enabled = entry.enabled;
            self.adoptConfig(cur, entry); // frees old config, takes new
            if (entry.enabled) {
                cur.fiber = try self.loadEntry(entry);
            }
            return;
        }

        // No material change: handle enable/disable transitions. The config is
        // unchanged, so free the duplicate the desired entry carries (we keep
        // ours) to avoid leaking it.
        if (entry.config) |c| c.deinit(self.allocator);

        if (cur.enabled and !entry.enabled) {
            // Disable: retire + remove, keep the entry (and its config) tracked.
            try self.teardownEntry(cur);
            cur.enabled = false;
        } else if (!cur.enabled and entry.enabled) {
            // Re-enable: instantiate a FRESH fiber (§4.4 Configuration).
            cur.enabled = true;
            cur.fiber = try self.orch.loadWithConfig(
                cur.component,
                comp.root,
                if (cur.config) |cc| cc.ptr else null,
            );
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
            if (cur.config) |c| c.deinit(self.allocator);
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

// ── Config-driven reconciliation (§5.2.1 material change via config) ──

const PortCfg = struct { port: u16 };
const port_schema = schema_mod.Schema(PortCfg){ .constraints = &.{
    .{ .int_range = .{ .field = "port", .min = 1, .max = 65535 } },
} };

// A provider whose provisioned value is read from its config (port), so the
// effect observably depends on the config value.
fn portProvider() Component {
    const S = struct {
        const k = [_]Key{Key.of(u16, "server.port")};
        fn apply(ctx: *@import("../context/context.zig").Context, config: ?*anyopaque) anyerror!@import("../context/context.zig").Context.Iterator {
            const Ctx = @import("../context/context.zig").Context;
            const Iter = struct {
                port: u16,
                fn make(a: std.mem.Allocator, port: u16) !Ctx.Iterator {
                    const self = try a.create(@This());
                    self.* = .{ .port = port };
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(state: *anyopaque, a: std.mem.Allocator, c: *Ctx) anyerror!fixtures.Step(Ctx) {
                    const self: *@This() = @ptrCast(@alignCast(state));
                    try c.store.set(u16, Key.of(u16, "server.port"), self.port);
                    const kb = try a.create(Key);
                    kb.* = Key.of(u16, "server.port");
                    const Inv = struct {
                        fn call(s: *anyopaque, cc: *Ctx) void {
                            cc.store.restrict(@as(*Key, @ptrCast(@alignCast(s))).*) catch {};
                        }
                        fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                            aa.destroy(@as(*Key, @ptrCast(@alignCast(s))));
                        }
                    };
                    return .{ .inverse = .{ .state = kb, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
                }
                fn deinit(state: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(state))));
                }
            };
            const cfg: *const PortCfg = @ptrCast(@alignCast(config.?));
            return Iter.make(ctx.allocator, cfg.port);
        }
    };
    return .{ .inject = &.{}, .provide = &S.k, .apply = S.apply };
}

test "§5.2.1 config: a validated config is passed to apply" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    const cfg = try Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 8080 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = cfg }});

    try std.testing.expectEqual(@as(u16, 8080), try loader.orch.root_ctx.get(u16, Key.of(u16, "server.port")));
}

test "§5.2.1 material change: a config VALUE change reloads the fiber" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();
    const kport = Key.of(u16, "server.port");

    const c1 = try Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 8080 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c1 }});
    const fid1 = loader.entries.get("srv").?.fiber.?;
    try std.testing.expectEqual(@as(u16, 8080), try loader.orch.root_ctx.get(u16, kport));

    // Same code (same apply), DIFFERENT config value → material change → reload.
    const c2 = try Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 9090 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c2 }});
    const fid2 = loader.entries.get("srv").?.fiber.?;

    try std.testing.expect(fid1 != fid2); // fiber swapped
    try std.testing.expectEqual(@as(u16, 9090), try loader.orch.root_ctx.get(u16, kport));
}

test "§5.2.1 config: an unchanged config value is a no-op (no reload)" {
    var loader = try Loader.init(std.testing.allocator);
    defer loader.deinit();

    const c1 = try Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 8080 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c1 }});
    const fid1 = loader.entries.get("srv").?.fiber;

    const c2 = try Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 8080 }); // same value
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c2 }});
    const fid2 = loader.entries.get("srv").?.fiber;

    try std.testing.expectEqual(fid1, fid2); // not reloaded
}

test "schema: an invalid config is rejected before load" {
    try std.testing.expectError(
        schema_mod.ValidationError.OutOfRange,
        Config.of(std.testing.allocator, PortCfg, port_schema, .{ .port = 0 }),
    );
}

fn configReconcileUnderOom(allocator: std.mem.Allocator) !void {
    var loader = try Loader.init(allocator);
    defer loader.deinit();
    const c1 = try Config.of(allocator, PortCfg, port_schema, .{ .port = 8080 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c1 }});
    const c2 = try Config.of(allocator, PortCfg, port_schema, .{ .port = 9090 });
    try loader.reconcile(&.{.{ .name = "srv", .component = portProvider(), .config = c2 }});
}

test "OOM safety: config-driven reconcile leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configReconcileUnderOom, .{});
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
