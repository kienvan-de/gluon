//! Host API bridge — implements `GluonHostApi` for a fiber's Context.
//!
//! This module fills in the `GluonHostApi` function-pointer struct that Gluon
//! passes to a dynamic plugin's `activate` call. Each function pointer routes
//! into the fiber's own `Context`, using the same Gluon primitives (ctx.on,
//! ctx.emit, ctx.store.set) that native Zig components use.
//!
//! ## EventBus payload
//!
//! All events between dynamic plugins use `[]const u8` as the payload type —
//! a JSON string by convention. The bridge converts between the C `[*:0]u8`
//! (null-terminated) and the Zig `[]const u8` the EventBus stores.
//!
//! Native Zig components use `ctx.on([]const u8, ext_bus_key, ...)` to
//! interoperate. The TypeId of `[]const u8` is the same on both sides.
//!
//! ## Opaque service provision — ownership
//!
//! `store.set(V, key, value)` boxes `value` into a fresh allocation (the
//! store owns and frees that box on restrict). When storing a `*ExtService`,
//! the box holds a copy of the pointer, and the store frees the box on
//! restrict — but NOT the `ExtService` struct itself (which we also allocate).
//!
//! `cProvideOpaque` therefore tracks TWO inverses, newest-first (LIFO):
//!
//!   Inverse A (newest — runs first): `svc.free()`.
//!     Runs the plugin's free_fn(ptr) exactly once (idempotent via svc.live),
//!     then on `deinit` frees the ExtService allocation itself.
//!
//!   Inverse B (oldest — runs second): `store.restrict(key)`.
//!     Removes the binding; the store's StoredValue.deinit frees the box (a
//!     copy of the svc pointer), never svc itself. Safe regardless of A.
//!
//! ## Freeing exactly once (findings C1, M8)
//!
//! Both an explicit `withdraw_opaque` and the tracked Inverse A route through
//! `ExtService.free`, which is idempotent on `svc.live`:
//!
//!   - `live` starts false and is set true only AFTER store.set succeeds, so a
//!     provision that fails before the binding is installed never runs free_fn
//!     on recover (M8).
//!   - The first `free` (explicit withdraw OR rollback) runs free_fn and clears
//!     `live`; any later `free` is a no-op — so withdraw-then-unload calls
//!     free_fn once, not twice (C1).

const std = @import("std");
const abi = @import("gluon_abi.zig");
const Context = @import("../context/context.zig").Context;
const EventBus = @import("../event/bus.zig").EventBus;
const Handler = @import("../event/bus.zig").Handler;
const acc_mod = @import("../effect/accumulator.zig");
const store_mod = @import("../coeffect/store.zig");
const Key = store_mod.Key;

pub const GluonHostApi = abi.GluonHostApi;
pub const GluonSubToken = abi.GluonSubToken;
pub const ExtService = abi.ExtService;

/// Build a Key for a named dynamic opaque service.
pub fn extServiceKey(name: []const u8) Key {
    return Key.of(*const ExtService, name);
}

/// The EventBus key dynamic plugins and native components share.
pub const ext_bus_key = Key.of(*EventBus, "gluon.dyn.bus");

/// Per-fiber bridge. Heap-allocated once at activation; freed by the inverse
/// registered in ext_loader when the fiber's LIFO rollback runs.
pub const HostBridge = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    /// The set of keys this plugin declared in meta.provide. Used by
    /// cProvideOpaque to reject calls for undeclared keys (finding H3):
    /// a plugin that writes a key outside its declared set would bypass the
    /// registry's provider table, conflict check, and notify path entirely.
    /// Slice is borrowed from the Extension that owns it; must outlive the bridge.
    declared_provide: []const Key = &.{},

    /// Build the `GluonHostApi` struct backed by this bridge.
    pub fn hostApi(self: *HostBridge) GluonHostApi {
        return GluonHostApi{
            .ctx = self,
            .subscribe = cSubscribe,
            .unsubscribe = cUnsubscribe,
            .emit = cEmit,
            .provide_opaque = cProvideOpaque,
            .withdraw_opaque = cWithdrawOpaque,
        };
    }
};

