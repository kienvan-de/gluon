//! Pattern B — Pub/Sub via the EventBus (§3.4.2 tagged registry).
//!
//! The printer plugin SUBSCRIBES to a "print" event on a shared bus.
//! Any other plugin EMITS strings to that event at any time after activation —
//! without knowing anything about the printer or even whether it is loaded.
//!
//! Topology:
//!
//!   bus_provider     provide "app.bus"       (creates and provisions the bus)
//!        │
//!   printer_plugin   inject  "app.bus"       (subscribes on activation,
//!        │                                    unsubscribes on deactivation)
//!   producer_a       inject  "app.bus"       (stores bus ref; emits on demand)
//!   producer_b       inject  "app.bus"       (same)
//!
//! Producers and printer are peers — neither imports the other. They share
//! only the bus key name and the payload type ([]const u8).
//!
//! The key design point for pub/sub:
//!   Producers do NOT emit on activation. Instead they expose a send() fn
//!   that the host can call at any time. This is the real-world pattern:
//!   a plugin registers with the bus as a means to broadcast later events
//!   (button clicks, data ready, errors, etc.) — not as a one-shot fire.
//!
//! What this demonstrates:
//!
//!   • Pub/sub decoupling: producers call bus.emit(); the printer's handler is
//!     invoked synchronously inline. No queue, no thread — direct dispatch.
//!
//!   • Revertible subscription (Def 8): ctx.on() tracks bus.off() as the
//!     inverse on the printer's context accumulator. Unloading the printer
//!     automatically removes its listener — no manual cleanup.
//!
//!   • Tagged-registry commutativity (§3.4.2 / Thm 47): every bus.on() gets
//!     a unique tag, so multiple printer instances are independent effects.
//!
//!   • Spatial composability (Thm 70): all plugins wait for "app.bus" before
//!     activating.
//!
//!   • Temporal composability (Cor 69): unloading the printer removes its
//!     listener; later emits reach nobody. Unloading the bus deactivates
//!     everyone first (drainDependents), then the bus is freed.

const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;
const Component = gluon.Component;
const Orchestrator = gluon.Orchestrator;
const EventBus = gluon.EventBus;
const Handler = gluon.Handler;
const Step = gluon.effect_iter.Step;

// ── Shared API contract ───────────────────────────────────────────
//
// In a real project this is a tiny `print_bus_api.zig` everyone imports.
// Producers and the printer agree on:
//   1. The bus key name/type.
//   2. The event name string.
//   3. The payload type ([]const u8).
// Nothing else is shared between them.

pub const bus_key = Key.of(*EventBus, "app.bus");
pub const print_event = "print";

// ── Output sink (replaces real stdout in tests) ───────────────────

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
    pub fn record(self: *Sink, msg: []const u8) void {
        const copy = self.allocator.dupe(u8, msg) catch return;
        self.lines.append(self.allocator, copy) catch self.allocator.free(copy);
    }
    pub fn last(self: *const Sink) ?[]const u8 {
        if (self.lines.items.len == 0) return null;
        return self.lines.items[self.lines.items.len - 1];
    }
};

// ── bus_provider ──────────────────────────────────────────────────
//
// Creates an EventBus, provisions it under bus_key. All other plugins depend
// on this key, so the bus_provider is the root of the dependency tree.
//
// The EventBus must outlive every context that subscribed to it (its disposer
// calls bus.off during recover). Theorem 70 guarantees this: a provider only
// deactivates AFTER all its dependents have deactivated (drainDependents).
// So by the time the bus inverse runs bus.deinit(), all bus.off() calls have
// already been made.

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

            try c.store.set(*EventBus, bus_key, bus);
            errdefer c.store.restrict(bus_key) catch {};

            // Inverse: withdraw the key, deinit the bus, free the allocation.
            const Inv = struct {
                fn call(s: *anyopaque, cc: *Context) void {
                    cc.store.restrict(bus_key) catch {};
                    const b: *EventBus = @ptrCast(@alignCast(s));
                    b.deinit();
                }
                fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                    aa.destroy(@as(*EventBus, @ptrCast(@alignCast(s))));
                }
            };
            return .{
                .inverse = .{ .state = bus, .call = Inv.call, .deinit = Inv.dfn },
                .done = true,
            };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(raw))));
        }
    };
    return Iter.make(ctx.allocator);
}

pub const bus_provider_component = Component{
    .inject = &.{},
    .provide = &.{bus_key},
    .apply = busProviderApply,
};

// ── printer_plugin ────────────────────────────────────────────────
//
// Subscribes to "print" events on activation. Uses ctx.on() which:
//   1. Calls bus.on() to register the listener and returns a Subscription.
//   2. Tracks bus.off(sub) as an inverse on this context's accumulator.
//
// When the printer is unloaded, the LIFO rollback calls bus.off(sub)
// automatically — no manual cleanup. This is Definition 8 in action.

fn sinkHandlerFn(state: *anyopaque, payload: *const anyopaque) void {
    const sink: *Sink = @ptrCast(@alignCast(state));
    const msg: *const []const u8 = @ptrCast(@alignCast(payload));
    sink.record(msg.*);
}

