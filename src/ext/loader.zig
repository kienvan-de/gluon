//! Dynamic plugin loader — wraps a foreign `.so`/`.dll`/`.dylib` as a Gluon Component.
//!
//! A dynamic plugin is a shared library that exports the symbol:
//!
//!   `export fn gluon_plugin_vtable() callconv(.c) *const GluonExtVTable`
//!
//! The loader:
//!   1. Opens the library with `std.DynLib`.
//!   2. Resolves `gluon_plugin_vtable` and calls it to get the vtable.
//!   3. Calls `vtable.meta()` to read the plugin's inject/provide declarations.
//!   4. Builds a Gluon `Component` whose `apply` function:
//!        a. Creates a `HostBridge` and fills the `GluonHostApi`.
//!        b. Calls `vtable.activate(host_api)` to activate the plugin.
//!        c. Tracks `vtable.deactivate(handle)` as the LIFO inverse — so Gluon's
//!           normal unload path calls the plugin's cleanup automatically.
//!
//! ## Lifecycle mapping
//!
//! | Gluon lifecycle  | Dynamic plugin        |
//! |------------------|-----------------------|
//! | `inject` gating  | plugin waits for keys |
//! | `apply` runs     | `vtable.activate()`   |
//! | LIFO rollback    | `vtable.deactivate()` |
//!
//! ## Memory
//!
//! The `ExtLoader` owns the `std.DynLib` handle (keeps the `.so` mapped).
//! Unloading the component does NOT dlclose the library — the vtable pointer
//! must remain valid. Call `ExtLoader.deinit()` to dlclose.
//!
//! The injected/provided key slices are read from the plugin's static metadata
//! at load time and stored in the `Extension` struct (which outlives the
//! Component while the loader is alive).

const std = @import("std");
const abi = @import("gluon_abi.zig");
const host_mod = @import("host.zig");
const comp_mod = @import("../component/component.zig");
const context_mod = @import("../context/context.zig");
const acc_mod = @import("../effect/accumulator.zig");
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

pub const Component = comp_mod.Component;
pub const Context = context_mod.Context;
pub const Key = store_mod.Key;
pub const HostBridge = host_mod.HostBridge;
pub const GluonHostApi = abi.GluonHostApi;
pub const GluonExtVTable = abi.GluonExtVTable;

/// The vtable symbol name Gluon looks up in a loaded `.so`.
pub const VTABLE_SYMBOL = abi.VTABLE_SYMBOL;

// ── Extension: per-loaded-library state ──────────────────────────

/// Holds the resolved vtable + converted key slices for one dynamic plugin.
/// Lives as long as the ExtLoader that created it.
pub const Extension = struct {
    allocator: std.mem.Allocator,
    vtable: *const GluonExtVTable,

    /// Gluon Key slices built from the plugin's meta.inject strings.
    inject_keys: []Key,
    /// Gluon Key slices built from the plugin's meta.provide strings.
    provide_keys: []Key,

    pub fn deinit(self: *Extension) void {
        self.allocator.free(self.inject_keys);
        self.allocator.free(self.provide_keys);
    }

    /// Build a Gluon Component whose lifecycle calls into the dynamic plugin.
    /// The Component borrows `inject_keys` and `provide_keys` from `self` —
    /// `self` must outlive any fiber created from this component.
    pub fn component(self: *Extension) Component {
        return .{
            .inject = self.inject_keys,
            .provide = self.provide_keys,
            .apply = dynApply,
            .provide_witness = .{ .kind = .trivial, .justification = "dynamic plugin: trivial value provision" },
        };
    }

    /// Returns the vtable pointer as a `?*anyopaque` for `loadWithConfig`.
    pub fn vtableConfig(self: *const Extension) ?*anyopaque {
        return @constCast(self.vtable);
    }
};

// ── apply function ────────────────────────────────────────────────
//
// Called by the lifecycle when all inject keys are satisfied.
// We receive the plugin vtable via `config` (passed by ExtLoader.load).

/// Iterator state for dynApply: carries the vtable and the allocated bridge+api.
const ExtIterState = struct {
    vtable: *const GluonExtVTable,
    bridge: *HostBridge,
    /// Heap-allocated so its address is stable for the plugin's lifetime.
    /// Ownership: ExtIterState owns it until next() runs and yields an inverse;
    /// after that, InvState owns it (freed in InvState.dfn).
    host_api: *GluonHostApi,
    /// Whether next() has already been called and yielded a step inverse.
    /// If true, host_api and bridge are owned by the InvState, not by us.
    next_ran: bool = false,
};