// ── Helpers ───────────────────────────────────────────────────────

fn bridgeOf(ctx: *anyopaque) *HostBridge {
    return @ptrCast(@alignCast(ctx));
}

/// A small inline buffer that covers the common case (payloads ≤ this size)
/// without a heap allocation; larger payloads fall back to allocation.
const inline_payload_cap = 512;

/// State for the C-handler wrapper (one allocation per subscription).
const WrapState = struct {
    c_handler: abi.GluonHandlerFn,
    c_state: ?*anyopaque,
    /// Allocator for the per-dispatch NUL-terminated copy of large payloads.
    allocator: std.mem.Allocator,
};

/// The Gluon handler that converts a Zig `[]const u8` payload into the
/// NUL-terminated C string the plugin's handler expects.
///
/// The C ABI handler takes `[*:0]const u8` with no length, so the payload must
/// be NUL-terminated. Rather than truncate at a fixed size (the former 4 KiB
/// stack buffer silently dropped larger payloads — finding C2), we copy the
/// FULL payload: into a small stack buffer when it fits, else a heap allocation
/// freed as soon as the handler returns (the payload is only valid during the
/// call). On allocation failure the handler is skipped rather than handed a
/// truncated string.
fn wrappedCall(state: *anyopaque, payload: *const anyopaque) void {
    const ws: *WrapState = @ptrCast(@alignCast(state));
    const msg: *const []const u8 = @ptrCast(@alignCast(payload));
    const len = msg.*.len;

    var stack_buf: [inline_payload_cap]u8 = undefined;
    // Choose storage big enough for the payload plus a NUL terminator: the
    // inline stack buffer when it fits, else a right-sized heap allocation.
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |hb| ws.allocator.free(hb);

    const buf: []u8 = if (len + 1 <= stack_buf.len)
        stack_buf[0 .. len + 1]
    else blk: {
        const hb = ws.allocator.alloc(u8, len + 1) catch return; // skip on OOM
        heap_buf = hb;
        break :blk hb;
    };

    @memcpy(buf[0..len], msg.*[0..len]);
    buf[len] = 0;
    ws.c_handler(ws.c_state, buf[0..len :0].ptr);
}

// ── C-callable functions ──────────────────────────────────────────

/// Subscribe to a JSON event. Returns a token (bus subscription tag) or 0.
fn cSubscribe(
    ctx: *anyopaque,
    event: [*:0]const u8,
    handler: abi.GluonHandlerFn,
    state: ?*anyopaque,
) callconv(.c) GluonSubToken {
    const bridge = bridgeOf(ctx);

    const ws = bridge.allocator.create(WrapState) catch return 0;
    const event_slice = abi.cStrSlice(event);
    ws.* = .{ .c_handler = handler, .c_state = state, .allocator = bridge.allocator };

    const gluon_handler = Handler{ .state = ws, .call = wrappedCall };

    // ctx.on registers the listener AND tracks bus.off on the accumulator.
    const sub = bridge.ctx.on([]const u8, ext_bus_key, event_slice, gluon_handler) catch {
        bridge.allocator.destroy(ws);
        return 0;
    };

    // Track a separate inverse to free the WrapState (LIFO: runs before bus.off).
    const Inv = acc_mod.Inverse(Context){
        .state = ws,
        .call = struct {
            fn call(_: *anyopaque, _: *Context) void {}
        }.call,
        .deinit = struct {
            fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                a.destroy(@as(*WrapState, @ptrCast(@alignCast(s))));
            }
        }.deinit,
    };
    bridge.ctx.dispose.track(Inv) catch {
        // Failed to track the WrapState cleanup. Remove listener and ws now.
        if (bridge.ctx.store.get(*EventBus, ext_bus_key)) |bus| {
            bus.off(.{ .event = event_slice, .tag = sub.tag });
        } else |_| {}
        bridge.allocator.destroy(ws);
        return 0; // signal failure
    };

    return sub.tag;
}

