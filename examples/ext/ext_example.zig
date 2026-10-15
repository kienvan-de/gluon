//! Dynamic plugin end-to-end example.
//!
//! Exercises Pattern A (opaque service via store) and Pattern B (pub/sub via
//! EventBus) using the dynplugin subsystem — WITHOUT dlopen (to avoid a
//! compiled-shared-library dependency in the test suite). Instead, the example
//! builds plugin vtables inline, exactly as `ext_printer.zig` / `ext_greeter.zig`
//! would export them from a real `.so`. This proves the entire ABI bridge works
//! without requiring a separate build step for the `.so` files.
//!
//! For real dlopen usage see `ExtLoader` in `src/dynplugin/ext_loader.zig` and
//! the example plugins in `examples/ext_plugins/`.
//!
//! What this tests:
//!
//!   • The C ABI contract (`GluonExtVTable` / `GluonHostApi`) works
//!     end-to-end within the Gluon orchestration lifecycle.
//!   • A dynamic plugin that subscribes to events has its listener removed
//!     automatically when the plugin deactivates (Def 8 / LIFO rollback).
//!   • A dynamic plugin that provides an opaque service has that service
//!     withdrawn and its free_fn called on deactivation (two-inverse pattern).
//!   • Spatial composability: plugins wait for their declared inject keys.
//!   • Temporal composability: unloading a provider deactivates dependents first.

const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;
const Component = gluon.Component;
const Orchestrator = gluon.Orchestrator;
const EventBus = gluon.EventBus;

const abi = gluon.ext.gluon_abi;
const host_mod = gluon.ext.host;
const ext_loader = gluon.ext.loader;

const GluonExtVTable = abi.GluonExtVTable;
const GluonExtMeta = abi.GluonExtMeta;
const GluonHostApi = abi.GluonHostApi;
const GluonExtHandle = abi.GluonExtHandle;
const ExtService = abi.ExtService;
const Extension = ext_loader.Extension;

// ── Shared bus provider (needed by both patterns) ──────────────────
//
// Same bus_provider_component from pattern_b_eventbus.zig.

const Step = gluon.effect_iter.Step;

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

// ── Inline vtable helpers ──────────────────────────────────────────
//
// These mirror what `ext_printer.zig` and `ext_greeter.zig` export from a .so.
// They are defined at module scope (not inside test blocks) so their addresses
// are stable function pointers usable in vtable structs.

// ── Pattern B: inline "ext_printer" vtable ────────────────────────

const PrinterInject = [_:null]?[*:0]const u8{ "gluon.dyn.bus", null };
const PrinterProvide = [_:null]?[*:0]const u8{null};
const PrinterMeta = GluonExtMeta{
    .name = "ext_printer",
    .inject = &PrinterInject,
    .provide = &PrinterProvide,
};

/// Captured output for the printer (filled by onPrint).
pub const PrinterSink = struct {
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PrinterSink {
        return .{ .lines = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *PrinterSink) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
    pub fn record(self: *PrinterSink, msg: []const u8) void {
        const copy = self.allocator.dupe(u8, msg) catch return;
        self.lines.append(self.allocator, copy) catch self.allocator.free(copy);
    }
};

/// Handler registered by the printer. State = *PrinterSink.
fn printerOnPrint(state: ?*anyopaque, json: [*:0]const u8) callconv(.c) void {
    const sink: *PrinterSink = @ptrCast(@alignCast(state.?));
    sink.record(std.mem.span(json));
}

const PrinterHandle = struct { token: abi.GluonSubToken, host: *const GluonHostApi };

fn printerMeta() callconv(.c) *const GluonExtMeta {
    return &PrinterMeta;
}
fn printerActivate(host: *const GluonHostApi) callconv(.c) ?*GluonExtHandle {
    // The sink pointer is passed via config (the vtable is called with a
    // host whose ctx carries the sink via the bridge's fiber config).
    // But vtable.activate only receives host — not config. So we need to
    // thread the sink another way. Use the subscribe `state` parameter:
    // the bridge's ctx carries the sink in its store under a well-known key.
    // Simpler: use a module-level pointer that the test sets before loading.
    const sink = g_printer_sink orelse return null;
    const h = std.heap.c_allocator.create(PrinterHandle) catch return null;
    const tok = host.subscribe(host.ctx, "print", printerOnPrint, sink);
    h.* = .{ .token = tok, .host = host };
    return @ptrCast(h);
}
fn printerDeactivate(raw: *GluonExtHandle) callconv(.c) void {
    const h: *PrinterHandle = @ptrCast(@alignCast(raw));
    h.host.unsubscribe(h.host.ctx, h.token);
    std.heap.c_allocator.destroy(h);
}

/// Test-global sink pointer. Set by the test before loading the printer plugin.
var g_printer_sink: ?*PrinterSink = null;

const printer_vtable = GluonExtVTable{
    .meta = printerMeta,
    .activate = printerActivate,
    .deactivate = printerDeactivate,
};

// ── Pattern A: inline "ext_greeter" vtable ────────────────────────

const GreeterInject = [_:null]?[*:0]const u8{null};
const GreeterProvide = [_:null]?[*:0]const u8{ "greeter.service", null };
const GreeterMeta = GluonExtMeta{
    .name = "ext_greeter",
    .inject = &GreeterInject,
    .provide = &GreeterProvide,
};

/// The C ABI service struct the greeter exposes (mirrors ext_greeter.zig).
pub const GreeterService = extern struct {
    greet: *const fn (name: [*:0]const u8) callconv(.c) void,
};

fn greetFn(name: [*:0]const u8) callconv(.c) void {
    if (g_greet_sink) |sink| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Hello, {s}!", .{std.mem.span(name)}) catch return;
        sink.record(msg);
    }
}
var g_greet_sink: ?*PrinterSink = null;

