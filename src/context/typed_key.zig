//! Comptime-typed coeffect keys (roadmap #5) — ergonomic accessors that carry
//! their value type, so call sites need not restate it.
//!
//! Paper correspondence (ergonomics only — no new semantics):
//!   - Definition 19 (Σ : (k:K) ⇀ Vₖ) is a dependent partial function: each
//!     key already *has* a value type. The runtime store erases it to a TypeId
//!     (plan C3) and the current `ctx.get(V, key)` / `ctx.set(V, key, v)` make
//!     the caller re-state V, redundant with the type already baked into the
//!     key via `Key.of(V, name)`.
//!   - A `TypedKey(V, name)` carries V at comptime, so `ctx.getT(key)` /
//!     `ctx.setT(key, v)` infer V from the key. This is the closest Zig gets to
//!     Cordis's transparent `ctx.service` access: typed, but still explicit
//!     (Zig has no Proxy / declaration merging — see roadmap §4 Tier 4 #8).
//!
//! This introduces NO new store behavior: a TypedKey lowers to the same
//! `store.Key` and the typed accessors call the exact same store operations.
//! It is a thin, zero-overhead comptime wrapper.

const std = @import("std");
const store_mod = @import("../coeffect/store.zig");

pub const Key = store_mod.Key;

/// A coeffect key that carries its value type `V` at comptime. Construct once
/// (typically as a module-level `const`), then use the typed `ctx.*T` accessors
/// which read `V` straight off the key.
///
/// `TypedKey(V, name)` is a distinct type per (V, name); `.key` lowers it to
/// the runtime `store.Key` the store and the untyped accessors expect, so the
/// two styles interoperate freely.
pub fn TypedKey(comptime V: type, comptime name: []const u8) type {
    return struct {
        const Self = @This();

        /// The value type this key binds (Vₖ of Definition 19).
        pub const Value = V;
        /// The logical key name.
        pub const key_name = name;
        /// The lowered runtime key (same identity as `Key.of(V, name)`).
        pub const key: Key = Key.of(V, name);

        /// Allow a TypedKey instance to be used where a runtime Key is wanted.
        pub inline fn lower(_: Self) Key {
            return key;
        }
    };
}

/// Whether `T` is a TypedKey (a struct exposing `Value`, `key_name`, `key`).
/// Used by the context accessors to accept a TypedKey *type* ergonomically.
pub fn isTypedKey(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "Value") and
        @hasDecl(T, "key_name") and
        @hasDecl(T, "key");
}

// ───────────────────────────── Tests ─────────────────────────────

test "TypedKey carries its value type and lowers to the matching runtime Key" {
    const DbPort = TypedKey(u32, "db.port");
    try std.testing.expectEqual(u32, DbPort.Value);
    try std.testing.expectEqualStrings("db.port", DbPort.key_name);

    // Lowers to exactly Key.of(u32, "db.port") — same name and TypeId.
    const expected = Key.of(u32, "db.port");
    try std.testing.expectEqualStrings(expected.name, DbPort.key.name);
    try std.testing.expectEqual(expected.value_type, DbPort.key.value_type);
}

test "distinct (V, name) pairs are distinct TypedKey types" {
    const A = TypedKey(u32, "x");
    const B = TypedKey(u64, "x"); // same name, different value type
    const C = TypedKey(u32, "y"); // same value type, different name
    try std.testing.expect(A != B);
    try std.testing.expect(A != C);
    // Lowered keys share name with C-vs-A? names differ; A vs B share a name
    // but differ in TypeId — the store's C3 boundary check distinguishes them.
    try std.testing.expect(A.key.value_type != B.key.value_type);
    try std.testing.expect(!std.mem.eql(u8, A.key.name, C.key.name));
}

test "isTypedKey recognizes TypedKey types and rejects others" {
    try std.testing.expect(isTypedKey(TypedKey(u32, "k")));
    try std.testing.expect(!isTypedKey(u32));
    try std.testing.expect(!isTypedKey(Key));
}
