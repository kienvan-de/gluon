//! Coeffect interception (Definitions 26, 27) — cross-cutting metadata on
//! dependency access, without modifying the dependency value.
//!
//! Paper correspondence:
//!   - Definition 26 (Σinter, 𝔇inter): the context carries metadata 𝜄 : (k:K) →
//!     ℳₖ installed on the context itself (empty εₖ by default); and the
//!     provider table maps each key to a provider function ℳₖ → 𝒱ₖ. A
//!     specification carries component-declared metadata d(k).
//!   - Definition 27 (get/set/intercept):
//!       • get(k, μ) evaluates σ(k)(μ ⊕ₖ 𝜄(k)) — merge component-declared
//!         metadata μ with context-carried 𝜄(k), apply the provider.
//!       • intercept(k, ν) derives a context merging ν onto 𝜄(k). The merge is
//!         right-biased, so 𝜄(k) (the enclosing context) takes priority and can
//!         override a component's declaration (e.g. §6.3 sandboxing).
//!       • Each key equips ℳₖ with a monoid (ℳₖ, ⊕ₖ, εₖ).
//!   - §5.1.2: intercept derives a child context adjusting 𝜄 only; recovery is
//!     implicit (discard the derived context), so it is NOT a tracked effect
//!     (derived realization, Def 23).
//!
//! This slice models metadata as an opaque, monoid-mergeable value keyed by
//! coeffect key name. The merge semantics are supplied per key (scalar fields
//! overwrite, set-valued fields union — Def 27 note). We provide a generic
//! Metadata table and a right-biased merge hook; concrete key metadata types
//! plug in via the comptime key registry (Phase 8).

const std = @import("std");

/// A metadata merge function ⊕ₖ for a key: combines an inherited value with a
/// new one, right-biased (the second argument / enclosing context wins on
/// conflict). Both are opaque; the function knows the concrete type.
pub const Merge = *const fn (
    allocator: std.mem.Allocator,
    inherited: ?*anyopaque,
    incoming: *anyopaque,
) anyerror!*anyopaque;

/// A metadata entry: an opaque value plus the hooks to merge and free it.
const Entry = struct {
    value: *anyopaque,
    merge: Merge,
    free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,
};

/// The interception table 𝜄 : key name → metadata (Definition 26). Carried by
/// a context; a derived child context gets its own table that inherits (by
/// merge) from the parent on intercept.
pub const InterceptTable = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| e.free(e.value, self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Definition 27 (intercept): merge `incoming` metadata onto 𝜄(key),
    /// right-biased. If no metadata exists for the key, `incoming` becomes it.
    /// Takes ownership of `incoming` (merge/free manage it thereafter).
    pub fn intercept(
        self: *Self,
        key_name: []const u8,
        incoming: *anyopaque,
        merge: Merge,
        free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,
    ) !void {
        if (self.entries.getPtr(key_name)) |existing| {
            // Merge: 𝜄(k) ⊕ₖ ν, right-biased toward the incoming value. If merge
            // fails we must still free `incoming` (we own it) — otherwise it
            // leaks on the error path.
            const merged = merge(self.allocator, existing.value, incoming) catch |err| {
                free(incoming, self.allocator);
                return err;
            };
            // merge returns a freshly-owned value; release the old inherited
            // value and the consumed incoming one.
            existing.free(existing.value, self.allocator);
            free(incoming, self.allocator);
            existing.value = merged;
        } else {
            // On put failure we still own `incoming`; free it so it does not
            // leak before returning the error.
            self.entries.put(self.allocator, key_name, .{
                .value = incoming,
                .merge = merge,
                .free = free,
            }) catch |err| {
                free(incoming, self.allocator);
                return err;
            };
        }
    }

    /// 𝜄(k): the context-carried metadata for a key, or null (εₖ) if none.
    pub fn get(self: *const Self, key_name: []const u8) ?*anyopaque {
        if (self.entries.get(key_name)) |e| return e.value;
        return null;
    }
};

// ───────────────────────────── Tests ─────────────────────────────
//
// Model metadata as a set of string flags (a set-valued field, unioned on
// merge per Def 27) to exercise the monoid merge.

const FlagSet = struct {
    flags: std.ArrayListUnmanaged([]const u8),

    fn create(allocator: std.mem.Allocator, initial: []const []const u8) !*FlagSet {
        const self = try allocator.create(FlagSet);
        errdefer allocator.destroy(self);
        self.* = .{ .flags = .empty };
        errdefer self.flags.deinit(allocator);
        for (initial) |f| try self.flags.append(allocator, f);
        return self;
    }
    fn has(self: *const FlagSet, flag: []const u8) bool {
        for (self.flags.items) |f| if (std.mem.eql(u8, f, flag)) return true;
        return false;
    }
    fn freeFn(value: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FlagSet = @ptrCast(@alignCast(value));
        self.flags.deinit(allocator);
        allocator.destroy(self);
    }
    /// Union merge (right-biased is irrelevant for a set union, but we keep the
    /// incoming elements too). Returns a fresh FlagSet.
    fn mergeFn(allocator: std.mem.Allocator, inherited: ?*anyopaque, incoming: *anyopaque) anyerror!*anyopaque {
        const inc: *FlagSet = @ptrCast(@alignCast(incoming));
        const out = try FlagSet.create(allocator, &.{});
        errdefer FlagSet.freeFn(out, allocator); // free partial result on OOM
        if (inherited) |ih| {
            const old: *FlagSet = @ptrCast(@alignCast(ih));
            for (old.flags.items) |f| try out.flags.append(allocator, f);
        }
        for (inc.flags.items) |f| {
            if (!out.has(f)) try out.flags.append(allocator, f);
        }
        return out;
    }
};

test "Definition 27: intercept installs metadata when none exists" {
    var table = InterceptTable.init(std.testing.allocator);
    defer table.deinit();

    const fs = try FlagSet.create(std.testing.allocator, &.{"read-only"});
    try table.intercept("db", fs, FlagSet.mergeFn, FlagSet.freeFn);

    const got: *FlagSet = @ptrCast(@alignCast(table.get("db").?));
    try std.testing.expect(got.has("read-only"));
}

test "Definition 27: intercept merges metadata (set union)" {
    var table = InterceptTable.init(std.testing.allocator);
    defer table.deinit();

    const fs1 = try FlagSet.create(std.testing.allocator, &.{"read-only"});
    try table.intercept("db", fs1, FlagSet.mergeFn, FlagSet.freeFn);
    const fs2 = try FlagSet.create(std.testing.allocator, &.{"audited"});
    try table.intercept("db", fs2, FlagSet.mergeFn, FlagSet.freeFn);

    const got: *FlagSet = @ptrCast(@alignCast(table.get("db").?));
    try std.testing.expect(got.has("read-only")); // inherited
    try std.testing.expect(got.has("audited")); // incoming
}

test "εₖ: an unintercepted key carries no metadata" {
    var table = InterceptTable.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), table.get("absent"));
}

fn interceptScenario(allocator: std.mem.Allocator) !void {
    var table = InterceptTable.init(allocator);
    defer table.deinit();
    const fs1 = try FlagSet.create(allocator, &.{"a"});
    try table.intercept("k", fs1, FlagSet.mergeFn, FlagSet.freeFn);
    const fs2 = try FlagSet.create(allocator, &.{"b"});
    try table.intercept("k", fs2, FlagSet.mergeFn, FlagSet.freeFn);
}

test "OOM safety: intercept merge path leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, interceptScenario, .{});
}