/// Scan all event buckets for `token` and remove the matching entry.
/// Correctness relies on the bus's global-unique tag invariant: `next_tag` is
/// a single monotonic counter across ALL event buckets (bus.zig), so a given
/// token is unique across all events and the scan hits at most one entry.
/// This is O(events) in the number of distinct subscribed events; for typical
/// plugins with a small number of subscriptions this is negligible.
/// (H5 finding: the invariant is implicit — documented here explicitly.)
fn cUnsubscribe(ctx: *anyopaque, token: GluonSubToken) callconv(.c) void {
    const bridge = bridgeOf(ctx);
    const bus = bridge.ctx.store.get(*EventBus, ext_bus_key) catch return;
    var it = bus.listeners.iterator();
    while (it.next()) |kv| {
        bus.off(.{ .event = kv.key_ptr.*, .tag = token });
    }
}

/// Emit a JSON null-terminated string to all listeners of `event`.
fn cEmit(
    ctx: *anyopaque,
    event: [*:0]const u8,
    json: [*:0]const u8,
) callconv(.c) void {
    const bridge = bridgeOf(ctx);
    const event_slice = abi.cStrSlice(event);
    const json_slice = abi.cStrSlice(json);
    const n = bridge.ctx.emit([]const u8, ext_bus_key, event_slice, &json_slice) catch 0;
    // L11 diagnostic: in debug builds, warn only if there ARE listeners for this
    // event but NONE were invoked (the classic TypeId-mismatch case: a native
    // subscriber used a payload type other than `[]const u8`, which the bus
    // silently skips). Zero listeners for an event is normal and not warned.
    if (std.debug.runtime_safety and n == 0) {
        if (bridge.ctx.store.get(*EventBus, ext_bus_key)) |bus| {
            if (bus.count(event_slice) > 0) {
                std.debug.print(
                    "[gluon ext] cEmit: event '{s}' has {d} listener(s) but 0 were " ++
                    "invoked — native subscribers must use `[]const u8` as the payload type\n",
                    .{ event_slice, bus.count(event_slice) },
                );
            }
        } else |_| {}
    }
}

