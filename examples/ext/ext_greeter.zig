//! Dynamic greeter plugin — compiled to a shared library.
//!
//! Provides a "greeter.service" opaque C service struct.
//!
//!   inject  = []
//!   provide = ["greeter.service"]

const std = @import("std");
const abi = @import("gluon_abi");

// ── Shared service contract ───────────────────────────────────────
//
// Both this plugin and its consumers agree on this layout.
// In a real project this lives in a shared header / Zig file.

pub const GreeterService = extern struct {
    greet: *const fn (name: [*:0]const u8) callconv(.c) void,
};

// ── Static metadata ───────────────────────────────────────────────

const inject_list  = [_:null]?[*:0]const u8{null};
const provide_list = [_:null]?[*:0]const u8{ "greeter.service", null };

const META = abi.GluonExtMeta{
    .name    = "zig_ext_greeter",
    .inject  = &inject_list,
    .provide = &provide_list,
};

// ── Concrete greet function ───────────────────────────────────────

fn greetImpl(name: [*:0]const u8) callconv(.c) void {
    const n = std.mem.span(name);
    std.debug.print("[zig_ext_greeter] Hello, {s}!\n", .{n});
}

const GREETER_SVC = GreeterService{ .greet = greetImpl };

// ── Ext handle ─────────────────────────────────────────────────

const GreeterHandle = struct {
    host: *const abi.GluonHostApi,
};

// ── Vtable ────────────────────────────────────────────────────────

fn vtMeta() callconv(.c) *const abi.GluonExtMeta {
    return &META;
}

fn vtActivate(host: *const abi.GluonHostApi) callconv(.c) ?*abi.GluonExtHandle {
    const h = std.heap.c_allocator.create(GreeterHandle) catch return null;
    h.* = .{ .host = host };
    const rc = host.provide_opaque(host.ctx, "greeter.service", @constCast(&GREETER_SVC), null);
    if (rc != 0) { std.heap.c_allocator.destroy(h); return null; }
    return @ptrCast(h);
}

fn vtDeactivate(raw: *abi.GluonExtHandle) callconv(.c) void {
    const h: *GreeterHandle = @ptrCast(@alignCast(raw));
    h.host.withdraw_opaque(h.host.ctx, "greeter.service");
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
