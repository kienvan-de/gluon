//! Coeffect specification 𝔇Γ (Definition 21) with satisfaction and reactive
//! classification (Definition 22).
//!
//! Paper correspondence:
//!   - Definition 21 (Coeffect Specification 𝔇Σ ≔ Set(K)): the set of keys a
//!     component declares as required from the environment.
//!   - Eq. 22 (Satisfaction predicate):  σ ⊧ d ≔ ∀k ∈ d. k ∈ dom(σ).
//!     Decidable since dom(σ) is finite.
//!   - Definition 22 (Reactive classification): a transition σ → σ′ is
//!       activating    if σ ⊭ d ∧ σ′ ⊧ d
//!       deactivating  if σ ⊧ d ∧ σ′ ⊭ d
//!       neutral       otherwise
//!     An activating transition triggers the component's effects; a
//!     deactivating one triggers recovery. This classification is the
//!     algebraic basis of reactivity (§3.2.2): every coeffect change is
//!     observed at an effect boundary.
//!
//! This slice is pure (no fibers): it computes satisfaction against a Store and
//! classifies transitions. The propagation of a change to dependents (notify,
//! Alg 3) and the activation/deactivation it drives belong to the fiber
//! lifecycle (Phase 4), since they iterate the registry.

const std = @import("std");
const store_mod = @import("store.zig");

pub const Key = store_mod.Key;
pub const Store = store_mod.Store;

/// Classification of a context transition against a specification (Def 22).
pub const Classification = enum {
    activating,
    deactivating,
    neutral,
};

/// A coeffect specification 𝔇Γ: the keys a component requires (Definition 21).
/// Backed by a borrowed slice of keys; the owner keeps them alive.
pub const Spec = struct {
    inject: []const Key,

    pub fn init(inject: []const Key) Spec {
        return .{ .inject = inject };
    }

    /// The empty specification (declares nothing) is satisfied by any state.
    pub fn empty() Spec {
        return .{ .inject = &.{} };
    }

    /// Eq. 22 — satisfaction: every declared key is present in the store.
    /// `provided` tells us how to decide k ∈ dom(σ); we take a Store directly,
    /// but a predicate indirection lets the fiber layer resolve "present" as
    /// "provided by an ACTIVE fiber" (Def 53) without changing this code.
    pub fn satisfiedBy(self: Spec, store: *const Store) bool {
        for (self.inject) |k| {
            if (!store.has(k)) return false;
        }
        return true;
    }

    /// Satisfaction against an arbitrary presence predicate (used by the fiber
    /// layer where "present" means "an ACTIVE provider installed it").
    pub fn satisfiedByFn(
        self: Spec,
        ctx: anytype,
        present: *const fn (@TypeOf(ctx), Key) bool,
    ) bool {
        for (self.inject) |k| {
            if (!present(ctx, k)) return false;
        }
        return true;
    }

    /// Definition 22 — classify a transition between two satisfaction states.
    /// Takes the before/after satisfaction booleans so it is independent of how
    /// satisfaction was decided.
    pub fn classify(sat_before: bool, sat_after: bool) Classification {
        if (!sat_before and sat_after) return .activating;
        if (sat_before and !sat_after) return .deactivating;
        return .neutral;
    }

    /// Classify a transition given the store states before and after, by
    /// evaluating satisfaction at each.
    pub fn classifyTransition(self: Spec, before: *const Store, after: *const Store) Classification {
        return classify(self.satisfiedBy(before), self.satisfiedBy(after));
    }
};

// ───────────────────────────── Tests ─────────────────────────────

test "Eq. 22: empty spec is satisfied by any state" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(Spec.empty().satisfiedBy(&store));
}

test "Eq. 22: satisfaction requires every declared key present" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const ka = Key.of(u32, "a");
    const kb = Key.of(u32, "b");
    const spec = Spec.init(&.{ ka, kb });

    try std.testing.expect(!spec.satisfiedBy(&store)); // neither present
    try store.set(u32, ka, 1);
    try std.testing.expect(!spec.satisfiedBy(&store)); // still missing b
    try store.set(u32, kb, 2);
    try std.testing.expect(spec.satisfiedBy(&store)); // both present
}

test "Definition 22: classify covers activating/deactivating/neutral" {
    // Pure truth-table over (before, after).
    try std.testing.expectEqual(Classification.neutral, Spec.classify(false, false));
    try std.testing.expectEqual(Classification.activating, Spec.classify(false, true));
    try std.testing.expectEqual(Classification.deactivating, Spec.classify(true, false));
    try std.testing.expectEqual(Classification.neutral, Spec.classify(true, true));
}

test "Definition 22: classifyTransition detects an activating change" {
    const allocator = std.testing.allocator;
    const k = Key.of(u32, "dep");
    const spec = Spec.init(&.{k});

    var before = Store.init(allocator);
    defer before.deinit();
    var after = Store.init(allocator);
    defer after.deinit();
    try after.set(u32, k, 1); // dependency appears

    try std.testing.expectEqual(Classification.activating, spec.classifyTransition(&before, &after));
    try std.testing.expectEqual(Classification.deactivating, spec.classifyTransition(&after, &before));
    try std.testing.expectEqual(Classification.neutral, spec.classifyTransition(&before, &before));
}

test "satisfiedByFn resolves presence through a custom predicate" {
    const k1 = Key.of(u32, "x");
    const k2 = Key.of(u32, "y");
    const spec = Spec.init(&.{ k1, k2 });

    const Ctx = struct {
        // pretend only "x" is provided by an active fiber
        fn present(_: void, key: Key) bool {
            return std.mem.eql(u8, key.name, "x");
        }
    };
    try std.testing.expect(!spec.satisfiedByFn({}, Ctx.present));

    const All = struct {
        fn present(_: void, _: Key) bool {
            return true;
        }
    };
    try std.testing.expect(spec.satisfiedByFn({}, All.present));
}
