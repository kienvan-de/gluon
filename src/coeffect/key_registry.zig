//! Coeffect keys with operations 𝒜ₖ and commutativity witnesses (§3.3.1,
//! §3.4.2) — the comptime key registry (plan Phase 8 / C3).
//!
//! Paper correspondence:
//!   - Definition 29 (Coeffect at a key = (𝒱ₖ, 𝒜ₖ)): a key carries a value type
//!     and a set of operations the value provides to a holder. Each operation
//!     is an effect function on 𝒱ₖ (forward map + witnessed inverse) plus an
//!     outcome. The operations induce the equivalence ≃ₖ (Def 31) up to which
//!     values at k are compared.
//!   - Definition 44 (Independence of operations): two operations are
//!     independent when their lifts commute and neither disturbs the other's
//!     outcome. A key is commutative when any two of its operations are
//!     independent.
//!   - Definition 46 (Witnessed coeffect): a coeffect carries, as a third
//!     constituent, a proof that the key is commutative. The obligation falls
//!     on the component PROVIDING the key (Thm 45: operations at distinct keys
//!     are independent, so only same-key pairs need checking).
//!   - Theorem 47: independence of two context-mediated iterators reduces to
//!     commutativity at shared keys + provision disjointness — the latter the
//!     registry already enforces (O-Insert), the former this witness supplies.
//!
//! What the runtime checks (§5.1.1): the witness is NOT verified at runtime —
//! "that the operations published at a key commute is an obligation on the
//! component providing it, discharged by the representation choice of §3.4.2".
//! We therefore record a declared CommutativityWitness as comptime metadata on
//! a key, and provide a comptime assertion so a provider states the proof
//! obligation explicitly and the kind of evidence it rests on (Def 31 turns
//! each division into a design choice).

const std = @import("std");
const type_id = @import("../context/type_id.zig");
const store_mod = @import("store.zig");

pub const TypeId = type_id.TypeId;
pub const Key = store_mod.Key;

/// The evidence a key's commutativity rests on (Def 31 / §3.4.2 examples).
/// Recording the KIND makes the proof obligation legible and auditable, which
/// is the "design procedure" §3.4.2 turns Def 31 into.
pub const CommutativityKind = enum {
    /// No operations beyond get/set, or operations trivially commute (e.g. a
    /// pure value read). Independence is immediate.
    trivial,
    /// A table whose entries each carry a unique tag/identifier, so two
    /// registrations name distinct entries and commute (the route/listener
    /// case; CRDT-style unique tags, §3.4.2).
    tagged_registry,
    /// Commutativity holds up to ≃ₖ because the interface publishes fewer
    /// outcomes than the internal state distinguishes (the allocator-with-
    /// hidden-handles case; scalable commutativity rule, §3.4.2).
    observational,
    /// The key's operations do NOT commute (e.g. an ordered middleware chain).
    /// Such a key imposes order from outside the effects (§3.4.2); the system
    /// must sequence its providers/consumers rather than rely on independence.
    non_commutative,
};

/// A witness (Def 46) that a key's operations are pairwise independent.
/// Declared by the component providing the key. `kind` records the evidence;
/// `justification` is a human-readable note for auditors.
pub const CommutativityWitness = struct {
    kind: CommutativityKind,
    justification: []const u8,

    /// A key with no operations (pure value) is trivially commutative.
    pub fn trivial() CommutativityWitness {
        return .{ .kind = .trivial, .justification = "pure value; get/set only" };
    }

    /// Whether this witness certifies commutativity (Def 44). A
    /// non_commutative key is explicitly NOT independent of itself.
    pub fn isCommutative(self: CommutativityWitness) bool {
        return self.kind != .non_commutative;
    }
};

