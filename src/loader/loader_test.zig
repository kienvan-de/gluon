//! Tests for the declarative loader (§5.2): reconciliation, enable/disable,
//! and hot module replacement.

const std = @import("std");
const loader_mod = @import("loader.zig");
const comp = @import("../component/component.zig");
const Context = @import("../context/context.zig").Context;
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

const Loader = loader_mod.Loader;
const Component = comp.Component;
const ConfigEntry = loader_mod.ConfigEntry;
const Key = store_mod.Key;

// A provider component that provisions `key := value`.
fn providerApply(comptime key_name: []const u8, comptime value: u32) comp.Apply {
    const Impl = struct {
        const k = Key.of(u32, key_name);
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!effect_iter.Step(Context) {
                    try c.store.set(u32, k, value);
                    const kb = try a.create(Key);
                    kb.* = k;
                    const Inv = struct {
                        fn call(s: *anyopaque, cc: *Context) void {
                            cc.store.restrict(@as(*Key, @ptrCast(@alignCast(s))).*) catch {};
                        }
                        fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                            aa.destroy(@as(*Key, @ptrCast(@alignCast(s))));
                        }
                    };
                    return .{ .inverse = .{ .state = kb, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
                }
                fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return Impl.apply;
}

fn provider(comptime key_name: []const u8, comptime value: u32) Component {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_name)};
    };
    return .{ .inject = &.{}, .provide = &S.k, .apply = providerApply(key_name, value) };
}

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
