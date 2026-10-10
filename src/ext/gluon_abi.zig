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
};

// ── Ext handle ─────────────────────────────────────────────────

/// Opaque handle returned by activate(). Gluon stores and forwards it.
/// Cast to your own struct type inside activate/deactivate.
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

    pub fn free(self: *const ExtService) void {
        if (self.free_fn) |f| f(self.ptr);
    }
};

// ── Utility ───────────────────────────────────────────────────────

/// Convert a null-terminated C string to a Zig slice (no allocation).
pub fn cStrSlice(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}