/// A coeffect-at-a-key descriptor (Definition 29): the value type, the key's
/// operations are represented by the witness over them, and the commutativity
/// witness (Def 46). Constructed at comptime so the proof obligation is stated
/// where the key is declared.
pub fn Coeffect(comptime V: type) type {
    return struct {
        const Self = @This();

        key: Key,
        witness: CommutativityWitness,

        /// Declare a coeffect at `name` with value type V and a commutativity
        /// witness. Theorem 45 means only same-key operation pairs need the
        /// witness; distinct keys are independent for free.
        pub fn declare(name: []const u8, witness: CommutativityWitness) Self {
            return .{ .key = Key.of(V, name), .witness = witness };
        }

        /// A pure-value coeffect (no operations beyond get/set): trivially
        /// commutative (Theorem 45 degenerate case).
        pub fn pure(name: []const u8) Self {
            return .{ .key = Key.of(V, name), .witness = CommutativityWitness.trivial() };
        }

        /// Comptime proof-obligation gate: a provider that installs this key
        /// must certify commutativity. Calling this in a provider's comptime
        /// context makes a non-commutative key a compile error unless the
        /// provider opts into sequencing (acknowledging the obligation).
        pub fn assertCommutative(comptime self: Self) void {
            if (!self.witness.isCommutative()) {
                @compileError("coeffect key '" ++ self.key.name ++
                    "' is non-commutative; its provider must impose ordering " ++
                    "(see §3.4.2) rather than rely on effect independence");
            }
        }
    };
}

/// Theorem 47 precondition check at the component level: two components'
/// effects are independent when their provisions are disjoint from each other's
/// interface AND every shared operation key is commutative. The registry's
/// O-Insert already enforces provision disjointness (single-source); this
/// checks the shared-key commutativity half given the two key sets' witnesses.
pub fn sharedKeysCommutative(
    a_keys: []const CommutativityWitness,
    b_keys: []const CommutativityWitness,
) bool {
    // In this model each list is the witnesses of one component's keys; a key
    // shared by both must be commutative. We conservatively require every
    // witness on both sides to be commutative (a shared non-commutative key
    // would fail on whichever side declares it).
    for (a_keys) |w| if (!w.isCommutative()) return false;
    for (b_keys) |w| if (!w.isCommutative()) return false;
    return true;
}

// ───────────────────────────── Tests ─────────────────────────────

test "Definition 29: declare a coeffect with value type and witness" {
    const PortCfg = struct { port: u16 };
    const cfg = Coeffect(PortCfg).pure("server.config");
    try std.testing.expectEqualStrings("server.config", cfg.key.name);
    try std.testing.expect(cfg.witness.isCommutative());
    try std.testing.expectEqual(CommutativityKind.trivial, cfg.witness.kind);
}

test "Definition 46: a tagged-registry key is commutative" {
    const RouteTable = struct {};
    const routes = Coeffect(RouteTable).declare("router.routes", .{
        .kind = .tagged_registry,
        .justification = "each route carries a unique id; registrations name distinct entries",
    });
    try std.testing.expect(routes.witness.isCommutative());
}

test "Definition 44: a non-commutative key is flagged" {
    const Chain = struct {};
    const mw = Coeffect(Chain).declare("http.middleware", .{
        .kind = .non_commutative,
        .justification = "ordered chain; middleware position changes the request seen",
    });
    try std.testing.expect(!mw.witness.isCommutative());
}

test "Theorem 45: distinct pure keys are commutative for free" {
    const a = Coeffect(u32).pure("a");
    const b = Coeffect(u64).pure("b");
    try std.testing.expect(sharedKeysCommutative(
        &.{a.witness},
        &.{b.witness},
    ));
}

test "Theorem 47: a non-commutative key breaks shared-key commutativity" {
    const good = CommutativityWitness.trivial();
    const bad = CommutativityWitness{ .kind = .non_commutative, .justification = "ordered" };
    try std.testing.expect(sharedKeysCommutative(&.{good}, &.{good}));
    try std.testing.expect(!sharedKeysCommutative(&.{good}, &.{bad}));
}

test "comptime assertCommutative gate passes for commutative keys" {
    // This compiles only because the key is commutative; a non_commutative
    // key here would be a compile error (verified by construction).
    const cfg = comptime Coeffect(u32).pure("x");
    comptime cfg.assertCommutative();
    try std.testing.expect(true);
}
