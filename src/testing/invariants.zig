//! Well-formedness invariant checker (verification-assessment items 3/4/12/20).
//!
//! A state-level auditor over an `Orchestrator`: after any sequence of
//! orchestration + lifecycle steps, `assertWellFormed` verifies the structural
//! guarantees the paper proves hold at EVERY step (Thm 64, Def 63, Eq 46,
//! Thm 70). It is a testing helper — not part of the kernel — so it may read
//! private registry fields.
//!
//! Paper correspondence (checklist tags):
//!   - item 4 / Def 63, Thm 64: (1) every parent is in the registry or root;
//!     (2) provisions of distinct fibers are disjoint; (3) an installed fiber's
//!     committed view is total on its declared keys and valued in the registry;
//!     (4) if an installed fiber's view names m, then m is installed.
//!   - item 12 / Eq 46: each key has at most one provider; only ACTIVE fibers
//!     publish (isProvided ⇒ provider active).
//!   - item 20 / Thm 70: a committed view only names fibers that are installed
//!     (covered by (4)); a provider named by an installed consumer is itself
//!     installed (so it cannot have been removed underneath the consumer).
//!
//! Confinement (Def 55-56, item 30) is deliberately NOT checked: it is a
//! discipline in this implementation, not a runtime-enforced invariant.

const std = @import("std");
const lifecycle = @import("../component/lifecycle.zig");
const comp = @import("../component/component.zig");

const Orchestrator = lifecycle.Orchestrator;
const Fiber = comp.Fiber;

pub const InvariantError = error{
    /// (4.1) A fiber's parent is neither root nor present in the registry.
    DanglingParent,
    /// (4.2) Two distinct fibers reserve the same provided key.
    ProvisionOverlap,
    /// (4.3) An installed fiber's committed view is missing or not total on
    /// its declared keys.
    ViewNotTotal,
    /// (4.3) A committed view names a provider that is absent from the registry.
    ViewNamesAbsentProvider,
    /// (4.4 / Thm 70) An installed fiber's committed view names a fiber that is
    /// not installed — a consumer committed to a departed/uninstalled provider.
    ViewNamesUninstalledProvider,
    /// (Eq 46) `isProvided` reports a key whose provider fiber is not ACTIVE.
    ProvidedByNonActive,
    /// A committed view's provider actually provides a DIFFERENT key than the
    /// consumer declared at that slot (resolution/provider-table disagreement).
    ProviderDoesNotProvideKey,
};

/// Assert every structural invariant on the orchestrator's current state.
/// Returns the first violation found (so a failing randomized run points at a
/// specific broken guarantee).
pub fn assertWellFormed(orch: *Orchestrator) InvariantError!void {
    const reg = &orch.registry;

    var it = reg.fibers.valueIterator();
    while (it.next()) |fp| {
        const f = fp.*;

        // (4.1) parent in registry or root.
        if (f.parent) |pid| {
            if (reg.fibers.get(pid) == null) return InvariantError.DanglingParent;
        }

        // (4.3)+(4.4) committed view obligations, only for installed fibers.
        if (f.installed()) {
            const view = f.committed orelse return InvariantError.ViewNotTotal;
            // total on declared keys: one provider slot per injected key.
            if (view.providers.len != f.component.inject.len) {
                return InvariantError.ViewNotTotal;
            }
            for (view.providers, f.component.inject) |maybe_pid, decl_key| {
                const pid = maybe_pid orelse return InvariantError.ViewNotTotal;
                const provider = reg.fibers.get(pid) orelse
                    return InvariantError.ViewNamesAbsentProvider;
                // (4.4 / Thm 70) the named provider is itself installed.
                if (!provider.installed()) {
                    return InvariantError.ViewNamesUninstalledProvider;
                }
                // the named provider actually provides the declared key.
                if (!provides(provider, decl_key.name)) {
                    return InvariantError.ProviderDoesNotProvideKey;
                }
            }
        }
    }

    // (4.2) provisions of distinct fibers are disjoint. Allocation-free O(n²)
    // pairwise scan so this checker stays usable under OOM-injection tests (it
    // must never fail for its OWN allocation). For each provided key, verify no
    // OTHER fiber provides the same name, and that an ACTIVE-provided key
    // (Eq 46) resolves to an active provider.
    var it2 = reg.fibers.valueIterator();
    while (it2.next()) |fp| {
        const f = fp.*;
        for (f.component.provide) |k| {
            // disjointness: no other fiber claims k.name.
            var it3 = reg.fibers.valueIterator();
            while (it3.next()) |gp| {
                const g = gp.*;
                if (g.id == f.id) continue;
                for (g.component.provide) |k2| {
                    if (std.mem.eql(u8, k.name, k2.name)) {
                        return InvariantError.ProvisionOverlap;
                    }
                }
            }
            // (Eq 46) if the key is published, its provider is ACTIVE.
            const key = comp.Key{ .name = k.name, .value_type = k.value_type };
            if (reg.isProvided(key)) {
                const pid = reg.providerOf(key) orelse return InvariantError.ProvidedByNonActive;
                const provider = reg.fibers.get(pid) orelse return InvariantError.ProvidedByNonActive;
                if (provider.phase != .active) return InvariantError.ProvidedByNonActive;
            }
        }
    }
}

fn provides(fiber: *Fiber, key_name: []const u8) bool {
    for (fiber.component.provide) |k| {
        if (std.mem.eql(u8, k.name, key_name)) return true;
    }
    return false;
}

// ───────────────────────────── Tests ─────────────────────────────

const fixtures = @import("fixtures.zig");
const provider_c = fixtures.provider;
const consumer_c = fixtures.consumer;
const Key = comp.Key;

test "assertWellFormed holds for a satisfied provider+consumer" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    _ = try orch.load(provider_c("db", 1), comp.root);
    _ = try orch.load(consumer_c("db"), comp.root);
    try assertWellFormed(&orch);
}

test "assertWellFormed holds for an inactive (unsatisfied) consumer" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    _ = try orch.load(consumer_c("db"), comp.root); // dep absent → inactive
    try assertWellFormed(&orch);
}

test "assertWellFormed holds after a provider is retired and consumer deactivates" {
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const pid = try orch.load(provider_c("db", 1), comp.root);
    _ = try orch.load(consumer_c("db"), comp.root);
    try orch.unloadFiber(pid);
    try assertWellFormed(&orch);
}

test "assertWellFormed detects an injected ViewNamesUninstalledProvider" {
    // Deliberately corrupt the state to prove the checker catches a violation:
    // activate a consumer committed to a provider, then force the provider
    // Inactive WITHOUT clearing the consumer's committed view. The real
    // lifecycle never produces this; the checker must flag it.
    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const pid = try orch.load(provider_c("db", 1), comp.root);
    _ = try orch.load(consumer_c("db"), comp.root);
    try assertWellFormed(&orch); // clean first

    orch.registry.get(pid).?.phase = .inactive; // corrupt: provider not installed
    try std.testing.expectError(
        InvariantError.ViewNamesUninstalledProvider,
        assertWellFormed(&orch),
    );
    // restore so teardown is clean.
    orch.registry.get(pid).?.phase = .active;
}
