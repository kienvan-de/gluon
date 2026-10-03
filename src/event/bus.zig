//! Event bus — listeners as revertible effects over a tagged registry
//! (§3.4.2, Definition 8, Definition 29, Definition 46/Theorem 47).
//!
//! This is the paper's own motivating construction, assembled from pieces the
//! library already provides rather than imported from Cordis:
//!
//!   - §3.4.2 (tagged registry): the listener table is "a key whose value is a
//!     table of entries", where each registration carries a UNIQUE tag, so two
//!     concurrent `on` registrations name distinct entries and COMMUTE. The
//!     bus therefore certifies a `tagged_registry` commutativity witness
//!     (Definition 46): registering listeners is a commutative coeffect
//!     operation (𝒜ₖ, Definition 29), and by Theorem 47 two components that
//!     only register listeners are independent.
//!
//!   - Definition 8 (revertible effect): `on(event, handler)` is an effect
//!     whose inverse is the disposer. Registering returns an `Inverse` that
//!     removes exactly that listener (identified by its unique tag). When
//!     tracked onto a context's accumulator (φ), unloading the component
//!     withdraws its listeners automatically — the LIFO recover of Theorem 7
//!     and Theorem 16. A listener leaks iff an effect leaks; it does not.
//!
//!   - `emit` is a read over the current registry: it dispatches the payload to
//!     every live listener. It performs no provision and tracks no inverse, so
//!     it is neutral with respect to the registry invariant.
//!
//! Type erasure (plan C1/C3): handlers are closure-free. A listener is a
//! `{ctx: *anyopaque, call}` pair plus a type-erased payload (`*anyopaque` +
//! `TypeId`), checked on emit exactly as the store checks `get`/`set`.
//!
//! Ownership invariant: the EventBus must OUTLIVE every context that registers
//! listeners on it. A listener's disposer (the Definition 8 inverse) calls back
//! into the bus (`off`) during the subscriber's recover/unload, so the bus must
//! still be alive then. In the fiber model this holds structurally: a provider
//! installs the bus and unloads only AFTER its dependents (Theorem 70, relied-
//! upon ordering + Definition 52 cascade), so every subscriber's listeners are
//! withdrawn before the bus itself is torn down. Hosts wiring buses manually
//! must preserve the same order (provider deinit last).

const std = @import("std");
const type_id = @import("../context/type_id.zig");
const key_registry = @import("../coeffect/key_registry.zig");

pub const TypeId = type_id.TypeId;
pub const typeId = type_id.typeId;
pub const CommutativityWitness = key_registry.CommutativityWitness;
pub const CommutativityKind = key_registry.CommutativityKind;

/// The commutativity witness every event bus carries (Definition 46): listener
/// registration is a tagged-registry operation (§3.4.2), so registrations at
/// the bus commute. Exposed so a component PROVIDING a bus states the proof
/// obligation where it declares the bus key (Theorem 45).
pub fn busWitness() CommutativityWitness {
    return .{
        .kind = .tagged_registry,
        .justification = "each listener carries a unique tag; two `on` " ++
            "registrations name distinct entries and commute (§3.4.2)",
    };
}

/// A type-erased event handler: a closure-free `{state, call}` pair.
/// `call` receives the handler's captured state and a type-erased payload
/// pointer; the bus guarantees the payload's TypeId matches what the handler
/// was registered under before invoking it.
pub const Handler = struct {
    state: *anyopaque,
    call: *const fn (state: *anyopaque, payload: *const anyopaque) void,
};

/// A listener subscription token: the unique tag identifying one registration
/// in the registry. `on` returns this so a caller can also unsubscribe
/// explicitly; the revertible-effect path uses it internally.
pub const Subscription = struct {
    event: []const u8,
    tag: u64,
};

/// A single registered listener entry.
const Entry = struct {
    /// Unique tag — the CRDT-style identifier that makes registrations commute
    /// (§3.4.2). Two distinct registrations always have distinct tags, so they
    /// touch disjoint entries.
    tag: u64,
    /// The event payload type this listener expects; emit checks it.
    payload_type: TypeId,
    handler: Handler,
};

