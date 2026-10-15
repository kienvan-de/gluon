//! C ABI contract for Gluon dynamic plugins — the Zig source of truth.
//!
//! Mirrors `include/gluon_abi.h` exactly. Any language with C FFI implements
//! a Gluon plugin by conforming to this interface:
//!
//!   Zig plugins    → @import("gluon_abi")   (this file)
//!   C/C++ plugins  → #include "gluon_abi.h"
//!   Rust plugins   → bindgen or manual transcription from gluon_abi.h
//!
//! This file has NO imports from Gluon host internals (no store, no context,
//! no lifecycle) so it compiles cleanly into a plugin shared library.
//! Host-side utilities that need Gluon internals live in host.zig.
//!
//! ## Threading contract (M9)
//!
//! All GluonHostApi calls are **single-threaded and synchronous**. The Gluon
//! host (EventBus, coeffect store, accumulator) has no internal locks. A plugin
//! MUST only call host functions (subscribe, emit, provide_opaque, …) from the
//! thread that called activate() or deactivate(). Calling host functions from
//! a background thread is undefined behaviour. If a plugin spawns threads, it
//! must complete all host interactions before returning from activate(), and
//! must stop its threads before calling any host function from deactivate().

const std = @import("std");

// ── Primitive types ───────────────────────────────────────────────

/// Subscription token returned by subscribe(). Pass to unsubscribe().
pub const GluonSubToken = u64;

/// Event handler the plugin registers.
///   state — opaque pointer the plugin passed to subscribe().
///   json  — null-terminated JSON payload, valid only during the call.
pub const GluonHandlerFn = *const fn (
    state: ?*anyopaque,
    json: [*:0]const u8,
) callconv(.c) void;

/// Optional cleanup callback for opaque service values.
/// Called by Gluon when the provision is withdrawn.
pub const GluonFreeFn = *const fn (ptr: *anyopaque) callconv(.c) void;

// ── Ext metadata ───────────────────────────────────────────────

/// Commutativity hint a plugin declares for its provided keys (finding H4).
/// Matches `GluonCommutativity` in the C header. Zero = trivial (default,
/// backward-compatible); non-zero values tighten the Theorem 47 check.
pub const GluonCommutativity = enum(u8) {
    /// Pure value / no operations beyond get-set: trivially commutative.
    trivial = 0,
    /// Tagged-registry (each entry carries a unique tag; registrations commute).
    tagged_registry = 1,
    /// Observational (hidden internal state; scalable commutativity rule).
    observational = 2,
    /// Non-commutative: operations are order-sensitive. Gluon will reject load.
    non_commutative = 3,
    _,
};

/// Metadata a plugin declares about its coeffect interface.
/// Returned by GluonExtVTable.meta once after dlopen.
/// All pointers must remain valid for the process lifetime (static data).
pub const GluonExtMeta = extern struct {
    /// Human-readable plugin name (null-terminated).
    name: [*:0]const u8,
    /// Keys this plugin REQUIRES before activating.
    /// Null-terminated array of null-terminated C strings.
    inject: [*:null]const ?[*:0]const u8,
    /// Keys this plugin PROVIDES when active.
    /// Null-terminated array of null-terminated C strings.
    provide: [*:null]const ?[*:0]const u8,
    /// Commutativity declaration for the provided keys (finding H4).
    /// 0 = trivial (default, backward-compatible with ABI v1 plugins).
    commutativity: GluonCommutativity = .trivial,
};

// ── Ext handle ─────────────────────────────────────────────────

/// Opaque handle returned by activate(). Gluon stores and forwards it.
/// Cast to your own struct type inside activate/deactivate.
///
/// ## Null convention (L10 known limitation)
///
/// `activate` returning null signals failure; a plugin with no private state
/// cannot return a valid null handle. Plugins must allocate a minimal sentinel
/// struct (e.g. a zero-byte or single-bool handle) to satisfy the non-null
/// requirement. A future revision could introduce a dedicated
/// `GluonActivateResult` enum to separate the failure signal from the handle
/// value, but that is a breaking ABI change.
pub const GluonExtHandle = opaque {};

