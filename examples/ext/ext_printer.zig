//! Dynamic printer plugin — compiled to a shared library (.so / .dll / .dylib).
//!
//! Subscribes to the "print" event on the shared EventBus.
//! Every JSON payload emitted to that event is written to stdout.
//!
//!   inject  = ["gluon.dyn.bus"]   — waits for the bus before activating
//!   provide = []
//!
//! This file is the Zig implementation of the same interface as ext_printer.c.
//! It imports only `plugin_abi` (the minimal ABI types) — no Gluon internals.
//!
//! Build via `zig build ext-plugins` (see build.zig).

const std = @import("std");
const abi = @import("gluon_abi");

// ── Static metadata ───────────────────────────────────────────────

const inject_list  = [_:null]?[*:0]const u8{ "gluon.dyn.bus", null };
const provide_list = [_:null]?[*:0]const u8{null};

const META = abi.GluonExtMeta{
    .name    = "zig_ext_printer",
    .inject  = &inject_list,
    .provide = &provide_list,
};

// ── Ext handle ─────────────────────────────────────────────────

const PrinterHandle = struct {
    token: abi.GluonSubToken,
    host:  *const abi.GluonHostApi,
};

// ── Event handler ─────────────────────────────────────────────────

fn onPrint(_: ?*anyopaque, json: [*:0]const u8) callconv(.c) void {
    const msg = std.mem.span(json);
    std.debug.print("[zig_ext_printer] {s}\n", .{msg});
}

// ── Vtable ────────────────────────────────────────────────────────

fn vtMeta() callconv(.c) *const abi.GluonExtMeta {
    return &META;
}

fn vtActivate(host: *const abi.GluonHostApi) callconv(.c) ?*abi.GluonExtHandle {
    const h = std.heap.c_allocator.create(PrinterHandle) catch return null;
    h.* = .{
        .token = host.subscribe(host.ctx, "print", onPrint, null),
        .host  = host,
    };
    return @ptrCast(h);
}

fn vtDeactivate(raw: *abi.GluonExtHandle) callconv(.c) void {
    const h: *PrinterHandle = @ptrCast(@alignCast(raw));
    h.host.unsubscribe(h.host.ctx, h.token);
    std.heap.c_allocator.destroy(h);
}

const VTABLE = abi.GluonExtVTable{
    .meta       = vtMeta,
    .activate   = vtActivate,
    .deactivate = vtDeactivate,
};

export fn gluon_plugin_vtable() callconv(.c) *const abi.GluonExtVTable {
    return &VTABLE;
}