fn dynApply(ctx: *Context, config: ?*anyopaque) anyerror!Context.Iterator {
    // config carries a *const GluonExtVTable.
    const vtable: *const GluonExtVTable = @ptrCast(@alignCast(config.?));

    const Iter = struct {
        fn make(a: std.mem.Allocator, vt: *const GluonExtVTable, c: *Context) !Context.Iterator {
            const st = try a.create(ExtIterState);
            errdefer a.destroy(st);

            const bridge = try a.create(HostBridge);
            errdefer a.destroy(bridge);
            bridge.* = .{ .ctx = c, .allocator = a };

            // Heap-allocate the host API so the plugin can safely store its
            // address in its handle for use during deactivate.
            const host_api = try a.create(GluonHostApi);
            errdefer a.destroy(host_api);
            host_api.* = bridge.hostApi();

            st.* = .{ .vtable = vt, .bridge = bridge, .host_api = host_api };
            return .{ .state = st, .next_fn = next, .deinit_fn = deinit };
        }

        fn next(raw: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!effect_iter.Step(Context) {
            const st: *ExtIterState = @ptrCast(@alignCast(raw));

            // Activate the plugin, passing a stable pointer to the host API.
            const handle = st.vtable.activate(st.host_api) orelse {
                return error.ExtActivateFailed;
            };

            // Inverse: deactivate the plugin, then free bridge + host_api.
            const InvState = struct {
                vtable: *const GluonExtVTable,
                handle: *abi.GluonExtHandle,
                bridge: *HostBridge,
                host_api: *GluonHostApi,
            };
            // If InvState alloc fails, deactivate immediately so the plugin
            // doesn't leak its own allocations (e.g. PrinterHandle via c_allocator).
            const inv_st = st.bridge.allocator.create(InvState) catch {
                st.vtable.deactivate(handle);
                return error.OutOfMemory;
            };
            inv_st.* = .{
                .vtable = st.vtable,
                .handle = handle,
                .bridge = st.bridge,
                .host_api = st.host_api,
            };

            const Inv = struct {
                fn call(s: *anyopaque, _: *Context) void {
                    const i: *InvState = @ptrCast(@alignCast(s));
                    i.vtable.deactivate(i.handle);
                }
                fn dfn(s: *anyopaque, a: std.mem.Allocator) void {
                    const i: *InvState = @ptrCast(@alignCast(s));
                    a.destroy(i.host_api);
                    a.destroy(i.bridge);
                    a.destroy(i);
                }
            };

            // Mark that next() ran — ownership of bridge/host_api transferred to InvState.
            st.next_ran = true;

            return .{
                .inverse = .{ .state = inv_st, .call = Inv.call, .deinit = Inv.dfn },
                .done = true,
            };
        }

        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            const st: *ExtIterState = @ptrCast(@alignCast(raw));
            // Free bridge and host_api only if next() never ran.
            // If next() ran, InvState owns them (freed in InvState.dfn).
            if (!st.next_ran) {
                a.destroy(st.host_api);
                a.destroy(st.bridge);
            }
            a.destroy(st);
        }
    };

    return Iter.make(ctx.allocator, vtable, ctx);
}

// ── ExtLoader ─────────────────────────────────────────────────────

pub const LoadError = error{
    /// The `.so` file could not be opened.
    OpenFailed,
    /// The `gluon_plugin_vtable` symbol was not found.
    SymbolNotFound,
    /// `vtable.meta()` returned a valid meta, but key conversion failed.
    OutOfMemory,
};

