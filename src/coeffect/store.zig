//! The coeffect store Σ with isolation (Definitions 19, 24) — type-erased (C3).
//!
//! Paper correspondence:
//!   - Definition 19 (Coeffect Context Σ): a dependent partial function
//!       σ : (k:K) ⇀ Vₖ   assigning each key a value of its own type.
//!   - Definition 20 (get/set): get(k) reads σ(k); set(k,v) extends σ and
//!       returns an inverse that restricts it (σ ∖ k). set has type 𝔈Σ, so a
//!       provision is an ordinary tracked effect (handled in a later slice).
//!   - Definition 24/25 (Isolation Σiso = (ρ, σ)): a realm table ρ : K ⇀ R
//!       redirects a key to an independent binding; get/set resolve
//!       k → ρ(k) → σ(ρ(k)). A key outside dom(ρ) resolves to its own realm.
//!
//! This slice provides the raw store operations. Wrapping set as a revertible
//! effect (𝔈Σ) and reactive notification come in the coeffect-effect slice.
//!
//! Zig note (plan C3): values are erased to *anyopaque + TypeId. get() asserts
//! the requested type matches what was stored, recovering Def 19's dependent
//! typing at the boundary. Keys are identified by interned string names here;
//! the comptime key registry (Phase 8) will carry 𝒜ₖ and the commutativity
//! witness on top of these.

const std = @import("std");
const type_id = @import("../context/type_id.zig");

pub const TypeId = type_id.TypeId;

/// A coeffect key: a logical name plus the TypeId of its value (Vₖ).
/// Two keys are equal iff names match; the type is checked on access.
pub const Key = struct {
    name: []const u8,
    value_type: TypeId,

    pub fn of(comptime V: type, name: []const u8) Key {
        return .{ .name = name, .value_type = type_id.typeId(V) };
    }
};

/// A realm identifier (R of Definition 24). The default realm of a key is the
/// key's own name, so unisolated keys each resolve to a distinct realm.
pub const Realm = []const u8;

