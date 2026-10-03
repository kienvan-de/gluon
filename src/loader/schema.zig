//! Schema-validated component configuration (§5.2.1).
//!
//! Paper correspondence:
//!   - §5.2.1 (Declarative Configuration): a configured entry carries the
//!     config a component is instantiated with; reconciliation "reloads only on
//!     a material change". The paper treats config abstractly; this module
//!     turns it into a TYPED, VALIDATED value and makes "material change" a
//!     value-level diff (not merely a code-identity diff).
//!   - §4.4 (Configuration revision): changing an entry's config is a revision
//!     — retire the fiber and reinstantiate with the new config (the composite
//!     held to its endpoint, Thm 80). The loader detects a config change via
//!     `Config.eql` and routes it through the same HMR path as a code change.
//!
//! Design (Zig comptime): a `Schema(T)` is built at compile time from a config
//! struct type `T` plus per-field constraints. Validation runs the constraints
//! against a `T` value. A `Config` is the type-erased carrier the loader
//! stores: it owns a heap copy of the value, remembers how to validate, compare
//! (for the material-change diff), and free it, and exposes the opaque pointer
//! that `Component.apply` receives.
//!
//! Why value-diff over code-diff: two entries with the same `apply` but
//! different config must reload (a port change, a feature flag). The previous
//! loader only diffed the apply fn-ptr + interface, so a config-only change was
//! a silent no-op. This closes that gap faithfully to §5.2.1's "material
//! change".

const std = @import("std");
const type_id = @import("../context/type_id.zig");

pub const TypeId = type_id.TypeId;

pub const ValidationError = error{
    /// A numeric field fell outside its declared [min, max] range.
    OutOfRange,
    /// A slice/string field was empty where non-empty was required.
    Empty,
    /// A custom predicate rejected the value.
    ConstraintViolated,
};

/// A per-field constraint over a config struct `T`. Constraints are declared at
/// comptime (field name + kind) and checked against a `T` value at runtime.
pub fn Constraint(comptime T: type) type {
    return union(enum) {
        /// An integer field must lie in [min, max] (inclusive).
        int_range: struct { field: []const u8, min: i128, max: i128 },
        /// A slice/pointer-to-array field must be non-empty.
        non_empty: struct { field: []const u8 },
        /// A caller-supplied predicate over the whole value.
        predicate: *const fn (value: T) bool,
    };
}

/// A schema over a config struct type `T`: a comptime list of constraints plus
/// a validate function. Build with `Schema(T){ .constraints = &.{...} }`.
pub fn Schema(comptime T: type) type {
    return struct {
        const Self = @This();

        constraints: []const Constraint(T) = &.{},

        /// Validate a `T` value against every constraint. Returns the first
        /// violation (deterministic: constraints are checked in order).
        pub fn validate(comptime self: Self, value: T) ValidationError!void {
            inline for (self.constraints) |c| {
                switch (c) {
                    .int_range => |r| {
                        const fv: i128 = @intCast(@field(value, r.field));
                        if (fv < r.min or fv > r.max) return ValidationError.OutOfRange;
                    },
                    .non_empty => |n| {
                        if (@field(value, n.field).len == 0) return ValidationError.Empty;
                    },
                    .predicate => |p| {
                        if (!p(value)) return ValidationError.ConstraintViolated;
                    },
                }
            }
        }
    };
}