/// Provision an opaque service under `key`.
///
/// The ExtService struct is allocated here and owned by inv_a (freed when the
/// LIFO rollback runs). The store holds a COPY of the `*const ExtService` pointer
/// inside its own box; `store.restrict` frees that box, not the ExtService.
fn cProvideOpaque(
    ctx: *anyopaque,
    key: [*:0]const u8,
    ptr: *anyopaque,
    free_fn: ?abi.GluonFreeFn,
) callconv(.c) c_int {
    const bridge = bridgeOf(ctx);
    const key_slice = abi.cStrSlice(key);
    const store_key = extServiceKey(key_slice);

    // H3 guard: reject keys not declared in meta.provide. A plugin that writes
    // an undeclared key bypasses the registry's provider table, conflict check,
    // and notify path — the spatial engine would be unaware of the provision.
    var declared = false;
    for (bridge.declared_provide) |dk| {
        if (std.mem.eql(u8, dk.name, key_slice)) { declared = true; break; }
    }
    if (!declared) return -1;

    // Allocate the ExtService struct. `live` starts false and is flipped true
    // only once the store binding is actually installed (below), so a provision
    // that fails before store.set never runs free_fn on recover (finding M8).
    const svc = bridge.allocator.create(ExtService) catch return -1;
    svc.* = .{ .ptr = ptr, .free_fn = free_fn, .live = false };

    // Inverse B (oldest, runs second): restrict the store key.
    // The store's StoredValue.deinit frees its internal box (a copy of the svc
    // pointer), NOT svc itself — svc is freed separately by inv_a.deinit. The
    // order of A and B does not matter: B only touches the box.
    const store_key_box = bridge.allocator.create(Key) catch {
        bridge.allocator.destroy(svc);
        return -1;
    };
    store_key_box.* = store_key;

    const inv_b = acc_mod.Inverse(Context){
        .state = store_key_box,
        .call = struct {
            fn call(s: *anyopaque, cc: *Context) void {
                const k: *Key = @ptrCast(@alignCast(s));
                cc.store.restrict(k.*) catch {};
            }
        }.call,
        .deinit = struct {
            fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                a.destroy(@as(*Key, @ptrCast(@alignCast(s))));
            }
        }.deinit,
    };
    bridge.ctx.dispose.track(inv_b) catch {
        bridge.allocator.destroy(store_key_box);
        bridge.allocator.destroy(svc);
        return -1;
    };

    // Inverse A (newest, runs first): call free_fn(ptr) + free ExtService.
    // `free` is idempotent via svc.live: if the service was already withdrawn
    // explicitly (cWithdrawOpaque), this is a no-op — no double free_fn (C1).
    const inv_a = acc_mod.Inverse(Context){
        .state = svc,
        .call = struct {
            fn call(s: *anyopaque, _: *Context) void {
                const d: *ExtService = @ptrCast(@alignCast(s));
                d.free();
            }
        }.call,
        .deinit = struct {
            fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                a.destroy(@as(*ExtService, @ptrCast(@alignCast(s))));
            }
        }.deinit,
    };
    bridge.ctx.dispose.track(inv_a) catch {
        // inv_b is tracked (will restrict on recover, fail silently = ok).
        // svc is not in the store; free it now.
        bridge.allocator.destroy(svc);
        return -1;
    };

    // Write svc into the store. The store creates its own box(*const ExtService)
    // and stores svc there; store.restrict frees that box via StoredValue.deinit.
    bridge.ctx.store.set(*const ExtService, store_key, svc) catch {
        // Provision failed before taking effect. inv_a and inv_b are tracked;
        // on recover inv_a calls svc.free(), but svc.live is still false, so
        // free_fn does NOT run on a value we never provided (finding M8). inv_b
        // restricts the absent key (fails silently). Nothing is leaked.
        return -1;
    };

    // The binding is installed: mark the service live so its free_fn runs
    // exactly once, on either explicit withdraw or LIFO rollback.
    svc.live = true;
    return 0;
}

/// Withdraw an opaque service: call its free_fn, then restrict the store key.
fn cWithdrawOpaque(ctx: *anyopaque, key: [*:0]const u8) callconv(.c) void {
    const bridge = bridgeOf(ctx);
    const key_slice = abi.cStrSlice(key);
    const store_key = extServiceKey(key_slice);

    if (bridge.ctx.store.get(*const ExtService, store_key)) |svc| {
        // The store holds the same mutable ExtService allocation cProvideOpaque
        // created; @constCast reaches it to run (and disarm) free. Idempotent:
        // the provision's tracked inverse will see live=false and skip (C1).
        @constCast(svc).free(); // call plugin's free_fn(ptr) exactly once
    } else |_| {}

    // restrict removes the binding and frees the store's box.
    bridge.ctx.store.restrict(store_key) catch {};
}

// ─────────────────────────────── Tests ───────────────────────────

test "HostBridge.hostApi fills all function pointers" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bridge = try std.testing.allocator.create(HostBridge);
    defer std.testing.allocator.destroy(bridge);
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator };

    const api = bridge.hostApi();
    // In Zig 0.17 we cannot compare fn pointers to `undefined`; instead verify
    // the ctx pointer round-trips correctly (proves the struct is populated).
    try std.testing.expect(api.ctx == @as(*anyopaque, bridge));
    // Verify each fn ptr is non-null by comparing identity.
    try std.testing.expect(api.subscribe == cSubscribe);
    try std.testing.expect(api.unsubscribe == cUnsubscribe);
    try std.testing.expect(api.emit == cEmit);
    try std.testing.expect(api.provide_opaque == cProvideOpaque);
    try std.testing.expect(api.withdraw_opaque == cWithdrawOpaque);
}

