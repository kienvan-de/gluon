//! Integration tests for the lifecycle state machine (Algorithm 5), notify
//! (Algorithm 3), and the ordering guard (Theorem 70). Validates the global
//! form of spatial composability on small fiber systems.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const comp = @import("component.zig");
const Context = @import("../context/context.zig").Context;
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

const Orchestrator = lifecycle.Orchestrator;
const Component = comp.Component;
const Key = store_mod.Key;

// ── A provider component: on activation, provisions `key := value`. ──

fn ProviderApply(comptime key_name: []const u8, comptime value: u32) comp.Apply {
    const Impl = struct {
        const k = Key.of(u32, key_name);
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                done: bool = false,
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(state: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!effect_iter.Step(Context) {
                    _ = state;
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
                fn deinit(state: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(state))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return Impl.apply;
}

/// A consumer that declares `key_name` but provisions nothing.
fn consumerComponent(comptime key_name: []const u8) Component {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_name)};
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            // A no-op single-step effect (unit): yields identity inverse.
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!effect_iter.Step(Context) {
                    const Noop = struct {
                        fn call(_: *anyopaque, _: *Context) void {}
                        fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
                    };
                    return .{ .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn }, .done = true };
                }
                fn deinit(state: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(state))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return .{ .inject = &S.k, .provide = &.{}, .apply = S.apply };
}

fn providerComponent(comptime key_name: []const u8, comptime value: u32) Component {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_name)};
    };
    return .{ .inject = &.{}, .provide = &S.k, .apply = ProviderApply(key_name, value) };
}

test "a provider with no deps activates immediately on load" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const kdb = Key.of(u32, "db");
    const id = try orch.load(providerComponent("db", 5432), comp.root);

    const fiber = orch.registry.get(id).?;
    try std.testing.expectEqual(comp.Phase.active, fiber.phase);
    try std.testing.expect(orch.isProvided(kdb));
    try std.testing.expectEqual(@as(u32, 5432), try orch.root_ctx.get(u32, kdb));
}

test "a consumer stays inactive until its dependency is provided" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load the consumer first — its dep "db" is absent, so it stays inactive.
    const consumer_id = try orch.load(consumerComponent("db"), comp.root);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(consumer_id).?.phase);

    // Now load the provider; notify must activate the consumer reactively.
    const provider_id = try orch.load(providerComponent("db", 1), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(provider_id).?.phase);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(consumer_id).?.phase);
}

test "Theorem 70 ordering: retiring a provider deactivates its consumer first" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const provider_id = try orch.load(providerComponent("db", 1), comp.root);
    const consumer_id = try orch.load(consumerComponent("db"), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(consumer_id).?.phase);

    // Retire the provider. The guard defers its withdrawal until the consumer
    // (which resolves "db" to it) has deactivated.
    try orch.unloadFiber(provider_id);

    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(provider_id).?.phase);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(consumer_id).?.phase);
}

test "Corollary 69: a deactivated provider leaves Σ clean (binding withdrawn)" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const kdb = Key.of(u32, "db");
    const provider_id = try orch.load(providerComponent("db", 1), comp.root);
    try std.testing.expect(orch.isProvided(kdb));

    try orch.unloadFiber(provider_id);
    try std.testing.expect(!orch.isProvided(kdb)); // provision reverted
    try std.testing.expect(!orch.root_ctx.has(kdb)); // store binding gone
}

test "reload after re-satisfaction: consumer reactivates when provider returns" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const provider_id = try orch.load(providerComponent("db", 1), comp.root);
    const consumer_id = try orch.load(consumerComponent("db"), comp.root);

    try orch.unloadFiber(provider_id);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(consumer_id).?.phase);

    // Per §4.3.1, the retired provider still holds its provision until it is
    // removed (O-Remove); only then may the key be reissued. Remove it first.
    try orch.removeFiber(provider_id);

    // Load a NEW provider of "db"; the consumer must reactivate.
    _ = try orch.load(providerComponent("db", 2), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(consumer_id).?.phase);
}

test "O-Remove after deactivation frees the fiber" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const id = try orch.load(providerComponent("x", 9), comp.root);
    try orch.unloadFiber(id);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(id).?.phase);
    try orch.removeFiber(id);
    try std.testing.expectEqual(@as(?*comp.Fiber, null), orch.registry.get(id));
}

test "Definition 52: retiring a parent cascades to its instantiated children" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const kc = Key.of(u32, "c");
    const parent_id = try orch.load(providerComponent("p", 1), comp.root);
    const child_id = try orch.load(providerComponent("c", 2), parent_id);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(child_id).?.phase);
    try std.testing.expect(orch.isProvided(kc));

    // Retiring the parent cascades: the child it instantiated is retired and
    // deactivated too, and its provision is withdrawn (Def 52 cascade).
    try orch.unloadFiber(parent_id);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(parent_id).?.phase);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(child_id).?.phase);
    try std.testing.expect(orch.registry.get(child_id).?.retired);
    try std.testing.expect(!orch.isProvided(kc));
}

