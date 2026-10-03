//! Shared test fixtures: reusable component factories for integration tests.
//!
//! These build the small provider/consumer components that the lifecycle and
//! loader integration suites (and the README example) exercise. Centralizing
//! them removes the near-identical copies that previously lived in each test
//! file and keeps the fixture semantics in one place.
//!
//! All providers use a u32 value type and provision/withdraw a single key, so
//! the inverse is a simple `restrict`. Consumers declare a dependency and run a
//! no-op effect (unit), so activation/deactivation is observable without side
//! effects of their own.

const std = @import("std");
const comp = @import("../component/component.zig");
const Context = @import("../context/context.zig").Context;
const effect_iter = @import("../effect/effect_iter.zig");
const store_mod = @import("../coeffect/store.zig");

pub const Component = comp.Component;
pub const Key = store_mod.Key;
pub const Step = effect_iter.Step;

/// Build an `apply` that provisions `key_name := value` on activation and
/// yields a `restrict` inverse that withdraws it on deactivation.
pub fn providerApply(comptime key_name: []const u8, comptime value: u32) comp.Apply {
    const Impl = struct {
        const k = Key.of(u32, key_name);
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
                    try c.store.set(u32, k, value);
                    const kb = try a.create(Key);
                    kb.* = k;
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
                fn deinit(state: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(state))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return Impl.apply;
}

/// A provider component: provides `key_name` (value type u32), depends on
/// nothing. Default (trivial/commutative) provision witness.
pub fn provider(comptime key_name: []const u8, comptime value: u32) Component {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_name)};
    };
    return .{ .inject = &.{}, .provide = &S.k, .apply = providerApply(key_name, value) };
}

/// A consumer component: declares `key_name` as a dependency, provides nothing,
/// and runs a no-op effect (unit) so its activation is observable.
pub fn consumer(comptime key_name: []const u8) Component {
    const S = struct {
        const k = [_]Key{Key.of(u32, key_name)};
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, _: std.mem.Allocator, _: *Context) anyerror!Step(Context) {
                    const Noop = struct {
                        fn call(_: *anyopaque, _: *Context) void {}
                        fn dfn(_: *anyopaque, _: std.mem.Allocator) void {}
                    };
                    return .{ .inverse = .{ .state = undefined, .call = Noop.call, .deinit = Noop.dfn }, .done = true };
                }
                fn deinit(state: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(state))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return .{ .inject = &S.k, .provide = &.{}, .apply = S.apply };
}