test "cSubscribe + cEmit: C handler receives emitted JSON" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    // Provision the bus into the context store.
    try ctx.set(*EventBus, ext_bus_key, &bus);
    // Sanity: the store holds the bus (reachable via ctx.on later).
    _ = try ctx.get(*EventBus, ext_bus_key);

    const bridge = try std.testing.allocator.create(HostBridge);
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator };
    // bridge is freed by ctx.dispose.recover below (not with explicit destroy here).

    const api = bridge.hostApi();

    var received: [64]u8 = undefined;
    var received_len: usize = 0;
    const Cap = struct {
        buf: *[64]u8,
        len: *usize,
    };
    var cap = Cap{ .buf = &received, .len = &received_len };

    const handler: abi.GluonHandlerFn = struct {
        fn h(state: ?*anyopaque, json: [*:0]const u8) callconv(.c) void {
            const s: *Cap = @ptrCast(@alignCast(state.?));
            const slice = std.mem.span(json);
            const n = @min(slice.len, s.buf.len);
            @memcpy(s.buf[0..n], slice[0..n]);
            s.len.* = n;
        }
    }.h;

    const tok = api.subscribe(api.ctx, "test.event", handler, &cap);
    // Token 0 is valid (first subscription always gets tag=0). Verify success
    // by checking the bus listener count instead.
    try std.testing.expectEqual(@as(usize, 1), bus.count("test.event"));
    _ = tok;

    api.emit(api.ctx, "test.event", "{\"x\":1}");
    try std.testing.expectEqualStrings("{\"x\":1}", received[0..received_len]);

    // Recover: runs bus.off + WrapState free + bus provision restrict.
    // bridge is freed as part of the context teardown via ctx.deinit.
    // But we allocated bridge separately — it leaks unless we free it here.
    // We need to free the bridge ourselves after recover, before ctx.deinit.
    ctx.dispose.recover(ctx);
    std.testing.allocator.destroy(bridge);
}

test "C2: a payload larger than the inline buffer reaches the handler intact" {
    // Regression for finding C2: wrappedCall used to copy into a fixed stack
    // buffer and silently truncate larger payloads. Emit a payload well past the
    // inline cap and assert the handler receives every byte, NUL-terminated.
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.set(*EventBus, ext_bus_key, &bus);

    const bridge = try std.testing.allocator.create(HostBridge);
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator };
    const api = bridge.hostApi();

    // A payload larger than inline_payload_cap (forces the heap fallback).
    const big_len = inline_payload_cap * 3 + 7;
    const big = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = @intCast('A' + (i % 26));

    const Cap = struct {
        a: std.mem.Allocator,
        got: []u8 = &.{},
    };
    var cap = Cap{ .a = std.testing.allocator };

    const handler: abi.GluonHandlerFn = struct {
        fn h(state: ?*anyopaque, json: [*:0]const u8) callconv(.c) void {
            const s: *Cap = @ptrCast(@alignCast(state.?));
            const slice = std.mem.span(json); // relies on NUL termination
            s.got = s.a.dupe(u8, slice) catch unreachable;
        }
    }.h;

    _ = api.subscribe(api.ctx, "big.event", handler, &cap);

    const payload: []const u8 = big;
    _ = try ctx.emit([]const u8, ext_bus_key, "big.event", &payload);
    defer std.testing.allocator.free(cap.got);

    try std.testing.expectEqual(big_len, cap.got.len); // nothing truncated
    try std.testing.expectEqualSlices(u8, big, cap.got); // every byte intact

    ctx.dispose.recover(ctx);
    std.testing.allocator.destroy(bridge);
}

test "cUnsubscribe: listener removed, later emits don't fire" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.set(*EventBus, ext_bus_key, &bus);

    const bridge = try std.testing.allocator.create(HostBridge);
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator };

    const api = bridge.hostApi();

    var hits: u32 = 0;
    const handler: abi.GluonHandlerFn = struct {
        fn h(state: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {
            const p: *u32 = @ptrCast(@alignCast(state.?));
            p.* += 1;
        }
    }.h;

    const tok = api.subscribe(api.ctx, "ping", handler, &hits);
    api.emit(api.ctx, "ping", "{}");
    try std.testing.expectEqual(@as(u32, 1), hits);

    api.unsubscribe(api.ctx, tok);
    api.emit(api.ctx, "ping", "{}");
    try std.testing.expectEqual(@as(u32, 1), hits);

    ctx.dispose.recover(ctx);
    std.testing.allocator.destroy(bridge);
}

