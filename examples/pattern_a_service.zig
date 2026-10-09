//! Pattern A — Service via the coeffect store.
//!
//! One plugin PROVIDES a Printer service (a function-pointer struct) into the
//! shared store. Other plugins INJECT that key and call through it — with zero
//! knowledge of the printer's implementation.
//!
//! Topology:
//!
//!   printer_plugin   provide "app.printer"
//!        │
//!   logger_plugin    inject  "app.printer"   (waits until printer is active)
//!   audit_plugin     inject  "app.printer"   (also waits; independent consumer)
//!
//! What this demonstrates:
//!
//!   • Service pattern: a struct carrying a function pointer is the "service
//!     object". The key encodes both the name AND the type — there is no
//!     separate type-registration step.
//!
//!   • Interface decoupling: consumers import only the shared key + struct
//!     definition. They never import the printer's implementation.
//!
//!   • Spatial composability (Thm 70): logger and audit stay Inactive until
//!     printer activates. Load order is irrelevant — Gluon sorts it out.
//!
//!   • Temporal composability (Thm 7 / Cor 69): unloading the printer
//!     deactivates both consumers FIRST (drainDependents), then withdraws the
//!     Printer struct from the store and frees its heap allocation. No
//!     dangling pointers.
//!
//!   • Hot-swap (§5.2.2 HMR): replacing the printer with a different
//!     implementation re-activates consumers with the new one automatically.

const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;
const Component = gluon.Component;
const Orchestrator = gluon.Orchestrator;
const Step = gluon.effect_iter.Step;

// ── Shared API contract ───────────────────────────────────────────
//
// In a real project this lives in a tiny `print_api.zig` that both the
// provider and every consumer import. Both sides agree on the struct shape
// and the key name; neither side imports the other's implementation.

/// The service object: a vtable-style struct carrying a function pointer.
/// The consumer calls `printer.print(printer.state, msg)` — it never needs
/// to know what "printing" means concretely.
pub const Printer = struct {
    state: *anyopaque,
    print: *const fn (state: *anyopaque, msg: []const u8) void,
};

/// The coeffect key. `Key.of` encodes BOTH the name AND the value type
/// (*const Printer), so a consumer that tries to read the wrong type gets a
/// TypeMismatch, not a silent miscast.
pub const printer_key = Key.of(*const Printer, "app.printer");

// ── Scripted output sink (used by tests) ─────────────────────────
//
// In main() the concrete Printer points to a real stdout writer.
// In tests it points to this capturing Sink. The plugins are agnostic.

pub const Sink = struct {
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Sink {
        return .{ .lines = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *Sink) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
    // printFn is used as a function pointer — must be a module-level fn.
    pub fn printFn(state: *anyopaque, msg: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(state));
        const copy = self.allocator.dupe(u8, msg) catch return;
        self.lines.append(self.allocator, copy) catch self.allocator.free(copy);
    }
    pub fn printer(self: *Sink) Printer {
        return .{ .state = self, .print = printFn };
    }
    pub fn last(self: *const Sink) ?[]const u8 {
        if (self.lines.items.len == 0) return null;
        return self.lines.items[self.lines.items.len - 1];
    }
};

// ── printer_plugin ────────────────────────────────────────────────
//
// Provides "app.printer". The concrete *Printer handle (stdout in main(),
// capturing Sink in tests) is passed as a type-erased config pointer via
// loadWithConfig. The plugin itself is output-agnostic.
//
// Because Zig nested functions cannot capture outer variables, the config
// pointer is threaded through the iterator STATE struct so that `next` can
// read it without closure.