// ── Host API ──────────────────────────────────────────────────────

/// The interface Gluon passes to activate(). All calls are synchronous.
/// Valid until deactivate() returns — safe to store in your handle.
pub const GluonHostApi = extern struct {
    /// Opaque Gluon context — pass unchanged to every function.
    ctx: *anyopaque,

    /// Subscribe to `event`. Returns a token for unsubscribing, or 0 on failure.
    subscribe: *const fn (
        ctx: *anyopaque,
        event: [*:0]const u8,
        handler: GluonHandlerFn,
        state: ?*anyopaque,
    ) callconv(.c) GluonSubToken,

    /// Remove the subscription identified by `token`. Idempotent.
    unsubscribe: *const fn (
        ctx: *anyopaque,
        token: GluonSubToken,
    ) callconv(.c) void,

    /// Emit `json` to all current listeners of `event`. Fire-and-forget.
    emit: *const fn (
        ctx: *anyopaque,
        event: [*:0]const u8,
        json: [*:0]const u8,
    ) callconv(.c) void,

    /// Provision an opaque service under `key`. Returns 0 on success.
    provide_opaque: *const fn (
        ctx: *anyopaque,
        key: [*:0]const u8,
        ptr: *anyopaque,
        free_fn: ?GluonFreeFn,
    ) callconv(.c) c_int,

    /// Withdraw a previously provisioned service.
    withdraw_opaque: *const fn (
        ctx: *anyopaque,
        key: [*:0]const u8,
    ) callconv(.c) void,
};

// ── Ext vtable ─────────────────────────────────────────────────

/// The vtable a plugin exports via the `gluon_plugin_vtable` symbol.
pub const GluonExtVTable = extern struct {
    /// Return static plugin metadata. Called once after dlopen.
    meta: *const fn () callconv(.c) *const GluonExtMeta,
    /// Activate the plugin. Return a non-null handle on success, null on failure.
    activate: *const fn (host: *const GluonHostApi) callconv(.c) ?*GluonExtHandle,
    /// Deactivate the plugin. After this returns, `host` is invalid.
    deactivate: *const fn (handle: *GluonExtHandle) callconv(.c) void,
};

/// The symbol name Gluon resolves after dlopen.
pub const VTABLE_SYMBOL = "gluon_plugin_vtable";

// ── Host-side wrapper for opaque services ────────────────────────
//
// When a plugin calls provide_opaque(key, ptr, free_fn), Gluon boxes
// the pointer into a ExtService and stores it in the coeffect store.
// Native Zig consumers retrieve *const ExtService and cast .ptr.

pub const ExtService = struct {
    ptr: *anyopaque,
    free_fn: ?GluonFreeFn,
    /// Whether this service is still live (provisioned and not yet freed).
    /// Guards against freeing twice: an explicit `withdraw_opaque` and the
    /// provision's tracked LIFO inverse both route through `free`, and only
    /// the first call runs `free_fn`. Also false until the store binding is
    /// actually installed, so a provision that fails before `store.set` never
    /// runs `free_fn` on recover (finding M8).
    live: bool = false,

    /// Run the plugin's `free_fn(ptr)` exactly once over this service's life.
    /// Idempotent: subsequent calls (e.g. the rollback inverse after an
    /// explicit withdraw) are no-ops. Requires `*ExtService` so it can clear
    /// the `live` flag; both callers hold the same underlying allocation.
    pub fn free(self: *ExtService) void {
        if (!self.live) return;
        self.live = false;
        if (self.free_fn) |f| f(self.ptr);
    }
};

// ── Utility ───────────────────────────────────────────────────────

/// Convert a null-terminated C string to a Zig slice (no allocation).
pub fn cStrSlice(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}
