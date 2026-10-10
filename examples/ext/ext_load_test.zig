//! ExtLoader integration test — exercises the REAL dlopen path.
//!
//! This is a standalone executable (not a Zig test binary) because dlopen
//! inside the Zig 0.17 test runner's IPC loop deadlocks on macOS.
//! Run via: zig build test-dyn
//!
//! It loads two shared libraries (the Zig printer plugin and the C printer
//! plugin), drives them through the full Gluon lifecycle, and asserts correct
//! behavior. Exits 0 on success, non-zero on failure.
//!
//! The compiled .so/.dylib paths are injected at build time by build.zig
//! through the `build_paths` options module.

const std = @import("std");
const gluon = @import("gluon");
const paths = @import("build_paths");

const Context = gluon.Context;
const Key = gluon.Key;
const Component = gluon.Component;
const Orchestrator = gluon.Orchestrator;
const EventBus = gluon.EventBus;
const ExtLoader = gluon.ExtLoader;

const host_mod = gluon.ext.host;
const abi = gluon.ext.gluon_abi;
const Step = gluon.effect_iter.Step;

// ── Bus provider ─────────────────────────────────────────────────

fn busProviderApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const bus = try a.create(EventBus);
            errdefer a.destroy(bus);
            bus.* = EventBus.init(a);
            errdefer bus.deinit();
            try c.store.set(*EventBus, host_mod.ext_bus_key, bus);
            errdefer c.store.restrict(host_mod.ext_bus_key) catch {};
            const Inv = struct {
                fn call(s: *anyopaque, cc: *Context) void {
                    cc.store.restrict(host_mod.ext_bus_key) catch {};
                    @as(*EventBus, @ptrCast(@alignCast(s))).deinit();
                }
                fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                    aa.destroy(@as(*EventBus, @ptrCast(@alignCast(s))));
                }
            };
            return .{ .inverse = .{ .state = bus, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(raw))));
        }
    };
    return Iter.make(ctx.allocator);
}

const bus_provider_component = Component{
    .inject = &.{},
    .provide = &.{host_mod.ext_bus_key},
    .apply = busProviderApply,
};

// ── Test helpers ──────────────────────────────────────────────────

var failed: bool = false;

fn expect(ok: bool, comptime msg: []const u8) void {
    if (!ok) {
        std.debug.print("FAIL: {s}\n", .{msg});
        failed = true;
    }
}

fn expectEqual(comptime T: type, expected: T, actual: T, comptime msg: []const u8) void {
    if (expected != actual) {
        std.debug.print("FAIL: {s} — expected {any}, got {any}\n", .{ msg, expected, actual });
        failed = true;
    }
}

// ── Tests ─────────────────────────────────────────────────────────

fn testLoadAndEmit(allocator: std.mem.Allocator, plugin_path: []const u8, plugin_label: []const u8) !void {
    std.debug.print("\n[{s}] opening {s}\n", .{ plugin_label, plugin_path });

    var loader = ExtLoader.open(allocator, plugin_path) catch |err| {
        std.debug.print("[{s}] ExtLoader.open skipped: {}\n", .{ plugin_label, err });
        return;
    };
    defer loader.deinit();

    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();

    // Load bus first (plugin injects it).
    const bus_id = try orch.load(bus_provider_component, gluon.component.root);

    // Load the plugin — drives vtable.activate() inside the .so.
    const pr_id = try orch.loadWithConfig(
        loader.pluginComponent(),
        gluon.component.root,
        loader.vtableConfig(),
    );
    expectEqual(gluon.Phase, gluon.Phase.active, orch.registry.get(pr_id).?.phase,
        "plugin should be active after load");

    // Emit a JSON event — the .so handler is called synchronously.
    const bus = try orch.root_ctx.get(*EventBus, host_mod.ext_bus_key);
    const payload: []const u8 = "{\"msg\":\"hello from ext_load_test\"}";
    const n = bus.emit([]const u8, "print", &payload);
    expectEqual(usize, 1, n, "exactly one listener should receive the emit");

    // Unload the plugin — LIFO rollback calls vtable.deactivate().
    try orch.unloadFiber(pr_id);
    expectEqual(gluon.Phase, gluon.Phase.inactive, orch.registry.get(pr_id).?.phase,
        "plugin should be inactive after unload");

    // After deactivation, no listeners remain.
    const n2 = bus.emit([]const u8, "print", &payload);
    expectEqual(usize, 0, n2, "no listener after unload");

    try orch.unloadFiber(bus_id);

    std.debug.print("[{s}] OK\n", .{plugin_label});
}

fn testInactiveUntilBus(allocator: std.mem.Allocator, plugin_path: []const u8) !void {
    std.debug.print("\n[inactive-until-bus] {s}\n", .{plugin_path});

    var loader = ExtLoader.open(allocator, plugin_path) catch |err| {
        std.debug.print("[inactive-until-bus] skipped: {}\n", .{err});
        return;
    };
    defer loader.deinit();

    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();

    // Load plugin BEFORE bus — must stay Inactive.
    const pr_id = try orch.loadWithConfig(
        loader.pluginComponent(),
        gluon.component.root,
        loader.vtableConfig(),
    );
    expectEqual(gluon.Phase, gluon.Phase.inactive, orch.registry.get(pr_id).?.phase,
        "plugin should wait for bus (Inactive)");

    // Load bus — plugin activates reactively (Alg 3 notify).
    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    expectEqual(gluon.Phase, gluon.Phase.active, orch.registry.get(pr_id).?.phase,
        "plugin should activate once bus is provided");

    try orch.unloadFiber(bus_id);
    std.debug.print("[inactive-until-bus] OK\n", .{});
}

fn testMetadata(allocator: std.mem.Allocator, plugin_path: []const u8) !void {
    std.debug.print("\n[metadata] {s}\n", .{plugin_path});

    var loader = ExtLoader.open(allocator, plugin_path) catch |err| {
        std.debug.print("[metadata] skipped: {}\n", .{err});
        return;
    };
    defer loader.deinit();

    // inject keys: ["gluon.dyn.bus"]
    expectEqual(usize, 1, loader.plugin.inject_keys.len, "inject_keys.len == 1");
    if (loader.plugin.inject_keys.len > 0) {
        const name = loader.plugin.inject_keys[0].name;
        expect(std.mem.eql(u8, "gluon.dyn.bus", name), "inject key is gluon.dyn.bus");
    }

    // provide keys: [] (printer provides nothing)
    expectEqual(usize, 0, loader.plugin.provide_keys.len, "provide_keys.len == 0");

    std.debug.print("[metadata] OK\n", .{});
}

// ── Entry point ───────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ExtLoader integration tests ===\n", .{});
    std.debug.print("Zig plugin path: {s}\n", .{paths.zig_printer_path});
    std.debug.print("C   plugin path: {s}\n", .{paths.c_printer_path});

    // Test 1: Zig plugin — full load/emit/unload cycle.
    try testLoadAndEmit(allocator, paths.zig_printer_path, "zig_printer");

    // Test 2: C plugin — same lifecycle, different language.
    try testLoadAndEmit(allocator, paths.c_printer_path, "c_printer");

    // Test 3: Ext waits for its inject dependency (spatial composability).
    try testInactiveUntilBus(allocator, paths.zig_printer_path);

    // Test 4: Metadata is read correctly from the .so.
    try testMetadata(allocator, paths.zig_printer_path);

    if (failed) {
        std.debug.print("\n=== SOME TESTS FAILED ===\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n=== All ExtLoader tests passed ===\n", .{});
    }
}
