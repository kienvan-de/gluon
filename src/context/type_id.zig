//! Comptime-stable type identity for the type-erased coeffect store (plan C3).
//!
//! The coeffect store σ : (k:K) ⇀ Vₖ (Definition 19) is a dependent partial
//! function: each key carries its own value type. Zig cannot store `anytype`,
//! so values are erased to `*anyopaque` and recovered via a TypeId checked at
//! `get`. This recovers the static type-safety Def 19's dependent 𝒱 provides,
//! enforced at the boundary rather than by Zig's type system directly.

const std = @import("std");

/// An opaque, comptime-stable identifier for a type. Equality of TypeIds
/// implies the same type. Implemented as the address of a per-type static,
/// which the compiler guarantees unique per monomorphization.
pub const TypeId = *const anyopaque;

/// Obtain the TypeId of `T`. Stable within a single compilation.
pub fn typeId(comptime T: type) TypeId {
    const Holder = struct {
        // Reference T so each type gets its own monomorphization (and thus
        // its own `marker` address). The field is never read at runtime.
        comptime {
            _ = T;
        }
        var marker: u8 = 0;
    };
    return &Holder.marker;
}

test "typeId is stable and distinguishes types" {
    try std.testing.expectEqual(typeId(u32), typeId(u32));
    try std.testing.expectEqual(typeId([]const u8), typeId([]const u8));
    try std.testing.expect(typeId(u32) != typeId(u64));
    try std.testing.expect(typeId(u32) != typeId(i32));

    const S = struct { x: i64 };
    const T = struct { x: i64 };
    try std.testing.expectEqual(typeId(S), typeId(S));
    try std.testing.expect(typeId(S) != typeId(T)); // distinct declarations
}
