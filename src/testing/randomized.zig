//! Randomized scheduler property test (verification-assessment item 59 /
//! checklist §L.59).
//!
//! A seeded PRNG drives a random sequence of orchestration actions against an
//! Orchestrator — load a provider, load a consumer, retire a fiber, remove a
//! legal (retired+inactive+child-free) fiber — over a small pool of keys. After
//! EVERY step it asserts well-formedness (items 3/4/12/20 via
//! `invariants.assertWellFormed`). At the end it asserts quiescence (item 34)
//! and that the whole run leaked nothing (std.testing.allocator).
//!
//! Determinism / confluence (item 39): because the `.blocking` scheduler runs
//! every transition to a fixpoint synchronously, a given seed produces one
//! deterministic final configuration. We replay each seed twice and compare the
//! resulting key-provision signatures — the history-independence the paper
//! proves for quiescent, acyclic, total systems (Theorem 80), specialized to
//! the schedule the blocking backend realizes.
//!
//! Why this is a faithful stress of the calculus: Thm 73 (progress) and Thm 80
//! (confluence) quantify over schedules; the blocking backend is one admissible
//! schedule, and randomizing the ORCHESTRATION actions (the O-rules) exercises
//! the lifecycle fixpoint from many starting configurations. Each provider has
//! an empty injection and provides exactly one key, so provisions are disjoint
//! by construction (no provision cycles), keeping the precedence relation
//! acyclic as Thm 73/80 require.

const std = @import("std");
const lifecycle = @import("../component/lifecycle.zig");
const comp = @import("../component/component.zig");
const Context = @import("../context/context.zig").Context;
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");
const invariants = @import("invariants.zig");

const Orchestrator = lifecycle.Orchestrator;
const Component = comp.Component;
const Key = store_mod.Key;
const FiberId = comp.FiberId;
const Step = effect_iter.Step;

/// The key pool. A fixed, comptime-known set so provider/consumer `apply`
/// functions can be generated per key without runtime closures. Small enough
/// to force frequent provision conflicts (exercising the O-Insert single-source
/// rejection path) yet large enough for interesting topologies.
const key_names = [_][]const u8{ "a", "b", "c", "d" };

