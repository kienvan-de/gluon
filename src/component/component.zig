//! Components (ℭΓ, Definition 48) and the fiber lifecycle state (ΘΓ, Def 49).
//!
//! Paper correspondence:
//!   - Definition 48 (Component ℭΓ ≔ (d, p, e)):
//!       • d : 𝔇Γ  — coeffect specification (keys required from environment);
//!       • p : 𝔓Γ  — coeffect provision (keys the component may provide);
//!       • e : ℑΓ  — the witnessed effect function (an effect iterator) run on
//!                   activation, together with the inverses that withdraw it.
//!   - Definition 49 (Fiber): an instantiation of a component carrying its own
//!       lifecycle state. Fields: (d, p, e, π, σ, τ, θ):
//!       • π — parent fiber (or root);
//!       • σ — the fiber's own coeffect table (its provisions);
//!       • τ — retirement flag (⊥ fresh, ⊤ once the orchestrator retired it);
//!       • θ — lifecycle state (ΘΓ below).
//!   - Definition 43 / §4.4 (Lifecycle state ΘΓ):
//!       Inactive | Reloading(i, g, ω) | Active(g, ω) | Unloading(g, ω)
//!       plus the Failed(error) state of the §4.4 Failure extension.
//!       In the implementation (Table 2) Reloading = LOADING.
//!
//! This slice defines the data only. The state machine that transitions a fiber
//! between these states (refresh/reload/unload, Alg 5) is a later sub-slice; it
//! needs the registry and scheduler first.

const std = @import("std");
const Context = @import("../context/context.zig").Context;
const spec_mod = @import("../coeffect/spec.zig");
const store_mod = @import("../coeffect/store.zig");
const key_registry = @import("../coeffect/key_registry.zig");

pub const Spec = spec_mod.Spec;
pub const Key = store_mod.Key;
pub const CommutativityWitness = key_registry.CommutativityWitness;

/// A unique fiber name (𝔑 of Definition 49). Atoms: compared only by equality,
/// never inspected. Drawn fresh on instantiation.
pub const FiberId = u64;

/// The root marker (π = root) for fibers the orchestrator inserts directly.
pub const root: ?FiberId = null;

/// The committed/target view ω : d → 𝔑 (Definition 49): maps each declared key
/// to the fiber that provides it. Represented as a parallel slice aligned with
/// the component's `inject` keys; entry i is the provider of inject[i], or null
/// if unresolved. A view of null-everywhere with `active = false` encodes ⊥
/// (the fiber ought not to run).
pub const View = struct {
    /// providers[i] = provider fiber of inject[i], or null if unresolved.
    providers: []?FiberId,
    /// Whether this view represents "should be running" (not ⊥).
    active: bool,

    pub fn deinit(self: View, allocator: std.mem.Allocator) void {
        allocator.free(self.providers);
    }

    /// The ⊥ view: the fiber ought not to run (retired or unsatisfied).
    pub fn bottom() View {
        return .{ .providers = &.{}, .active = false };
    }

    pub fn isBottom(self: View) bool {
        return !self.active;
    }

    /// Structural equality of two views (same active flag and same providers).
    /// Recording providers (not values) is what makes the comparison usable
    /// (Def 53 note): a different provider of an equal value compares unequal.
    pub fn eql(self: View, other: View) bool {
        if (self.active != other.active) return false;
        if (self.providers.len != other.providers.len) return false;
        for (self.providers, other.providers) |a, b| {
            if (a != b) return false;
        }
        return true;
    }

    /// Deep copy (caller owns the result).
    pub fn clone(self: View, allocator: std.mem.Allocator) !View {
        const providers = try allocator.dupe(?FiberId, self.providers);
        return .{ .providers = providers, .active = self.active };
    }
};

/// The lifecycle state ΘΓ (Definition 43 + §4.4 Failed).
pub const Phase = enum { inactive, loading, active, unloading, failed };

/// An effect-function factory: a component's `apply` (component.apply in
/// Table 2). Given the fiber's own context and the component's config, it
/// produces the effect iterator the lifecycle runs. config is type-erased so
/// one component definition can be instantiated with different payloads
/// (§4.4 Configuration).
pub const Apply = *const fn (ctx: *Context, config: ?*anyopaque) anyerror!Context.Iterator;