/// The event bus: a tagged registry of listeners keyed by event name
/// (Definition 29's value table). Owned by whoever provides it (typically
/// installed in the coeffect store under a bus key).
pub const EventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// event name → list of listener entries. The list order is irrelevant to
    /// observable behavior precisely because registrations commute; emit may
    /// dispatch in any order (we use insertion order for determinism).
    listeners: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)),
    /// Monotonic counter minting unique tags (§3.4.2 unique-identifier scheme).
    next_tag: u64,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .listeners = .empty,
            .next_tag = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.listeners.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
        }
        self.listeners.deinit(self.allocator);
    }

    /// Register a listener for `event`, where the handler expects a payload of
    /// comptime type `P`. Returns the Subscription token (its unique tag).
    ///
    /// This is the forward half of the Definition 8 effect; `onEffect` wraps it
    /// with the matching inverse for tracking onto a context accumulator.
    pub fn on(
        self: *Self,
        comptime P: type,
        event: []const u8,
        handler: Handler,
    ) !Subscription {
        const gop = try self.listeners.getOrPut(self.allocator, event);
        if (!gop.found_existing) {
            // Own the event-name key; back it out if the rest fails.
            const owned = self.allocator.dupe(u8, event) catch |err| {
                self.listeners.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .empty;
        }
        const tag = self.next_tag;
        gop.value_ptr.append(self.allocator, .{
            .tag = tag,
            .payload_type = typeId(P),
            .handler = handler,
        }) catch |err| {
            // If this was a freshly created (now-empty) bucket, drop it so the
            // registry is unchanged on failure.
            if (gop.value_ptr.items.len == 0) {
                self.allocator.free(gop.key_ptr.*);
                self.listeners.removeByPtr(gop.key_ptr);
            }
            return err;
        };
        self.next_tag += 1;
        return .{ .event = event, .tag = tag };
    }

    /// Remove the listener identified by `sub` (the disposer / Definition 8
    /// inverse). Idempotent: removing an absent tag is a no-op, which keeps the
    /// inverse safe to run during recovery even if already removed.
    pub fn off(self: *Self, sub: Subscription) void {
        const bucket = self.listeners.getPtr(sub.event) orelse return;
        var i: usize = 0;
        while (i < bucket.items.len) : (i += 1) {
            if (bucket.items[i].tag == sub.tag) {
                _ = bucket.orderedRemove(i);
                return;
            }
        }
    }

    /// Dispatch `payload` (of comptime type `P`) to every listener of `event`.
    /// A read over the registry — no provision, no inverse. Listeners whose
    /// registered payload type does not match `P` are skipped (type safety,
    /// mirroring the store's TypeId check); the count of invoked listeners is
    /// returned.
    pub fn emit(self: *Self, comptime P: type, event: []const u8, payload: *const P) usize {
        const bucket = self.listeners.getPtr(event) orelse return 0;
        const want = typeId(P);
        var invoked: usize = 0;
        // Snapshot length: handlers registered during dispatch are not invoked
        // in this emit (listeners added mid-dispatch join the next emit).
        const n = bucket.items.len;
        var i: usize = 0;
        while (i < n and i < bucket.items.len) : (i += 1) {
            const entry = bucket.items[i];
            if (entry.payload_type != want) continue;
            entry.handler.call(entry.handler.state, @ptrCast(payload));
            invoked += 1;
        }
        return invoked;
    }

    /// Number of live listeners for `event` (for tests/introspection).
    pub fn count(self: *const Self, event: []const u8) usize {
        const bucket = self.listeners.getPtr(event) orelse return 0;
        return bucket.items.len;
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const TestSink = struct {
    sum: u32 = 0,
    hits: u32 = 0,
    fn handler(self: *TestSink) Handler {
        return .{ .state = self, .call = call };
    }
    fn call(state: *anyopaque, payload: *const anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(state));
        const v: *const u32 = @ptrCast(@alignCast(payload));
        self.sum += v.*;
        self.hits += 1;
    }
};

test "Definition 8: on registers a listener, emit dispatches to it" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var sink = TestSink{};
    _ = try bus.on(u32, "tick", sink.handler());

    var payload: u32 = 7;
    const n = bus.emit(u32, "tick", &payload);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 7), sink.sum);
    try std.testing.expectEqual(@as(u32, 1), sink.hits);
}

test "§3.4.2 tagged registry: two registrations get distinct tags and both fire" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var a = TestSink{};
    var b = TestSink{};
    const sa = try bus.on(u32, "tick", a.handler());
    const sb = try bus.on(u32, "tick", b.handler());
    try std.testing.expect(sa.tag != sb.tag); // unique tags → commute

    var payload: u32 = 3;
    const n = bus.emit(u32, "tick", &payload);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 3), a.sum);
    try std.testing.expectEqual(@as(u32, 3), b.sum);
}

test "Definition 8 inverse: off removes exactly the tagged listener (disposer)" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var a = TestSink{};
    var b = TestSink{};
    const sa = try bus.on(u32, "tick", a.handler());
    _ = try bus.on(u32, "tick", b.handler());
    try std.testing.expectEqual(@as(usize, 2), bus.count("tick"));

    bus.off(sa); // dispose a's subscription
    try std.testing.expectEqual(@as(usize, 1), bus.count("tick"));

    var payload: u32 = 5;
    _ = bus.emit(u32, "tick", &payload);
    try std.testing.expectEqual(@as(u32, 0), a.sum); // a gone
    try std.testing.expectEqual(@as(u32, 5), b.sum); // b remains
}

test "off is idempotent: removing an absent tag is a safe no-op" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var a = TestSink{};
    const sa = try bus.on(u32, "tick", a.handler());
    bus.off(sa);
    bus.off(sa); // second removal must not corrupt the registry
    bus.off(.{ .event = "nope", .tag = 999 }); // absent event
    try std.testing.expectEqual(@as(usize, 0), bus.count("tick"));
}

test "emit skips listeners whose payload type does not match (TypeId safety)" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var sink = TestSink{};
    _ = try bus.on(u32, "ev", sink.handler());

    // Emit a different payload type to the same event: no listener matches.
    var wrong: u64 = 1;
    const n = bus.emit(u64, "ev", &wrong);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(@as(u32, 0), sink.hits);
}

test "Definition 46: the bus certifies a tagged_registry commutativity witness" {
    const w = busWitness();
    try std.testing.expectEqual(CommutativityKind.tagged_registry, w.kind);
    try std.testing.expect(w.isCommutative());
}

test "unknown event: emit on an event with no listeners is a no-op" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var payload: u32 = 1;
    try std.testing.expectEqual(@as(usize, 0), bus.emit(u32, "none", &payload));
}

fn busUnderOom(allocator: std.mem.Allocator) !void {
    var bus = EventBus.init(allocator);
    defer bus.deinit();
    var a = TestSink{};
    var b = TestSink{};
    _ = try bus.on(u32, "tick", a.handler());
    _ = try bus.on(u32, "tick", b.handler()); // same bucket, grows the list
    _ = try bus.on(u32, "tock", a.handler()); // new bucket, owns a new key
    var p: u32 = 1;
    _ = bus.emit(u32, "tick", &p);
}

test "OOM safety: on/emit/deinit leak nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, busUnderOom, .{});
}