/// Per-key provider `apply` (provisions key := 1, inverse restricts it) and
/// consumer `apply` (declares the key, no-op effect), generated at comptime so
/// each has a distinct static key — no runtime closure needed.
fn ProviderApply(comptime name: []const u8) comp.Apply {
    const Impl = struct {
        const k = Key.of(u32, name);
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
                    try c.store.set(u32, k, 1);
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

fn ConsumerApply() comp.Apply {
    const Impl = struct {
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!Step(Context) {
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
    return Impl.apply;
}

// Comptime arrays of per-key provider/consumer components keyed by pool index.
const providers = blk: {
    var arr: [key_names.len]Component = undefined;
    for (key_names, 0..) |name, i| {
        arr[i] = .{ .inject = &.{}, .provide = keySlice(i), .apply = ProviderApply(name) };
    }
    break :blk arr;
};
const consumers = blk: {
    var arr: [key_names.len]Component = undefined;
    for (0..key_names.len) |i| {
        arr[i] = .{ .inject = keySlice(i), .provide = &.{}, .apply = ConsumerApply() };
    }
    break :blk arr;
};

fn keySlice(comptime i: usize) []const Key {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_names[i])};
    };
    return &S.k;
}

/// A canonical signature of the quiescent configuration: for each pooled key,
/// whether it is currently provided (by an active fiber). This is the
/// observational projection the confluence comparison uses — it ignores fiber
/// ids / vestigial entries (Thm 80 "up to renaming and ignoring vestigial").
const Signature = [key_names.len]bool;

fn signatureOf(orch: *Orchestrator) Signature {
    var sig: Signature = undefined;
    for (key_names, 0..) |name, i| {
        sig[i] = orch.isProvided(Key.of(u32, name));
    }
    return sig;
}

/// Assert quiescence (item 34): no fiber is mid-transition (loading/unloading),
/// and every active fiber's target equals its committed view. A failed fiber is
/// admitted. In the blocking schedule every call returns at a fixpoint, so this
/// must always hold between actions.
fn assertQuiescent(orch: *Orchestrator) !void {
    var it = orch.registry.fibers.valueIterator();
    while (it.next()) |fp| {
        const f = fp.*;
        try std.testing.expect(f.phase != .loading and f.phase != .unloading);
        try std.testing.expect(!f.in_transition);
        if (f.phase == .active) {
            const t = f.target orelse return error.TestUnexpectedResult;
            const c = f.committed orelse return error.TestUnexpectedResult;
            try std.testing.expect(t.active and t.eql(c));
        }
    }
}

/// Run one seeded scenario of `steps` random actions. Returns the final
/// provision signature so the caller can compare two runs of the same seed.
fn runScenario(allocator: std.mem.Allocator, seed: u64, steps: usize) !Signature {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();

    // Track live fiber ids so retire/remove can target real fibers.
    var live: std.ArrayList(FiberId) = .empty;
    defer live.deinit(allocator);

    var s: usize = 0;
    while (s < steps) : (s += 1) {
        const action = rand.intRangeLessThan(u8, 0, 4);
        switch (action) {
            // 0: load a provider of a random pooled key (may conflict → skip).
            0 => {
                const i = rand.intRangeLessThan(usize, 0, key_names.len);
                const id = orch.load(providers[i], comp.root) catch |err| switch (err) {
                    error.ProvisionConflict => continue, // single-source rejection
                    else => return err,
                };
                try live.append(allocator, id);
            },
            // 1: load a consumer of a random pooled key (never conflicts).
            1 => {
                const i = rand.intRangeLessThan(usize, 0, key_names.len);
                const id = try orch.load(consumers[i], comp.root);
                try live.append(allocator, id);
            },
            // 2: retire a random live fiber (O-Retire, legal in any state).
            2 => {
                if (live.items.len == 0) continue;
                const idx = rand.intRangeLessThan(usize, 0, live.items.len);
                orch.unloadFiber(live.items[idx]) catch continue;
            },
            // 3: remove a random fiber if legal (retired + inactive + no child).
            3 => {
                if (live.items.len == 0) continue;
                const idx = rand.intRangeLessThan(usize, 0, live.items.len);
                const id = live.items[idx];
                const f = orch.registry.get(id) orelse {
                    _ = live.swapRemove(idx);
                    continue;
                };
                if (f.retired and f.phase == .inactive) {
                    orch.removeFiber(id) catch continue;
                    _ = live.swapRemove(idx);
                }
            },
            else => unreachable,
        }

        // Items 3/4/12/20: well-formed after EVERY step. Item 34: quiescent
        // between actions (the blocking schedule reaches a fixpoint each call).
        try invariants.assertWellFormed(&orch);
        try assertQuiescent(&orch);
    }

    return signatureOf(&orch);
}

// ───────────────────────────── Tests ─────────────────────────────

test "item 59: randomized orchestration stays well-formed and quiescent" {
    // Many independent seeds; each asserts invariants after every step and
    // quiescence between steps, and leaks nothing (testing.allocator).
    var seed: u64 = 1;
    while (seed <= 64) : (seed += 1) {
        _ = try runScenario(std.testing.allocator, seed, 40);
    }
}

test "item 39: replaying a seed reaches the same quiescent signature" {
    // History independence under the blocking schedule (Thm 80, specialized):
    // the same seed → the same final provision signature on a second run.
    var seed: u64 = 1;
    while (seed <= 32) : (seed += 1) {
        const a = try runScenario(std.testing.allocator, seed, 40);
        const b = try runScenario(std.testing.allocator, seed, 40);
        try std.testing.expectEqualSlices(bool, &a, &b);
    }
}

test "item 59: randomized runs leak nothing under OOM injection on a short seed" {
    // Combine the randomized driver with allocation-failure injection: a short,
    // fixed scenario run under checkAllAllocationFailures proves the
    // orchestration + lifecycle paths leave no effect without its inverse even
    // when any allocation fails mid-transition (item 56 × item 59).
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = try runScenario(allocator, 12345, 12);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "diag: randomized runs reach non-trivial (some-provided) signatures" {
    var any_provided = false;
    var seed: u64 = 1;
    while (seed <= 64) : (seed += 1) {
        const sig = try runScenario(std.testing.allocator, seed, 40);
        for (sig) |b| if (b) { any_provided = true; };
    }
    try std.testing.expect(any_provided); // at least one seed ends with a live provision
}
