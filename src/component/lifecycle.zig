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
        const iter = fiber.component.apply(fiber.ctx, null) catch |err| {
            // §4.4 Failure: raise aborts to UNLOADING-equivalent; recover what
            // was installed (nothing yet here) and mark FAILED.
            fiber.ctx.dispose.recover(fiber.ctx);
            if (fiber.committed) |c| {
                c.deinit(self.allocator);
                fiber.committed = null;
            }
            fiber.phase = .failed;
            fiber.failure = err;
            return;
        };
        defer iter.deinit(fiber.ctx.allocator);

        const guard = targetGuard(fiber);
        effect_iter.execute(Context, iter, guard, fiber.ctx.allocator, fiber.ctx, &fiber.ctx.dispose) catch |err| {
            // A raise during iteration: recover installed effects, mark FAILED.
            fiber.ctx.dispose.recover(fiber.ctx);
            if (fiber.committed) |c| {
                c.deinit(self.allocator);
                fiber.committed = null;
            }
            fiber.phase = .failed;
            fiber.failure = err;
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
        const id = self.registry.freshId();
        const child_ctx = try self.root_ctx.derive();
        const fiber = try self.allocator.create(Fiber);
        errdefer self.allocator.destroy(fiber);
        fiber.* = Fiber.init(id, component, parent, child_ctx);
        try self.registry.insert(fiber);

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

// ───────────────────────────── Tests ─────────────────────────────
// Covered in lifecycle_test.zig (needs richer fixtures).

test {
    _ = Orchestrator;
}