const static_greeter_svc = GreeterService{ .greet = greetFn };

fn greeterMeta() callconv(.c) *const GluonExtMeta {
    return &GreeterMeta;
}
const GreeterHandle = struct { host: *const GluonHostApi };
fn greeterActivate(host: *const GluonHostApi) callconv(.c) ?*GluonExtHandle {
    const h = std.heap.c_allocator.create(GreeterHandle) catch return null;
    h.* = .{ .host = host };
    const rc = host.provide_opaque(
        host.ctx,
        "greeter.service",
        @constCast(&static_greeter_svc),
        null, // no free needed (static)
    );
    if (rc != 0) {
        std.heap.c_allocator.destroy(h);
        return null;
    }
    return @ptrCast(h);
}
fn greeterDeactivate(raw: *GluonExtHandle) callconv(.c) void {
    const h: *GreeterHandle = @ptrCast(@alignCast(raw));
    h.host.withdraw_opaque(h.host.ctx, "greeter.service");
    std.heap.c_allocator.destroy(h);
}

const greeter_vtable = GluonExtVTable{
    .meta = greeterMeta,
    .activate = greeterActivate,
    .deactivate = greeterDeactivate,
};

// ── Extension builder from inline vtable ──────────────────────────

/// Build a Extension (and thus a Gluon Component) directly from an inline
/// vtable — no dlopen needed. This is what ExtLoader.open() does internally.
fn pluginFromVtable(allocator: std.mem.Allocator, vtable: *const GluonExtVTable) !Extension {
    const meta = vtable.meta();
    const inject_keys = try ext_loader.keysFromCList(allocator, meta.inject);
    errdefer allocator.free(inject_keys);
    const provide_keys = try ext_loader.keysFromCList(allocator, meta.provide);
    return Extension{
        .allocator = allocator,
        .vtable = vtable,
        .inject_keys = inject_keys,
        .provide_keys = provide_keys,
        .provide_witness = ext_loader.witnessFromMeta(meta.commutativity),
    };
}

// ── Host bridge component wrapper ─────────────────────────────────
//
// When a Extension activates, its `apply` function (dynApply in ext_loader.zig)
// creates a HostBridge, fills the GluonHostApi, and calls vtable.activate.
// We use Extension.component() which returns a Component backed by dynApply.

// ── Tests ─────────────────────────────────────────────────────────

test "Pattern B (dynamic): printer plugin subscribes, producer emits JSON" {
    var sink = PrinterSink.init(std.testing.allocator);
    defer sink.deinit();
    g_printer_sink = &sink;
    defer g_printer_sink = null;

    // Build Extension for the printer (inline vtable, no dlopen).
    var printer_plugin = try pluginFromVtable(std.testing.allocator, &printer_vtable);
    defer printer_plugin.deinit();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // 1. Load bus (printer waits for it).
    const bus_id = try orch.load(bus_provider_component, gluon.component.root);

    // 2. Load printer plugin (activates immediately — bus is already provided).
    //    Pass the vtable pointer as config so dynApply can call activate.
    const pr_id = try orch.loadWithConfig(
        printer_plugin.component(),
        gluon.component.root,
        printer_plugin.vtableConfig(),
    );
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(pr_id).?.phase);

    // 3. Emit a JSON string via the shared EventBus.
    //    In a real scenario this would be done by another plugin; here we
    //    emit from the native side to demonstrate full round-trip.
    const bus = try orch.root_ctx.get(*EventBus, host_mod.ext_bus_key);
    const payload: []const u8 = "{\"msg\":\"hello from test\"}";
    _ = bus.emit([]const u8, "print", &payload);

    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);
    try std.testing.expectEqualStrings("{\"msg\":\"hello from test\"}", sink.lines.items[0]);

    // 4. Unload printer: bus.off called automatically via LIFO rollback.
    try orch.unloadFiber(pr_id);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(pr_id).?.phase);

    // After unload, emitting reaches no listener.
    _ = bus.emit([]const u8, "print", &payload);
    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len); // still 1

    try orch.unloadFiber(bus_id);
}