fn printerApply(ctx: *Context, config: ?*anyopaque) anyerror!Context.Iterator {
    // The iterator state carries the config pointer so `next` can read it
    // without capturing the outer variable (Zig: no closures over fn frames).
    const IterState = struct {
        impl: *const Printer,
    };

    const Iter = struct {
        fn make(a: std.mem.Allocator, impl: *const Printer) !Context.Iterator {
            const st = try a.create(IterState);
            st.* = .{ .impl = impl };
            return .{ .state = st, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(raw: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const st: *IterState = @ptrCast(@alignCast(raw));
            const impl: *const Printer = st.impl;

            // Store the impl pointer itself as the service value.
            // The inverse only needs to restrict the key; the Printer struct is
            // owned by the caller (via config) and outlives the fiber.
            try c.store.set(*const Printer, printer_key, impl);
            errdefer c.store.restrict(printer_key) catch {};

            // Inverse: just withdraw the key from the store.
            const Inv = struct {
                fn call(_: *anyopaque, cc: *Context) void {
                    cc.store.restrict(printer_key) catch {};
                }
                fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
            };
            return .{
                .inverse = .{ .state = undefined, .call = Inv.call, .deinit = Inv.dfn },
                .done = true,
            };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*IterState, @ptrCast(@alignCast(raw))));
        }
    };

    const impl: *const Printer = @ptrCast(@alignCast(config.?));
    return Iter.make(ctx.allocator, impl);
}

pub const printer_component = Component{
    .inject = &.{},
    .provide = &.{printer_key},
    .apply = printerApply,
};

// ── logger_plugin ─────────────────────────────────────────────────
//
// Consumes "app.printer". On activation reads the Printer from the store and
// sends one line. Stays Inactive until the printer is provided.
// Printing is a §6.1 emission (irreversible); the step inverse is a no-op.

fn loggerApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            // Read the Printer from the store.
            // No import of the printer plugin — the key carries the type contract.
            const p = try c.get(*const Printer, printer_key);
            p.print(p.state, "[logger] Logger plugin activated.");

            const Noop = struct {
                fn call(_: *anyopaque, _: *Context) void {}
                fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
            };
            return .{
                .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn },
                .done = true,
            };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(raw))));
        }
    };
    return Iter.make(ctx.allocator);
}

pub const logger_component = Component{
    .inject = &.{printer_key}, // ← stays Inactive until "app.printer" is active
    .provide = &.{},
    .apply = loggerApply,
};

// ── audit_plugin ──────────────────────────────────────────────────
//
// A second, independent consumer of "app.printer". Sends a different message.
// Neither logger nor audit know about each other; they only share the key.

fn auditApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const p = try c.get(*const Printer, printer_key);
            p.print(p.state, "[audit]  Audit plugin activated.");

            const Noop = struct {
                fn call(_: *anyopaque, _: *Context) void {}
                fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
            };
            return .{
                .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn },
                .done = true,
            };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(raw))));
        }
    };
    return Iter.make(ctx.allocator);
}

pub const audit_component = Component{
    .inject = &.{printer_key},
    .provide = &.{},
    .apply = auditApply,
};

// ── main() ───────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Real stdout printer. Module-level fn so it can be used as a fn pointer.
    const stdout_printer = Printer{
        .state = undefined,
        .print = struct {
            fn print(_: *anyopaque, msg: []const u8) void {
                std.io.getStdOut().writer().print("{s}\n", .{msg}) catch {};
            }
        }.print,
    };

    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();

    // Load consumers first — they stay Inactive until the printer arrives.
    _ = try orch.load(logger_component, gluon.component.root);
    _ = try orch.load(audit_component, gluon.component.root);

    // Load printer — both consumers activate reactively and print their lines.
    _ = try orch.loadWithConfig(
        printer_component,
        gluon.component.root,
        @constCast(&stdout_printer),
    );
}

// ── Tests ─────────────────────────────────────────────────────────

test "Pattern A: consumers stay Inactive until printer activates" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var p = sink.printer();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load consumers first — no printer yet.
    const logger_id = try orch.load(logger_component, gluon.component.root);
    const audit_id = try orch.load(audit_component, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(audit_id).?.phase);
    try std.testing.expectEqual(@as(usize, 0), sink.lines.items.len); // nothing printed yet

    // Load printer — both consumers activate and print their messages.
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&p));
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(audit_id).?.phase);
    try std.testing.expectEqual(@as(usize, 2), sink.lines.items.len);
}

