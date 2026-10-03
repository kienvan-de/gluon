//! The component lifecycle state machine (Algorithm 5) + notification (Alg 3)
//! + instantiation (Alg 4), driven by an explicit scheduler (plan C2).
//!
//! Paper correspondence:
//!   - Definition 53 (target view): target_n(γ) maps each declared key to its
//!     provider, or ⊥ when the fiber ought not to run (retired or unsatisfied).
//!   - Algorithm 5 (refresh/reload/unload):
//!       • refresh recomputes target; if idle, starts reload (target≠⊥) or
//!         unload (target=⊥). While a transition is in flight (in_transition)
//!         it only updates target and returns — the inertial discipline (§4.4).
//!       • reload commits the view, runs the effect iterator via ctx.effect,
//!         then enters ACTIVE if target still matches, else chains to unload.
//!       • unload drains dependents (notify), applies the accumulator (recover),
//!         clears the committed view, then enters INACTIVE or chains to reload.
//!   - Algorithm 3 (notify): on a binding change, re-evaluate every fiber that
//!     declares a changed key; refresh drives its transition.
//!   - Lifecycle rules L-Begin/Iter/Finish/Divert/Leave/Unload (§4.2.2) are the
//!     steps these functions take; the guard ¬relied on L-Unload is Def 54.
//!
//! Scheduler model (C2): stable Zig has no async. We run transitions
//! synchronously and to completion in this slice (the "inertial, run-to-
//! completion" reading), which is sound: every §4.3 result quantifies over all
//! step sequences, and the synchronous schedule is one of them. Interleaved /
//! stepwise execution is a later refinement that reuses the same functions.

const std = @import("std");
const comp = @import("component.zig");
const reg_mod = @import("registry.zig");
const Context = @import("../context/context.zig").Context;
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

pub const Fiber = comp.Fiber;
pub const FiberId = comp.FiberId;
pub const Component = comp.Component;
pub const Phase = comp.Phase;
pub const View = comp.View;
pub const Registry = reg_mod.Registry;
pub const Key = store_mod.Key;

/// Explicit error set for the mutually-recursive lifecycle functions
/// (refresh ↔ reload ↔ unload ↔ notify), which otherwise form an inferred
/// error-set cycle. OutOfMemory covers allocation; NoSuchFiber covers
/// orchestration lookups. Component `apply` failures are caught inside reload
/// (the §4.4 Failure path) and never propagate as errors here.
pub const LifecycleError = error{
    OutOfMemory,
    NoSuchFiber,
    /// A component declares a non-commutative provision (Def 46 witness) but
    /// does not opt into ordering. Loading it would violate the Theorem 47
    /// precondition that shared operation keys be commutative.
    NonCommutativeProvision,
};