const StoredValue = struct {
    ptr: *anyopaque,
    value_type: TypeId,
    /// Releases the heap box holding the value.
    deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const StoreError = error{
    /// set(k,v) requires k ∉ dom(σ) (Definition 20 precondition).
    AlreadyProvided,
    /// get/restrict require the realm ∈ dom(σ).
    NotProvided,
    /// get(V, k): V did not match the stored value's type (C3 boundary check).
    TypeMismatch,
};

/// The coeffect store Σiso = (ρ, σ) (Definition 24).
pub const Store = struct {
    allocator: std.mem.Allocator,
    /// σ : realm ⇀ typed value.
    values: std.StringHashMapUnmanaged(StoredValue),
    /// ρ : key name ⇀ realm. Absent key ⇒ realm = key name (own realm).
    realms: std.StringHashMapUnmanaged(Realm),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .values = .empty,
            .realms = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.values.valueIterator();
        while (it.next()) |sv| sv.deinit(sv.ptr, self.allocator);
        self.values.deinit(self.allocator);
        self.realms.deinit(self.allocator);
    }

    /// Resolve a key to its realm: ρ(k), defaulting to the key's own name.
    pub fn resolveRealm(self: *const Store, key: Key) Realm {
        return self.realms.get(key.name) orelse key.name;
    }

    /// Definition 25 (isolate): redirect `key` to `realm`, so it resolves to an
    /// independent binding. Derived realization (Def 23): adjusts ρ only, with
    /// no effect to track on σ. Reassigns if already isolated.
    pub fn isolate(self: *Store, key: Key, realm: Realm) !void {
        try self.realms.put(self.allocator, key.name, realm);
    }

    /// Definition 20 (set): extend σ at ρ(k) with `value`. Precondition
    /// ρ(k) ∉ dom(σ). The inverse (σ ∖ ρ(k)) is realized by `restrict`.
    pub fn set(self: *Store, comptime V: type, key: Key, value: V) !void {
        std.debug.assert(key.value_type == type_id.typeId(V));
        const realm = self.resolveRealm(key);
        if (self.values.contains(realm)) return StoreError.AlreadyProvided;

        const box = try self.allocator.create(V);
        box.* = value;
        const Boxed = struct {
            fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                allocator.destroy(@as(*V, @ptrCast(@alignCast(ptr))));
            }
        };
        try self.values.put(self.allocator, realm, .{
            .ptr = box,
            .value_type = key.value_type,
            .deinit = Boxed.deinit,
        });
    }

    /// Definition 20 (get): read σ(ρ(k)). Fails if absent or if the requested
    /// type V disagrees with the stored type (the C3 boundary check).
    pub fn get(self: *const Store, comptime V: type, key: Key) !V {
        const realm = self.resolveRealm(key);
        const sv = self.values.get(realm) orelse return StoreError.NotProvided;
        if (sv.value_type != type_id.typeId(V)) return StoreError.TypeMismatch;
        return @as(*V, @ptrCast(@alignCast(sv.ptr))).*;
    }

    /// The inverse of set: remove the binding at ρ(k) (σ ∖ ρ(k)).
    pub fn restrict(self: *Store, key: Key) !void {
        const realm = self.resolveRealm(key);
        const entry = self.values.fetchRemove(realm) orelse return StoreError.NotProvided;
        entry.value.deinit(entry.value.ptr, self.allocator);
    }

    /// σ ⊧ {k}: whether the key currently resolves to a bound value.
    pub fn has(self: *const Store, key: Key) bool {
        return self.values.contains(self.resolveRealm(key));
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const PortCfg = struct { port: u16 };

test "Definition 20: set then get round-trips a typed value" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const k = Key.of(PortCfg, "server.config");
    try store.set(PortCfg, k, .{ .port = 8080 });
    try std.testing.expect(store.has(k));

    const got = try store.get(PortCfg, k);
    try std.testing.expectEqual(@as(u16, 8080), got.port);
}

test "Definition 20 preconditions: double-set and absent-get fail" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const k = Key.of(u32, "counter");
    try std.testing.expectError(StoreError.NotProvided, store.get(u32, k));

    try store.set(u32, k, 1);
    try std.testing.expectError(StoreError.AlreadyProvided, store.set(u32, k, 2));
}

test "C3 boundary: get with the wrong type is rejected" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    // Two keys with the same NAME but different value types resolve to the
    // same realm; the stored type is u32, so a u64 read must fail.
    const ku32 = Key.of(u32, "x");
    const ku64 = Key.of(u64, "x");
    try store.set(u32, ku32, 7);
    try std.testing.expectError(StoreError.TypeMismatch, store.get(u64, ku64));
}

test "set/restrict are inverse (Definition 20 inverse σ ∖ k)" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const k = Key.of(u32, "k");
    try store.set(u32, k, 42);
    try std.testing.expect(store.has(k));
    try store.restrict(k);
    try std.testing.expect(!store.has(k));
    // After restrict, set is allowed again (precondition restored).
    try store.set(u32, k, 43);
    try std.testing.expectEqual(@as(u32, 43), try store.get(u32, k));
}

test "Definition 24/25: isolation redirects a key to an independent binding" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const k = Key.of(u32, "db");
    // Default realm = key name.
    try store.set(u32, k, 100);
    try std.testing.expectEqual(@as(u32, 100), try store.get(u32, k));

    // Isolate k into realm "tenant-A": now it resolves to a fresh (absent)
    // binding, independent of the default-realm value.
    try store.isolate(k, "tenant-A");
    try std.testing.expect(!store.has(k));
    try store.set(u32, k, 200);
    try std.testing.expectEqual(@as(u32, 200), try store.get(u32, k));

    // Re-point to the original realm: the first value is still there.
    try store.isolate(k, "db");
    try std.testing.expectEqual(@as(u32, 100), try store.get(u32, k));
}