test "cProvideOpaque + cWithdrawOpaque: service round-trip with free_fn" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bridge = try std.testing.allocator.create(HostBridge);
    const declared = [_]Key{extServiceKey("svc.test")};
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator, .declared_provide = &declared };

    const api = bridge.hostApi();

    var dummy: u32 = 42;
    var freed = false;
    const St = struct {
        var flag: *bool = undefined;
        fn freeFn(ptr: *anyopaque) callconv(.c) void {
            _ = ptr;
            flag.* = true;
        }
    };
    St.flag = &freed;

    const rc = api.provide_opaque(api.ctx, "svc.test", &dummy, St.freeFn);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    const k = extServiceKey("svc.test");
    const svc = try ctx.get(*const ExtService, k);
    try std.testing.expectEqual(@as(*u32, @ptrCast(@alignCast(svc.ptr))), &dummy);

    // Explicit withdraw: free_fn fires and key is removed.
    api.withdraw_opaque(api.ctx, "svc.test");
    try std.testing.expect(freed);
    try std.testing.expect(!ctx.has(k));

    // LIFO rollback: inv_a.call runs (free_fn already called — won't double-call
    // because free_fn is idempotent in this test). inv_b restrict fails silently.
    ctx.dispose.recover(ctx);
    std.testing.allocator.destroy(bridge);
}

test "C1: explicit withdraw then unload calls free_fn exactly once" {
    // Regression for finding C1: cWithdrawOpaque used to leave inv_a tracked, so
    // the fiber's later recover ran free_fn a SECOND time (double-free). A real
    // free_fn is NOT idempotent, so we count invocations and require exactly one.
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bridge = try std.testing.allocator.create(HostBridge);
    const declared_c1 = [_]Key{extServiceKey("svc.c1")};
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator, .declared_provide = &declared_c1 };

    const api = bridge.hostApi();
    var dummy: u32 = 7;
    var free_calls: u32 = 0;
    const St = struct {
        var counter: *u32 = undefined;
        fn freeFn(ptr: *anyopaque) callconv(.c) void {
            _ = ptr;
            counter.* += 1;
        }
    };
    St.counter = &free_calls;

    const rc = api.provide_opaque(api.ctx, "svc.c1", &dummy, St.freeFn);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    // Explicit withdraw: free_fn fires once, key removed.
    api.withdraw_opaque(api.ctx, "svc.c1");
    try std.testing.expectEqual(@as(u32, 1), free_calls);

    // Fiber unload (LIFO rollback). The provision's inverse must NOT free again.
    ctx.dispose.recover(ctx);
    try std.testing.expectEqual(@as(u32, 1), free_calls); // exactly once, not twice

    std.testing.allocator.destroy(bridge);
}

test "cProvideOpaque inverse: LIFO rollback calls free_fn then restricts key" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const bridge = try std.testing.allocator.create(HostBridge);
    const declared_rollback = [_]Key{extServiceKey("rollback.test")};
    bridge.* = .{ .ctx = ctx, .allocator = std.testing.allocator, .declared_provide = &declared_rollback };

    const api = bridge.hostApi();

    var dummy: u32 = 99;
    var freed = false;
    const St = struct {
        var flag: *bool = undefined;
        fn freeFn(ptr: *anyopaque) callconv(.c) void {
            _ = ptr;
            flag.* = true;
        }
    };
    St.flag = &freed;

    _ = api.provide_opaque(api.ctx, "rollback.test", &dummy, St.freeFn);
    const k = extServiceKey("rollback.test");
    try std.testing.expect(ctx.has(k));

    // LIFO rollback: inv_a (free_fn + destroy svc), then inv_b (restrict key).
    ctx.dispose.recover(ctx);
    try std.testing.expect(freed);
    try std.testing.expect(!ctx.has(k));

    std.testing.allocator.destroy(bridge);
}