test "Pattern B (dynamic): plugin stays Inactive until bus is provided" {
    var sink = PrinterSink.init(std.testing.allocator);
    defer sink.deinit();
    g_printer_sink = &sink;
    defer g_printer_sink = null;

    var printer_plugin = try pluginFromVtable(std.testing.allocator, &printer_vtable);
    defer printer_plugin.deinit();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load printer BEFORE bus — must stay Inactive.
    const pr_id = try orch.loadWithConfig(
        printer_plugin.component(),
        gluon.component.root,
        printer_plugin.vtableConfig(),
    );
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(pr_id).?.phase);

    // Load bus — printer activates reactively.
    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(pr_id).?.phase);

    try orch.unloadFiber(bus_id);
}

test "Pattern A (dynamic): greeter plugin provides opaque service" {
    var sink = PrinterSink.init(std.testing.allocator);
    defer sink.deinit();
    g_greet_sink = &sink;
    defer g_greet_sink = null;

    var greeter_plugin = try pluginFromVtable(std.testing.allocator, &greeter_vtable);
    defer greeter_plugin.deinit();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load greeter (no dependencies — activates immediately).
    const gr_id = try orch.loadWithConfig(
        greeter_plugin.component(),
        gluon.component.root,
        greeter_plugin.vtableConfig(),
    );
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(gr_id).?.phase);

    // Read the opaque service from the store.
    const svc_key = gluon.extServiceKey("greeter.service");
    try std.testing.expect(orch.root_ctx.has(svc_key));
    const ext_svc = try orch.root_ctx.get(*const ExtService, svc_key);

    // Cast to the agreed-upon C ABI struct and call through it.
    const greeter: *const GreeterService = @ptrCast(@alignCast(ext_svc.ptr));
    greeter.greet("World");

    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);
    try std.testing.expectEqualStrings("Hello, World!", sink.lines.items[0]);

    // Unload greeter: service withdrawn automatically by LIFO rollback.
    try orch.unloadFiber(gr_id);
    try std.testing.expect(!orch.root_ctx.has(svc_key));
}

// ── Module-level key used by the consumer-waits test ─────────────
const greeter_svc_key = gluon.extServiceKey("greeter.service");

test "Pattern A (dynamic): consumer stays Inactive until greeter activates" {
    // A native Zig component that injects "greeter.service".
    const ConsumerKeys = struct {
        const keys = [_]Key{greeter_svc_key};
    };
    const consumer_cmp = Component{
        .inject = &ConsumerKeys.keys,
        .provide = &.{},
        .apply = struct {
            fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
                const Iter = struct {
                    fn make(a: std.mem.Allocator) !Context.Iterator {
                        const s = try a.create(@This());
                        s.* = .{};
                        return .{ .state = s, .next_fn = next, .deinit_fn = deinit };
                    }
                    fn next(_: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!Step(Context) {
                        const Noop = struct {
                            fn call(_: *anyopaque, _: *Context) void {}
                            fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
                        };
                        return .{ .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn }, .done = true };
                    }
                    fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                        a.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
                    }
                };
                return Iter.make(ctx.allocator);
            }
        }.apply,
    };

    var greeter_plugin = try pluginFromVtable(std.testing.allocator, &greeter_vtable);
    defer greeter_plugin.deinit();
    g_greet_sink = null;

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load consumer first — waits for "greeter.service".
    const con_id = try orch.load(consumer_cmp, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(con_id).?.phase);

    // Load greeter — consumer activates reactively.
    const gr_id = try orch.loadWithConfig(
        greeter_plugin.component(),
        gluon.component.root,
        greeter_plugin.vtableConfig(),
    );
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(con_id).?.phase);

    // Unload greeter — consumer deactivates first (Thm 70), then greeter rolls back.
    try orch.unloadFiber(gr_id);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(con_id).?.phase);
    try std.testing.expect(!orch.root_ctx.has(greeter_svc_key));
}

test "dynamic plugin OOM safety: full lifecycle leaks nothing on any allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var sink = PrinterSink.init(allocator);
            defer sink.deinit();
            g_printer_sink = &sink;
            defer g_printer_sink = null;

            var printer_plugin = try pluginFromVtable(allocator, &printer_vtable);
            defer printer_plugin.deinit();

            var orch = try Orchestrator.init(allocator);
            defer orch.deinit();

            const bus_id = try orch.load(bus_provider_component, gluon.component.root);
            const pr_id = try orch.loadWithConfig(
                printer_plugin.component(),
                gluon.component.root,
                printer_plugin.vtableConfig(),
            );
            try orch.unloadFiber(pr_id);
            try orch.removeFiber(pr_id);
            try orch.unloadFiber(bus_id);
            try orch.removeFiber(bus_id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