/// Loads a `.so` / `.dll` / `.dylib` and exposes it as a Gluon Component.
pub const ExtLoader = struct {
    allocator: std.mem.Allocator,
    lib: std.DynLib,
    plugin: Extension,

    /// Open `path`, resolve the vtable, and build key slices from the plugin
    /// metadata. Returns a `ExtLoader` ready to use; call `deinit` to close.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) LoadError!ExtLoader {
        var lib = std.DynLib.open(path) catch return LoadError.OpenFailed;
        errdefer lib.close();

        // Resolve the vtable getter function.
        const VTableFn = *const fn () callconv(.c) *const GluonExtVTable;
        const vtable_fn = lib.lookup(VTableFn, VTABLE_SYMBOL) orelse
            return LoadError.SymbolNotFound;
        const vtable = vtable_fn();
        const meta = vtable.meta();

        // Convert C string key lists to Gluon Key slices.
        const inject_keys = keysFromCList(allocator, meta.inject) catch
            return LoadError.OutOfMemory;
        errdefer allocator.free(inject_keys);
        const provide_keys = keysFromCList(allocator, meta.provide) catch
            return LoadError.OutOfMemory;

        return .{
            .allocator = allocator,
            .lib = lib,
            .plugin = .{
                .allocator = allocator,
                .vtable = vtable,
                .inject_keys = inject_keys,
                .provide_keys = provide_keys,
            },
        };
    }

    /// Close the shared library. Must be called AFTER all fibers created
    /// from this loader's component have been removed (the vtable pointer
    /// must be valid for the lifetime of any active fiber).
    pub fn deinit(self: *ExtLoader) void {
        self.plugin.deinit();
        self.lib.close();
    }

    /// Return a Gluon `Component` that wraps this dynamic plugin.
    /// The `config` pointer passed to `loadWithConfig` must be the vtable:
    ///
    ///   `orch.loadWithConfig(loader.component(), parent, loader.vtableConfig())`
    pub fn pluginComponent(self: *ExtLoader) Component {
        return self.plugin.component();
    }

    /// Returns the vtable pointer as a `?*anyopaque` suitable for
    /// `Orchestrator.loadWithConfig`'s `config` parameter.
    pub fn vtableConfig(self: *const ExtLoader) ?*anyopaque {
        return @constCast(self.plugin.vtable);
    }
};

// ── Helpers ───────────────────────────────────────────────────────

/// Convert a null-terminated array of C strings to Gluon Keys.
/// Exported so `ext_example.zig` can build Extensions from inline vtables
/// without going through ExtLoader.open (no dlopen needed in tests).
pub fn keysFromCList(
    allocator: std.mem.Allocator,
    list: [*:null]const ?[*:0]const u8,
) ![]Key {
    // Count entries.
    var n: usize = 0;
    while (list[n] != null) : (n += 1) {}

    const keys = try allocator.alloc(Key, n);
    for (0..n) |i| {
        const name = abi.cStrSlice(list[i].?);
        keys[i] = host_mod.extServiceKey(name);
    }
    return keys;
}

// ─────────────────────────────── Tests ───────────────────────────
//
// Real dlopen tests require a compiled .so, which build.zig creates as example
// plugins. Here we test the key-conversion helpers and component shape.

test "keysFromCList converts null-terminated C string list to Key slice" {
    const allocator = std.testing.allocator;
    // Static null-terminated array.
    const list = [_:null]?[*:0]const u8{ "foo", "bar", null };
    const keys = try keysFromCList(allocator, &list);
    defer allocator.free(keys);

    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("foo", keys[0].name);
    try std.testing.expectEqualStrings("bar", keys[1].name);
}

test "keysFromCList handles empty list" {
    const allocator = std.testing.allocator;
    const list = [_:null]?[*:0]const u8{null};
    const keys = try keysFromCList(allocator, &list);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "Extension.component returns Component with correct inject/provide lengths" {
    const allocator = std.testing.allocator;

    // Fake vtable (won't be called in this test).
    const fakeVtable = GluonExtVTable{
        .meta = undefined,
        .activate = undefined,
        .deactivate = undefined,
    };

    const inject_list = [_:null]?[*:0]const u8{ "dep.a", null };
    const provide_list = [_:null]?[*:0]const u8{ "svc.b", null };
    const inject_keys = try keysFromCList(allocator, &inject_list);
    const provide_keys = try keysFromCList(allocator, &provide_list);

    var plugin = Extension{
        .allocator = allocator,
        .vtable = &fakeVtable,
        .inject_keys = inject_keys,
        .provide_keys = provide_keys,
    };
    defer plugin.deinit();

    const c = plugin.component();
    try std.testing.expectEqual(@as(usize, 1), c.inject.len);
    try std.testing.expectEqual(@as(usize, 1), c.provide.len);
    try std.testing.expectEqualStrings("dep.a", c.inject[0].name);
    try std.testing.expectEqualStrings("svc.b", c.provide[0].name);
}