/// A type-erased, validated config carrier. Owns a heap copy of the config
/// value; knows how to compare it (material-change diff), free it, and hands
/// the opaque pointer to `Component.apply`.
pub const Config = struct {
    const Self = @This();

    /// Opaque pointer to the owned `T` value — what `apply` receives.
    ptr: *anyopaque,
    /// The config value's type (guards misuse at the boundary, like the store).
    value_type: TypeId,
    /// Byte-wise comparator over two Configs of the same type (material diff).
    eql_fn: *const fn (a: *anyopaque, b: *anyopaque) bool,
    /// Releases the owned value.
    free_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    /// Build a validated Config from a typed value and its schema. Validates
    /// up-front (comptime schema, runtime value); on success, heap-copies the
    /// value and returns the erased carrier. The caller's `value` is copied,
    /// so it may be a stack temporary.
    pub fn of(
        allocator: std.mem.Allocator,
        comptime T: type,
        comptime schema: Schema(T),
        value: T,
    ) (ValidationError || std.mem.Allocator.Error)!Self {
        try schema.validate(value);
        const box = try allocator.create(T);
        box.* = value;
        const Impl = struct {
            fn eql(a: *anyopaque, b: *anyopaque) bool {
                const av: *const T = @ptrCast(@alignCast(a));
                const bv: *const T = @ptrCast(@alignCast(b));
                return std.meta.eql(av.*, bv.*);
            }
            fn free(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
            }
        };
        return .{
            .ptr = @ptrCast(box),
            .value_type = type_id.typeId(T),
            .eql_fn = Impl.eql,
            .free_fn = Impl.free,
        };
    }

    /// Whether two configs are materially equal: same type AND equal value.
    /// A different type, or an equal type with a different value, is a change.
    pub fn eql(self: Self, other: Self) bool {
        if (self.value_type != other.value_type) return false;
        return self.eql_fn(self.ptr, other.ptr);
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        self.free_fn(self.ptr, allocator);
    }
};

// ───────────────────────────── Tests ─────────────────────────────

const ServerCfg = struct {
    port: u16,
    host: []const u8,
    verbose: bool = false,
};

const server_schema = Schema(ServerCfg){ .constraints = &.{
    .{ .int_range = .{ .field = "port", .min = 1, .max = 65535 } },
    .{ .non_empty = .{ .field = "host" } },
} };

test "§5.2.1 schema: a valid config passes validation" {
    try server_schema.validate(.{ .port = 8080, .host = "localhost" });
}

test "schema: int_range rejects an out-of-range field" {
    try std.testing.expectError(
        ValidationError.OutOfRange,
        server_schema.validate(.{ .port = 0, .host = "localhost" }),
    );
}

test "schema: non_empty rejects an empty slice field" {
    try std.testing.expectError(
        ValidationError.Empty,
        server_schema.validate(.{ .port = 80, .host = "" }),
    );
}

test "schema: a custom predicate constraint is enforced" {
    const schema = Schema(ServerCfg){ .constraints = &.{
        .{ .predicate = struct {
            fn p(v: ServerCfg) bool {
                return v.verbose or v.port != 0; // arbitrary rule
            }
        }.p },
    } };
    try schema.validate(.{ .port = 1, .host = "h" });
    try std.testing.expectError(
        ValidationError.ConstraintViolated,
        schema.validate(.{ .port = 0, .host = "h", .verbose = false }),
    );
}

test "Config.of validates and heap-copies a value" {
    const cfg = try Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 8080, .host = "h" });
    defer cfg.deinit(std.testing.allocator);
    const v: *const ServerCfg = @ptrCast(@alignCast(cfg.ptr));
    try std.testing.expectEqual(@as(u16, 8080), v.port);
}

test "Config.of rejects an invalid value (no allocation on failure)" {
    try std.testing.expectError(
        ValidationError.OutOfRange,
        Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 0, .host = "h" }),
    );
}

test "§5.2.1 material change: equal configs compare equal, differing ones differ" {
    const a = try Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 80, .host = "h" });
    defer a.deinit(std.testing.allocator);
    const b = try Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 80, .host = "h" });
    defer b.deinit(std.testing.allocator);
    const c = try Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 81, .host = "h" });
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(a.eql(b)); // same value → no material change
    try std.testing.expect(!a.eql(c)); // port differs → material change
}

test "Config.eql: a different value type is a material change" {
    const Other = struct { n: u32 };
    const other_schema = Schema(Other){};
    const a = try Config.of(std.testing.allocator, ServerCfg, server_schema, .{ .port = 80, .host = "h" });
    defer a.deinit(std.testing.allocator);
    const b = try Config.of(std.testing.allocator, Other, other_schema, .{ .n = 1 });
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!a.eql(b)); // distinct types never materially equal
}

fn configUnderOom(allocator: std.mem.Allocator) !void {
    const cfg = try Config.of(allocator, ServerCfg, server_schema, .{ .port = 8080, .host = "h" });
    defer cfg.deinit(allocator);
}

test "OOM safety: Config.of leaks nothing on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configUnderOom, .{});
}