test "Definition 52: cascade reaches grandchildren (transitive)" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const gp = try orch.load(providerComponent("gp", 1), comp.root);
    const p = try orch.load(providerComponent("p", 2), gp);
    const c = try orch.load(providerComponent("c", 3), p);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(c).?.phase);

    try orch.unloadFiber(gp);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(p).?.phase);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(c).?.phase);
}

// ── Confluence (Theorem 80) and OOM safety ──────────────────────────

test "Theorem 80 confluence: load order does not change the quiescent state" {
    // Two providers (a, b) and a consumer of both. Whatever order we load
    // them in, the system quiesces with all three active and both keys bound.
    const Scenario = struct {
        fn run(order: [3]u8) !void {
            var orch = try Orchestrator.init(std.testing.allocator);
            defer orch.deinit();

            const ca = providerComponent("a", 1);
            const cb = providerComponent("b", 2);
            const S = struct {
                const keys = [_]Key{ Key.of(u32, "a"), Key.of(u32, "b") };
                fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
                    const Iter = struct {
                        fn make(al: std.mem.Allocator) !Context.Iterator {
                            const self = try al.create(@This());
                            self.* = .{};
                            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                        }
                        fn next(_: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!effect_iter.Step(Context) {
                            const Noop = struct {
                                fn call(_: *anyopaque, _: *Context) void {}
                                fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
                            };
                            return .{ .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn }, .done = true };
                        }
                        fn deinit(s: *anyopaque, al: std.mem.Allocator) void {
                            al.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
                        }
                    };
                    return Iter.make(ctx.allocator);
                }
            };
            const consumer = Component{ .inject = &S.keys, .provide = &.{}, .apply = S.apply };
            const comps = [_]Component{ ca, cb, consumer };

            var ids: [3]comp.FiberId = undefined;
            for (order, 0..) |which, i| ids[i] = try orch.load(comps[which], comp.root);

            // Quiescent state is identical regardless of order: all active.
            for (ids) |id| {
                try std.testing.expectEqual(comp.Phase.active, orch.registry.get(id).?.phase);
            }
            try std.testing.expect(orch.isProvided(Key.of(u32, "a")));
            try std.testing.expect(orch.isProvided(Key.of(u32, "b")));
        }
    };

    // All permutations of {provider-a, provider-b, consumer} reach the same
    // quiescent configuration (Thm 80: history leaves no trace).
    try Scenario.run(.{ 0, 1, 2 });
    try Scenario.run(.{ 2, 1, 0 });
    try Scenario.run(.{ 2, 0, 1 });
    try Scenario.run(.{ 1, 2, 0 });
}

fn orchestratorScenario(allocator: std.mem.Allocator) !void {
    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();
    const provider_id = try orch.load(providerComponent("db", 1), comp.root);
    const consumer_id = try orch.load(consumerComponent("db"), comp.root);
    try orch.unloadFiber(provider_id);
    try orch.removeFiber(provider_id);
    _ = consumer_id;
}

test "OOM safety: full orchestrator scenario leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, orchestratorScenario, .{});
}

// ── Theorem 47: commutativity witness enforcement at load (Def 46) ──

test "Def 46/Thm 47: a non-commutative provision is rejected at load" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // A component that provides an order-sensitive key without opting into
    // ordering: declared non-commutative, so load must reject it.
    const S = struct {
        const k = [_]Key{Key.of(u32, "middleware.chain")};
    };
    const bad = Component{
        .inject = &.{},
        .provide = &S.k,
        .apply = ProviderApply("middleware.chain", 1),
        .provide_witness = .{ .kind = .non_commutative, .justification = "ordered chain" },
    };

    try std.testing.expectError(error.NonCommutativeProvision, orch.load(bad, comp.root));
    // Nothing was left behind.
    try std.testing.expect(!orch.isProvided(Key.of(u32, "middleware.chain")));
}

test "Def 46: a commutative (tagged-registry) provision loads normally" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const S = struct {
        const k = [_]Key{Key.of(u32, "router.routes")};
    };
    const ok = Component{
        .inject = &.{},
        .provide = &S.k,
        .apply = ProviderApply("router.routes", 1),
        .provide_witness = .{ .kind = .tagged_registry, .justification = "unique route ids" },
    };

    const id = try orch.load(ok, comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(id).?.phase);
}

test "default witness is commutative: existing simple components still load" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();
    // providerComponent sets no witness → defaults to trivial/commutative.
    const id = try orch.load(providerComponent("db", 1), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(id).?.phase);
}