/// A component ℂΓ = (d, p, e) (Definition 48).
pub const Component = struct {
    /// d — keys required from the environment.
    inject: []const Key,
    /// p — keys this component may provide (disjoint from every other
    ///     component's provision; O-Insert enforces this).
    provide: []const Key,
    /// e — the effect-function factory run on activation.
    apply: Apply,
    /// The commutativity witness (Def 46) the component attaches to the keys it
    /// provides. Defaults to trivial (commutative): a component that provides
    /// only pure values or tagged registries needs no explicit witness. A
    /// component providing an order-sensitive key (e.g. a middleware chain)
    /// declares `.non_commutative`, which the orchestrator rejects unless the
    /// provider opts into ordering. The obligation falls on the PROVIDER
    /// (Theorem 45: distinct keys are independent for free).
    provide_witness: CommutativityWitness = CommutativityWitness.trivial(),

    pub fn spec(self: Component) Spec {
        return Spec.init(self.inject);
    }
};

/// A fiber: a runtime instantiation of a component (Definition 49).
pub const Fiber = struct {
    const Self = @This();

    id: FiberId,
    component: Component,
    /// π — the fiber this one was instantiated under (null = root).
    parent: ?FiberId,
    /// The child context this fiber's effects run in (derived from parent's).
    ctx: *Context,

    /// θ — current lifecycle phase.
    phase: Phase,
    /// τ — retirement flag.
    retired: bool,
    /// ω — the committed view: the resolution the fiber activated against.
    ///     Valid while installed (loading/active/unloading); null when inactive.
    committed: ?View,
    /// The target view the fiber should be running against, recomputed
    ///     reactively (fiber.target in Table 2). Null until first computed.
    target: ?View,
    /// Whether a transition is in flight (fiber.inertia): while set, refresh
    ///     only updates `target` and returns (the inertial discipline, §4.4).
    in_transition: bool,
    /// Error outcome of the §4.4 Failure extension; set when phase = failed.
    failure: ?anyerror,

    /// A fresh fiber starts Inactive, not retired, with no views.
    pub fn init(id: FiberId, component: Component, parent: ?FiberId, ctx: *Context) Self {
        return .{
            .id = id,
            .component = component,
            .parent = parent,
            .ctx = ctx,
            .phase = .inactive,
            .retired = false,
            .committed = null,
            .target = null,
            .in_transition = false,
            .failure = null,
        };
    }

    /// A fiber is installed when its lifecycle carries a committed view, i.e.
    /// it is not Inactive (Definition 44 installed predicate).
    pub fn installed(self: Self) bool {
        return self.phase != .inactive and self.phase != .failed;
    }

    /// Release any views the fiber owns. The ctx is owned by the parent's
    /// accumulator (derive), not freed here.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.committed) |v| v.deinit(allocator);
        if (self.target) |v| v.deinit(allocator);
        self.committed = null;
        self.target = null;
    }
};

// ───────────────────────────── Tests ─────────────────────────────

fn dummyApply(_: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    unreachable;
}

test "Definition 48: a component exposes its spec from inject" {
    const ka = Key.of(u32, "a");
    const comp = Component{
        .inject = &.{ka},
        .provide = &.{},
        .apply = dummyApply,
    };
    try std.testing.expectEqual(@as(usize, 1), comp.spec().inject.len);
}

test "Definition 49: a fresh fiber is inactive, not installed, not retired" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const comp = Component{ .inject = &.{}, .provide = &.{}, .apply = dummyApply };
    var fiber = Fiber.init(1, comp, root, ctx);
    defer fiber.deinit(std.testing.allocator);

    try std.testing.expectEqual(Phase.inactive, fiber.phase);
    try std.testing.expect(!fiber.installed());
    try std.testing.expect(!fiber.retired);
    try std.testing.expectEqual(@as(?View, null), fiber.committed);
}

test "View: ⊥ vs resolved equality (Def 53 provider-recording)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(View.bottom().isBottom());

    var p1 = [_]?FiberId{ 10, 20 };
    var p2 = [_]?FiberId{ 10, 20 };
    var p3 = [_]?FiberId{ 10, 99 };
    const v1 = View{ .providers = &p1, .active = true };
    const v2 = View{ .providers = &p2, .active = true };
    const v3 = View{ .providers = &p3, .active = true };

    try std.testing.expect(v1.eql(v2)); // same providers
    try std.testing.expect(!v1.eql(v3)); // different provider for key 1
    try std.testing.expect(!v1.eql(View.bottom())); // active vs ⊥

    const cloned = try v1.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(v1.eql(cloned));
}

test "installed predicate tracks phase" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const comp = Component{ .inject = &.{}, .provide = &.{}, .apply = dummyApply };
    var fiber = Fiber.init(1, comp, root, ctx);
    defer fiber.deinit(std.testing.allocator);

    try std.testing.expect(!fiber.installed()); // inactive
    fiber.phase = .loading;
    try std.testing.expect(fiber.installed());
    fiber.phase = .active;
    try std.testing.expect(fiber.installed());
    fiber.phase = .unloading;
    try std.testing.expect(fiber.installed());
    fiber.phase = .failed;
    try std.testing.expect(!fiber.installed());
}