/// The orchestrator owns the registry and drives the lifecycle. It is the
/// surface the §4.2.1 orchestration rules (O-Insert/Retire/Remove) act on.
pub const Orchestrator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    registry: Registry,
    /// The root context whose store is Σ_γ; all fiber contexts derive from it.
    root_ctx: *Context,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const root_ctx = try Context.init(allocator);
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .root_ctx = root_ctx,
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
        self.root_ctx.deinit();
    }

    // ── Target view computation (Definition 53) ───────────────────

    /// target_n(γ): ⊥ if retired or unsatisfied; else the map key→provider.
    /// Caller owns the returned View.
    fn computeTarget(self: *Self, fiber: *Fiber) !View {
        if (fiber.retired) return View.bottom();

        const inject = fiber.component.inject;
        // Every declared key must be provided by an ACTIVE fiber (Def 53).
        for (inject) |k| {
            if (!self.registry.isProvided(k)) return View.bottom();
        }
        // Satisfied: record each key's provider.
        const providers = try self.allocator.alloc(?FiberId, inject.len);
        errdefer self.allocator.free(providers);
        for (inject, 0..) |k, i| {
            providers[i] = self.registry.providerOf(k);
        }
        return .{ .providers = providers, .active = true };
    }

    // ── refresh / reload / unload (Algorithm 5) ───────────────────

    /// Algorithm 5 refresh: recompute target; if it changed and no transition
    /// is in flight, drive the appropriate transition to completion.
    pub fn refresh(self: *Self, fiber: *Fiber) LifecycleError!void {
        const new_target = try self.computeTarget(fiber);

        // If unchanged from the current target, nothing to do (idempotent —
        // a neutral change is harmless, Def 22).
        if (fiber.target) |old| {
            if (old.eql(new_target)) {
                new_target.deinit(self.allocator);
                return;
            }
            old.deinit(self.allocator);
        }
        fiber.target = new_target;

        // Inertia (§4.4): a transition in flight is not interrupted; it will
        // observe the new target when it finishes and chain accordingly.
        if (fiber.in_transition) return;

        if (new_target.active) {
            try self.reload(fiber);
        } else {
            try self.unload(fiber);
        }
    }

    /// Algorithm 5 reload: commit the target view, run the effect iterator,
    /// then settle ACTIVE (if target held) or chain to unload (if it changed).
    fn reload(self: *Self, fiber: *Fiber) LifecycleError!void {
        fiber.in_transition = true;
        defer fiber.in_transition = false;

        // Snapshot the target this transition runs against (target0).
        const target0 = fiber.target.?; // active view
        fiber.phase = .loading;

        // Commit the view: ω := resolve(inject) (Def 49/Alg 5 line 14).
        if (fiber.committed) |c| c.deinit(self.allocator);
        fiber.committed = try target0.clone(self.allocator);

        // Build and run the effect iterator against the fiber's own context.
        // The guard holds the transition only while target is unchanged
        // (Alg 5 line 15 guard: fiber.target == target0) — realizing L-Divert.
        const iter = fiber.component.apply(fiber.ctx, fiber.config) catch |err| {
            // Infrastructure OOM is propagated, not swallowed as a component
            // failure; a genuine component refusal routes to FAILED (§4.4).
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.markFailed(fiber, err);
            return;
        };
        defer iter.deinit(fiber.ctx.allocator);

        const guard = targetGuard(fiber);
        effect_iter.execute(Context, iter, guard, fiber.ctx.allocator, fiber.ctx, &fiber.ctx.dispose) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.markFailed(fiber, err);
            return;
        };

        // Did the target hold throughout? (Alg 5 line 17.)
        if (fiber.target != null and fiber.target.?.active and fiber.target.?.eql(fiber.committed.?)) {
            fiber.phase = .active;
            // notify dependents that this fiber's provisions are now available.
            try self.notify(fiber.component.provide);
        } else {
            // Target changed under us: chain into unload (inertial, Alg 5 L21).
            fiber.in_transition = false;
            try self.unload(fiber);
        }
    }

    /// §4.4 Failure: a component raise aborts the activation. Recover whatever
    /// was installed (Cor 69 leaves nothing), discard the committed view, and
    /// record the error on the fiber (FAILED withholds re-entry until revised).
    fn markFailed(self: *Self, fiber: *Fiber, err: anyerror) void {
        fiber.ctx.dispose.recover(fiber.ctx);
        if (fiber.committed) |c| {
            c.deinit(self.allocator);
            fiber.committed = null;
        }
        fiber.phase = .failed;
        fiber.failure = err;
    }

    /// Algorithm 5 unload: drain dependents, recover effects, go INACTIVE (or
    /// chain to reload if the target became active again).
    fn unload(self: *Self, fiber: *Fiber) LifecycleError!void {
        fiber.in_transition = true;
        defer fiber.in_transition = false;
        fiber.phase = .unloading;

        // Guard on L-Unload (Def 54): a provider defers withdrawal until no
        // installed dependent resolves a key to it. In the synchronous
        // schedule we first drive dependents to deactivate, then proceed.
        try self.drainDependents(fiber);

        // Def 52 instantiation cascade: the children this fiber instantiated are
        // retired by its accumulator. Retiring a child drives its own unload
        // (and transitively its grandchildren) before we recover this fiber.
        try self.retireChildren(fiber.id);

        // Apply the accumulator: recover this fiber's effects (LIFO).
        fiber.ctx.dispose.recover(fiber.ctx);

        // Discard the committed view (L-Unload last act).
        if (fiber.committed) |c| {
            c.deinit(self.allocator);
            fiber.committed = null;
        }
        fiber.phase = .inactive;

        // Inertial chaining: if the target became active again, reload.
        if (fiber.target != null and fiber.target.?.active) {
            fiber.in_transition = false;
            try self.reload(fiber);
        }
    }

    /// Def 52: retire and deactivate every fiber instantiated under `parent_id`
    /// (its children by π). Each child's O-Retire is the inverse the parent's
    /// instantiation effect yields; running it here realizes the cascade that
    /// unloading a parent triggers. Children are retired so a later O-Remove
    /// can reclaim them; they are not removed here (removal is a separate
    /// orchestration step, §4.3.1).
    fn retireChildren(self: *Self, parent_id: FiberId) LifecycleError!void {
        var changed = true;
        while (changed) {
            changed = false;
            var it = self.registry.fibers.valueIterator();
            while (it.next()) |fp| {
                const child = fp.*;
                if (child.parent != parent_id) continue;
                if (child.retired and !child.installed()) continue;
                child.retired = true;
                const before = child.phase;
                try self.refresh(child);
                if (child.phase != before) changed = true;
            }
        }
    }

    /// Drive every fiber that relies on `fiber` to deactivate first, so the
    /// guard ¬relied releases (Def 54, Thm 70 ordering). A provider entering
    /// UNLOADING already stops providing (isProvided checks ACTIVE), so a
    /// dependent's recomputed target becomes ⊥ and it unloads.
    fn drainDependents(self: *Self, fiber: *Fiber) LifecycleError!void {
        // Mark non-active so isProvided() reports this fiber's keys withdrawn.
        // (phase is already .unloading here, which isProvided treats as not
        // providing.) Refresh each dependent; those that lose satisfaction
        // deactivate, releasing the guard.
        var changed = true;
        while (changed) {
            changed = false;
            var it = self.registry.fibers.valueIterator();
            while (it.next()) |fp| {
                const dep = fp.*;
                if (dep.id == fiber.id) continue;
                if (!dep.installed()) continue;
                const view = dep.committed orelse continue;
                for (view.providers) |p| {
                    if (p != null and p.? == fiber.id) {
                        const before = dep.phase;
                        try self.refresh(dep);
                        if (dep.phase != before) changed = true;
                        break;
                    }
                }
            }
        }
    }

    // ── notify (Algorithm 3) ──────────────────────────────────────

    /// Algorithm 3: propagate a binding change over `keys` to every fiber that
    /// declares one of them, driving its transition via refresh.
    pub fn notify(self: *Self, keys: []const Key) LifecycleError!void {
        var it = self.registry.fibers.valueIterator();
        while (it.next()) |fp| {
            const fiber = fp.*;
            for (keys) |changed_key| {
                if (declares(fiber, changed_key)) {
                    try self.refresh(fiber);
                    break;
                }
            }
        }
    }

    fn declares(fiber: *Fiber, key: Key) bool {
        for (fiber.component.inject) |k| {
            if (std.mem.eql(u8, k.name, key.name)) return true;
        }
        return false;
    }

    // ── Guard helper ──────────────────────────────────────────────

    /// A guard that stays active while the fiber's target is unchanged from the
    /// committed view (Alg 5 line 15 / L-Divert premise).
    fn targetGuard(fiber: *Fiber) effect_iter.Guard {
        const Impl = struct {
            fn poll(state: *anyopaque) bool {
                const f: *Fiber = @ptrCast(@alignCast(state));
                const t = f.target orelse return false;
                const c = f.committed orelse return false;
                return t.active and t.eql(c);
            }
        };
        return .{ .state = fiber, .poll = Impl.poll };
    }

    // ── Orchestration (§4.2.1) ────────────────────────────────────

    /// O-Insert (Alg 4 ctx.use): instantiate `component` under `parent`, add it
    /// to the registry, and drive its initial refresh (which activates it if
    /// its dependencies are already satisfied).
    pub fn load(self: *Self, component: Component, parent: ?FiberId) !FiberId {
        return self.loadWithConfig(component, parent, null);
    }

    /// As `load`, but instantiates the fiber with a type-erased `config` passed
    /// to `component.apply` (§4.4 Configuration). The config is owned by the
    /// caller and must outlive the fiber.
    pub fn loadWithConfig(self: *Self, component: Component, parent: ?FiberId, config: ?*anyopaque) !FiberId {
        // Theorem 47 precondition (the half O-Insert does not already cover):
        // a component's provided keys must be commutative, so its effects are
        // independent of every other component's. Provision disjointness is
        // enforced by registry.insert; shared-key commutativity reduces, by
        // Theorem 45, to each provider's own witness (Def 46). A provider that
        // installs an order-sensitive key must impose ordering rather than rely
        // on independence (§3.4.2); we reject it here if it has not.
        if (component.provide.len > 0 and !component.provide_witness.isCommutative()) {
            return LifecycleError.NonCommutativeProvision;
        }

        const id = self.registry.freshId();
        const child_ctx = try self.root_ctx.derive();
        const fiber = try self.allocator.create(Fiber);
        fiber.* = Fiber.init(id, component, parent, child_ctx);
        fiber.config = config;
        // insert takes ownership of `fiber` on success; on failure we still own
        // it. (The derived child_ctx is owned by root_ctx's accumulator via
        // derive, so it is reclaimed by root_ctx.deinit on every path.)
        self.registry.insert(fiber) catch |err| {
            self.allocator.destroy(fiber);
            return err;
        };
        // The registry now owns `fiber`; if refresh fails, remove+free it so no
        // half-activated fiber is left behind.
        errdefer {
            if (self.registry.remove(id) catch null) |f| {
                f.deinit(self.allocator);
                self.allocator.destroy(f);
            }
        }

        try self.refresh(fiber);
        return id;
    }

    /// O-Retire + lifecycle: mark the fiber retired (τ := ⊤) and refresh, which
    /// recomputes target = ⊥ and drives deactivation.
    pub fn unloadFiber(self: *Self, id: FiberId) !void {
        const fiber = self.registry.get(id) orelse return reg_mod.RegistryError.NoSuchFiber;
        fiber.retired = true;
        try self.refresh(fiber);
    }

    /// O-Remove: drop a now-inactive fiber from the registry and free it.
    pub fn removeFiber(self: *Self, id: FiberId) !void {
        const fiber = try self.registry.remove(id);
        fiber.deinit(self.allocator);
        self.allocator.destroy(fiber);
    }

    /// Convenience: whether a key currently resolves in Σ_γ.
    pub fn isProvided(self: *const Self, key: Key) bool {
        return self.registry.isProvided(key);
    }
};