fn printerApply(ctx: *Context, config: ?*anyopaque) anyerror!Context.Iterator {
    const IterState = struct { sink: *Sink };

    const Iter = struct {
        fn make(a: std.mem.Allocator, sink: *Sink) !Context.Iterator {
            const st = try a.create(IterState);
            st.* = .{ .sink = sink };
            return .{ .state = st, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(raw: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const st: *IterState = @ptrCast(@alignCast(raw));
            const h = Handler{ .state = st.sink, .call = sinkHandlerFn };

            // ctx.on() registers the listener AND tracks bus.off as an inverse.
            _ = try c.on([]const u8, bus_key, print_event, h);

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
            a.destroy(@as(*IterState, @ptrCast(@alignCast(raw))));
        }
    };

    const sink: *Sink = @ptrCast(@alignCast(config.?));
    return Iter.make(ctx.allocator, sink);
}

pub const printer_component = Component{
    .inject = &.{bus_key},
    .provide = &.{},
    .apply = printerApply,
};

// ── Producer: a plugin that holds a bus reference and emits on demand ────────
//
// A producer injects the bus, stores a REFERENCE to it in its state, and
// exposes a send() function the host calls at any time. This is the real
// pub/sub pattern: the plugin sets up the pipe once on activation; the host
// drives data through it.
//
// The producer does NOT emit on activation — that would race with the printer
// subscribing (if printer and producer happen to be peers with the same
// dependency, activation order is not guaranteed between them).

pub const ProducerState = struct {
    bus: ?*EventBus = null, // set on activation, cleared on deactivation

    /// Send a message to all "print" listeners on the bus.
    /// Only works while the producer is active (bus != null).
    pub fn send(self: *ProducerState, msg: []const u8) void {
        const b = self.bus orelse return;
        _ = b.emit([]const u8, print_event, &msg);
    }
};

fn makeProducerApply(state: *ProducerState) gluon.component.Apply {
    _ = state; // state passed via config (not closure — Zig has no closures)
    unreachable;
}

// Thread state through the iterator via config.
fn producerApply(ctx: *Context, config: ?*anyopaque) anyerror!Context.Iterator {
    const IterState = struct { producer: *ProducerState };

    const Iter = struct {
        fn make(a: std.mem.Allocator, producer: *ProducerState) !Context.Iterator {
            const st = try a.create(IterState);
            st.* = .{ .producer = producer };
            return .{ .state = st, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(raw: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const st: *IterState = @ptrCast(@alignCast(raw));

            // Read the bus from the store and store it in the producer state.
            st.producer.bus = try c.store.get(*EventBus, bus_key);

            // Inverse: clear the bus reference on deactivation.
            const Inv = struct {
                fn call(s: *anyopaque, _: *Context) void {
                    const p: *ProducerState = @ptrCast(@alignCast(s));
                    p.bus = null;
                }
                fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
            };
            return .{
                .inverse = .{ .state = st.producer, .call = Inv.call, .deinit = Inv.dfn },
                .done = true,
            };
        }
        fn deinit(raw: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*IterState, @ptrCast(@alignCast(raw))));
        }
    };

    const producer: *ProducerState = @ptrCast(@alignCast(config.?));
    return Iter.make(ctx.allocator, producer);
}

pub const producer_component = Component{
    .inject = &.{bus_key},
    .provide = &.{},
    .apply = producerApply,
};

// ── main() ───────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_sink = Sink.init(allocator);
    defer stdout_sink.deinit();

    var producer_a = ProducerState{};
    var producer_b = ProducerState{};

    var orch = try Orchestrator.init(allocator);
    defer orch.deinit();

    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&stdout_sink));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&producer_a));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&producer_b));

    // Host drives messages through the producers at any point after activation.
    producer_a.send("Hello from producer A!");
    producer_b.send("Hello from producer B!");

    // Ordered teardown: retire the bus last so Theorem 70 drains all subscribers.
    try orch.unloadFiber(bus_id);
}

// ── Tests ─────────────────────────────────────────────────────────

test "Pattern B: all plugins wait for bus_provider before activating" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var prod = ProducerState{};

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    // Load printer and producer first — both wait for the bus.
    const pr_id = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink));
    const pa_id = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod));
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(pr_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(pa_id).?.phase);
    try std.testing.expect(prod.bus == null); // not yet connected

    // Load the bus — printer subscribes, producer gets its bus reference.
    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(pr_id).?.phase);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(pa_id).?.phase);
    try std.testing.expect(prod.bus != null); // now connected

    // Host sends a message — reaches the printer.
    prod.send("hello");
    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);
    try std.testing.expectEqualStrings("hello", sink.lines.items[0]);

    // Ordered teardown: unload bus last (Thm 70 drains subscribers first).
    try orch.unloadFiber(bus_id);
}

