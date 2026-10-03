//! Compile-check of the README Quick Start example. Kept in sync with README.md
//! so the documented API cannot drift from the real one.
const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;

const db_key = Key.of(u32, "db.port");

fn dbApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!gluon.effect_iter.Step(Context) {
            try c.store.set(u32, db_key, 5432);
            const kb = try a.create(Key);
            kb.* = db_key;
            const Inv = struct {
                fn call(s: *anyopaque, cc: *Context) void {
                    cc.store.restrict(@as(*Key, @ptrCast(@alignCast(s))).*) catch {};
                }
                fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                    aa.destroy(@as(*Key, @ptrCast(@alignCast(s))));
                }
            };
            return .{ .inverse = .{ .state = kb, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
        }
        fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
        }
    };
    return Iter.make(ctx.allocator);
}

const db_component = gluon.Component{
    .inject = &.{},
    .provide = &.{db_key},
    .apply = dbApply,
};

test "README quickstart: orchestrator load/unload" {
    var orch = try gluon.Orchestrator.init(std.testing.allocator);
    defer orch.deinit();

    const db_id = try orch.load(db_component, gluon.component.root);
    try std.testing.expect(orch.isProvided(db_key));
    try orch.unloadFiber(db_id);
    try std.testing.expect(!orch.isProvided(db_key));
}

test "README quickstart: loader reconcile" {
    var loader = try gluon.Loader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.reconcile(&.{.{ .name = "db", .component = db_component }});
    try std.testing.expect(loader.isActive("db"));
}

// Schema-validated config: a config value is validated up-front, passed to the
// component, and a VALUE change triggers a reload (§5.2.1 material change).
const DbCfg = struct { port: u16 };
const db_schema = gluon.Schema(DbCfg){ .constraints = &.{
    .{ .int_range = .{ .field = "port", .min = 1, .max = 65535 } },
} };

test "README quickstart: schema-validated config" {
    // Invalid config is rejected before any load.
    try std.testing.expectError(
        gluon.ValidationError.OutOfRange,
        gluon.Config.of(std.testing.allocator, DbCfg, db_schema, .{ .port = 0 }),
    );

    // A valid config is built, validated, and reconciled (loader owns it).
    const cfg = try gluon.Config.of(std.testing.allocator, DbCfg, db_schema, .{ .port = 5432 });
    var loader = try gluon.Loader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.reconcile(&.{.{ .name = "db", .component = db_component, .config = cfg }});
    try std.testing.expect(loader.isActive("db"));
}

// Events: listeners are revertible effects over a tagged registry (§3.4.2).
// `ctx.on` returns a disposer tracked on the context, so unloading the
// subscriber withdraws its listener automatically (Definition 8).
const bus_key = Key.of(*gluon.EventBus, "app.bus");

const Counter = struct {
    hits: u32 = 0,
    fn handler(self: *Counter) gluon.Handler {
        return .{ .state = self, .call = call };
    }
    fn call(state: *anyopaque, payload: *const anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(state));
        self.hits += @as(*const u32, @ptrCast(@alignCast(payload))).*;
    }
};

test "README quickstart: events as revertible effects" {
    // The bus must outlive the context that subscribes to it (its disposer
    // calls back into the bus on recover). Declare it first → deinit last.
    var bus = gluon.EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.set(*gluon.EventBus, bus_key, &bus);

    var counter = Counter{};
    _ = try ctx.on(u32, bus_key, "tick", counter.handler());

    var one: u32 = 1;
    _ = try ctx.emit(u32, bus_key, "tick", &one);
    try std.testing.expectEqual(@as(u32, 1), counter.hits);

    // Recovering the context withdraws the listener: later emits reach no one.
    ctx.dispose.recover(ctx);
    try std.testing.expectEqual(@as(usize, 0), bus.emit(u32, "tick", &one));
}
