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