test "Pattern B: emit reaches the printer with correct message" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var prod_a = ProducerState{};
    var prod_b = ProducerState{};

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod_a));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod_b));

    prod_a.send("Hello from A!");
    prod_b.send("Hello from B!");

    try std.testing.expectEqual(@as(usize, 2), sink.lines.items.len);
    try std.testing.expectEqualStrings("Hello from A!", sink.lines.items[0]);
    try std.testing.expectEqualStrings("Hello from B!", sink.lines.items[1]);

    try orch.unloadFiber(bus_id);
}

test "Pattern B: unloading printer removes its listener — later emits reach nobody" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var prod = ProducerState{};

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    const pr_id = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod));

    // Printer is active and listening. First send goes through.
    prod.send("before");
    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);

    // Unload printer: ctx.on inverse runs → bus.off(sub) called automatically.
    try orch.unloadFiber(pr_id);
    try orch.removeFiber(pr_id);

    // Later send — nobody listening.
    prod.send("after");
    try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len); // still 1

    try orch.unloadFiber(bus_id);
}

test "Pattern B: load order is irrelevant — all components end up ACTIVE (Thm 80)" {
    // Three orderings: (bus, printer, producer). All must end with all ACTIVE
    // and the producer holding a non-null bus reference.
    const Order = struct {
        fn run(order: [3]u8) !void {
            var sink = Sink.init(std.testing.allocator);
            defer sink.deinit();
            var prod = ProducerState{};

            var orch = try Orchestrator.init(std.testing.allocator);
            defer orch.deinit();

            var ids: [3]gluon.FiberId = undefined;
            for (order, 0..) |which, i| {
                ids[i] = switch (which) {
                    0 => try orch.load(bus_provider_component, gluon.component.root),
                    1 => try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink)),
                    2 => try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod)),
                    else => unreachable,
                };
            }

            // All ACTIVE regardless of order (Thm 80).
            for (ids) |id| {
                try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(id).?.phase);
            }
            try std.testing.expect(prod.bus != null); // producer is wired

            // Emit works from any order.
            prod.send("hi");
            try std.testing.expectEqual(@as(usize, 1), sink.lines.items.len);

            // Ordered teardown: unload bus (index where order[i]==0).
            const bus_idx = std.mem.indexOfScalar(u8, &order, 0).?;
            try orch.unloadFiber(ids[bus_idx]);
        }
    };
    try Order.run(.{ 0, 1, 2 }); // bus → printer → producer
    try Order.run(.{ 1, 0, 2 }); // printer → bus → producer
    try Order.run(.{ 1, 2, 0 }); // printer → producer → bus
    try Order.run(.{ 2, 1, 0 }); // producer → printer → bus
    try Order.run(.{ 2, 0, 1 }); // producer → bus → printer
    try Order.run(.{ 0, 2, 1 }); // bus → producer → printer
}

test "Pattern B: multiple printer subscribers both receive each emission" {
    var sink_a = Sink.init(std.testing.allocator);
    defer sink_a.deinit();
    var sink_b = Sink.init(std.testing.allocator);
    defer sink_b.deinit();
    var prod = ProducerState{};

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink_a));
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink_b));
    _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod));

    prod.send("broadcast");

    // One emit → both sinks received it.
    try std.testing.expectEqual(@as(usize, 1), sink_a.lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink_b.lines.items.len);
    try std.testing.expectEqualStrings("broadcast", sink_a.lines.items[0]);
    try std.testing.expectEqualStrings("broadcast", sink_b.lines.items[0]);

    try orch.unloadFiber(bus_id);
}

test "Pattern B: producer.bus is cleared to null when producer deactivates" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var prod = ProducerState{};

    var orch = try Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const bus_id = try orch.load(bus_provider_component, gluon.component.root);
    const pa_id = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod));
    _ = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink));

    try std.testing.expect(prod.bus != null); // active and wired

    // Unloading the bus deactivates the producer (dependency gone) → bus=null.
    try orch.unloadFiber(bus_id);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(pa_id).?.phase);
    try std.testing.expect(prod.bus == null); // LIFO rollback cleared bus ref

    // send() is now a no-op (bus == null guard).
    prod.send("should not reach anyone");
    try std.testing.expectEqual(@as(usize, 0), sink.lines.items.len);
}

test "Pattern B: OOM safety — full scenario leaks nothing on any allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var sink = Sink.init(allocator);
            defer sink.deinit();
            var prod = ProducerState{};

            var orch = try Orchestrator.init(allocator);
            defer orch.deinit();

            const bus_id = try orch.load(bus_provider_component, gluon.component.root);
            const pr_id = try orch.loadWithConfig(printer_component, gluon.component.root, @ptrCast(&sink));
            _ = try orch.loadWithConfig(producer_component, gluon.component.root, @ptrCast(&prod));

            // No send() here: sink.record's dupe can silently drop under OOM,
            // which checkAllAllocationFailures treats as a swallowed error.
            // The lifecycle correctness (load → activate → unload → clean) is
            // what we verify for OOM safety.

            try orch.unloadFiber(pr_id);
            try orch.removeFiber(pr_id);
            try orch.unloadFiber(bus_id);
            try orch.removeFiber(bus_id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