test "Pattern A: both consumers receive the printer and print their messages" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var p = sink.printer();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    _ = try orch.load(logger_component, gluon.component.root);
    _ = try orch.load(audit_component, gluon.component.root);
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&p));

    var found_logger = false;
    var found_audit = false;
    for (sink.lines.items) |line| {
        if (std.mem.eql(u8, line, "[logger] Logger plugin activated.")) found_logger = true;
        if (std.mem.eql(u8, line, "[audit]  Audit plugin activated.")) found_audit = true;
    }
    try std.testing.expect(found_logger);
    try std.testing.expect(found_audit);
}

test "Pattern A: unloading printer deactivates both consumers first (Thm 70)" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var p = sink.printer();

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const logger_id = try orch.load(logger_component, gluon.component.root);
    const audit_id = try orch.load(audit_component, gluon.component.root);
    const printer_id = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&p));

    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(audit_id).?.phase);
    try std.testing.expect(orch.isProvided(printer_key));

    // Unload printer: Gluon drains consumers first, then rolls back the printer.
    try orch.unloadFiber(printer_id);

    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(audit_id).?.phase);
    // LIFO rollback withdrew the key — no dangling pointer in the store.
    try std.testing.expect(!orch.isProvided(printer_key));
    try std.testing.expect(!orch.root_ctx.has(printer_key));
}

test "Pattern A: hot-swap printer — consumers reactivate with new implementation" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();

    // Two concrete print functions: v1 tags lines with "[v1]", v2 with "[v2]".
    const V1 = struct {
        fn print(state: *anyopaque, msg: []const u8) void {
            const s: *Sink = @ptrCast(@alignCast(state));
            var buf: [256]u8 = undefined;
            const tagged = std.fmt.bufPrint(&buf, "[v1] {s}", .{msg}) catch return;
            const copy = s.allocator.dupe(u8, tagged) catch return;
            s.lines.append(s.allocator, copy) catch s.allocator.free(copy);
        }
    };
    const V2 = struct {
        fn print(state: *anyopaque, msg: []const u8) void {
            const s: *Sink = @ptrCast(@alignCast(state));
            var buf: [256]u8 = undefined;
            const tagged = std.fmt.bufPrint(&buf, "[v2] {s}", .{msg}) catch return;
            const copy = s.allocator.dupe(u8, tagged) catch return;
            s.lines.append(s.allocator, copy) catch s.allocator.free(copy);
        }
    };

    var pv1 = Printer{ .state = &sink, .print = V1.print };
    var pv2 = Printer{ .state = &sink, .print = V2.print };

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const logger_id = try orch.load(logger_component, gluon.component.root);
    const audit_id = try orch.load(audit_component, gluon.component.root);

    // Load v1 — consumers activate and print with [v1] prefix.
    const printer_id_v1 = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&pv1));
    const lines_after_v1 = sink.lines.items.len;
    try std.testing.expect(lines_after_v1 >= 2);
    for (sink.lines.items[0..lines_after_v1]) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "[v1]"));
    }

    // Retire and remove v1 — consumers deactivate.
    try orch.unloadFiber(printer_id_v1);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(audit_id).?.phase);
    try orch.removeFiber(printer_id_v1); // release the provision slot for reuse

    // Load v2 — consumers reactivate and print with [v2] prefix.
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&pv2));
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(logger_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(audit_id).?.phase);
    for (sink.lines.items[lines_after_v1..]) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "[v2]"));
    }
}

test "Pattern A: OOM safety — full scenario leaks nothing on any allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var sink = Sink.init(allocator);
            defer sink.deinit();
            var p = sink.printer();

            var orch = try Orchestrator.init(allocator);
            defer orch.deinit();

            _ = try orch.load(logger_component, gluon.component.root);
            _ = try orch.load(audit_component, gluon.component.root);
            const printer_id = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&p));
            try orch.unloadFiber(printer_id);
            try orch.removeFiber(printer_id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