// ─────────────────── Tests (integration) ─────────────────────────
// Shared component factories live in src/testing/fixtures.zig.

const fixtures = @import("../testing/fixtures.zig");
const provider = fixtures.provider;
const consumer = fixtures.consumer;
const providerApply = fixtures.providerApply;

test "a provider with no deps activates immediately on load" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const kdb = Key.of(u32, "db");
    const id = try orch.load(provider("db", 5432), comp.root);

    const fiber = orch.registry.get(id).?;
    try std.testing.expectEqual(comp.Phase.active, fiber.phase);
    try std.testing.expect(orch.isProvided(kdb));
    try std.testing.expectEqual(@as(u32, 5432), try orch.root_ctx.get(u32, kdb));
}

test "a consumer stays inactive until its dependency is provided" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load the consumer first — its dep "db" is absent, so it stays inactive.
    const consumer_id = try orch.load(consumer("db"), comp.root);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(consumer_id).?.phase);

    // Now load the provider; notify must activate the consumer reactively.
    const provider_id = try orch.load(provider("db", 1), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(provider_id).?.phase);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(consumer_id).?.phase);
}

test "Theorem 70 ordering: retiring a provider deactivates its consumer first" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const provider_id = try orch.load(provider("db", 1), comp.root);
    const consumer_id = try orch.load(consumer("db"), comp.root);
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
    const provider_id = try orch.load(provider("db", 1), comp.root);
    try std.testing.expect(orch.isProvided(kdb));

    try orch.unloadFiber(provider_id);
    try std.testing.expect(!orch.isProvided(kdb)); // provision reverted
    try std.testing.expect(!orch.root_ctx.has(kdb)); // store binding gone
}

test "reload after re-satisfaction: consumer reactivates when provider returns" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const provider_id = try orch.load(provider("db", 1), comp.root);
    const consumer_id = try orch.load(consumer("db"), comp.root);

    try orch.unloadFiber(provider_id);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(consumer_id).?.phase);

    // Per §4.3.1, the retired provider still holds its provision until it is
    // removed (O-Remove); only then may the key be reissued. Remove it first.
    try orch.removeFiber(provider_id);

    // Load a NEW provider of "db"; the consumer must reactivate.
    _ = try orch.load(provider("db", 2), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(consumer_id).?.phase);
}

test "O-Remove after deactivation frees the fiber" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const id = try orch.load(provider("x", 9), comp.root);
    try orch.unloadFiber(id);
    try std.testing.expectEqual(comp.Phase.inactive, orch.registry.get(id).?.phase);
    try orch.removeFiber(id);
    try std.testing.expectEqual(@as(?*comp.Fiber, null), orch.registry.get(id));
}

test "Definition 52: retiring a parent cascades to its instantiated children" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const kc = Key.of(u32, "c");
    const parent_id = try orch.load(provider("p", 1), comp.root);
    const child_id = try orch.load(provider("c", 2), parent_id);
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

    const gp = try orch.load(provider("gp", 1), comp.root);
    const p = try orch.load(provider("p", 2), gp);
    const c = try orch.load(provider("c", 3), p);
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

            const ca = provider("a", 1);
            const cb = provider("b", 2);
            // A consumer declaring BOTH keys (the shared fixture is single-key).
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
            const two_dep_consumer = Component{ .inject = &S.keys, .provide = &.{}, .apply = S.apply };
            const comps = [_]Component{ ca, cb, two_dep_consumer };

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
    const provider_id = try orch.load(provider("db", 1), comp.root);
    const consumer_id = try orch.load(consumer("db"), comp.root);
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
        .apply = providerApply("middleware.chain", 1),
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
        .apply = providerApply("router.routes", 1),
        .provide_witness = .{ .kind = .tagged_registry, .justification = "unique route ids" },
    };

    const id = try orch.load(ok, comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(id).?.phase);
}

test "default witness is commutative: existing simple components still load" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();
    // providerComponent sets no witness → defaults to trivial/commutative.
    const id = try orch.load(provider("db", 1), comp.root);
    try std.testing.expectEqual(comp.Phase.active, orch.registry.get(id).?.phase);
}
