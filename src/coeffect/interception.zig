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
//!
//! Provider table + automated get (roadmap #2): the provider function
//! σ(k) : ℳₖ → 𝒱ₖ is realized by `ProviderTable`, and Context.getIntercepted
//! performs the whole Definition 27 get — σ(k)(μ ⊕ₖ 𝜄(k)) — in one call: merge
//! the component-declared μ with the context-carried 𝜄(k) (right-biased toward
//! 𝜄(k)), then apply σ(k). Previously the merge+apply was left to the
//! component (only `interceptOf` exposed the carried half); it is now
//! automated at the access site, matching Def 27 directly.

const std = @import("std");

/// A metadata merge function ⊕ₖ for a key: combines an inherited value with a
/// new one, right-biased (the second argument / enclosing context wins on
/// conflict). Both are opaque; the function knows the concrete type.
pub const Merge = *const fn (
    allocator: std.mem.Allocator,
    inherited: ?*anyopaque,
    incoming: *anyopaque,
) anyerror!*anyopaque;

/// A provider function σ(k) : ℳₖ → 𝒱ₖ (Definition 26). Given the merged
/// metadata (μ ⊕ₖ 𝜄(k)), it computes the resolved value the holder observes.
/// Both metadata and value are opaque; the function knows the concrete types.
/// `metadata` may be null (εₖ — no component-declared nor context-carried
/// metadata). The returned value is owned by the caller (freed via the
/// provider's `free`).
pub const Provider = struct {
    /// σ(k): metadata ↦ freshly-owned value.
    apply: *const fn (allocator: std.mem.Allocator, metadata: ?*anyopaque) anyerror!*anyopaque,
    /// Releases a value produced by `apply`.
    free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,
};

/// A metadata entry: an opaque value plus the hooks to merge and free it.
const Entry = struct {
    value: *anyopaque,
    merge: Merge,
    free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,
};

/// The typed result of Definition 27's get σ(k)(μ ⊕ₖ 𝜄(k)): a value pointer the
/// caller owns, plus the hook to release it.
pub fn Resolved(comptime V: type) type {
    return struct {
        value: *V,
        free: *const fn (value: *anyopaque, allocator: std.mem.Allocator) void,

        /// Release the resolved value.
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            self.free(@ptrCast(self.value), allocator);
        }
    };
}

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

    /// The merge hook ⊕ₖ registered for a key (via a prior intercept), or null
    /// if the key carries no metadata. Needed to merge a component's declared
    /// μ with the carried 𝜄(k) at access time (Definition 27 get).
    pub fn mergeOf(self: *const Self, key_name: []const u8) ?Merge {
        if (self.entries.get(key_name)) |e| return e.merge;
        return null;
    }

    /// Free a value produced by this key's merge hook, using the key's `free`.
    /// Used to release the transient μ ⊕ₖ 𝜄(k) result after a provider applied
    /// it (Definition 27 get). No-op if the key is absent.
    pub fn freeMerged(self: *const Self, key_name: []const u8, value: *anyopaque) void {
        if (self.entries.get(key_name)) |e| e.free(value, self.allocator);
    }
};

/// The provider table σ : (k:K) → (ℳₖ → 𝒱ₖ) (Definition 26). Registered by the
/// component that provides a key; shared across contexts (like the store), so
/// a derived child resolves the same provider but against its own carried 𝜄.
pub const ProviderTable = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    providers: std.StringHashMapUnmanaged(Provider),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .providers = .empty };
    }

    pub fn deinit(self: *Self) void {
        self.providers.deinit(self.allocator);
    }

    /// Register σ(k) for a key. Fails if a provider already exists (single
    /// source, mirroring the store's O-Insert provision disjointness).
    pub fn register(self: *Self, key_name: []const u8, provider: Provider) !void {
        const gop = try self.providers.getOrPut(self.allocator, key_name);
        if (gop.found_existing) return error.ProviderAlreadyRegistered;
        gop.value_ptr.* = provider;
    }

    /// Remove σ(k) (the inverse of register, run on provider teardown).
    pub fn unregister(self: *Self, key_name: []const u8) void {
        _ = self.providers.remove(key_name);
    }

    pub fn get(self: *const Self, key_name: []const u8) ?Provider {
        return self.providers.get(key_name);
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

// ── Provider table σ(k) : ℳₖ → 𝒱ₖ (Definition 26) ──────────────
//
// A provider that counts the flags in a FlagSet metadata (demonstrating that
// the resolved value depends on the merged metadata). εₖ metadata yields 0.

fn countProvider(allocator: std.mem.Allocator, metadata: ?*anyopaque) anyerror!*anyopaque {
    const out = try allocator.create(usize);
    out.* = if (metadata) |m| @as(*FlagSet, @ptrCast(@alignCast(m))).flags.items.len else 0;
    return out;
}
fn countFree(value: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(@as(*usize, @ptrCast(@alignCast(value))));
}

test "Definition 26: register/get a provider σ(k), reject double registration" {
    var table = ProviderTable.init(std.testing.allocator);
    defer table.deinit();

    try table.register("db", .{ .apply = countProvider, .free = countFree });
    try std.testing.expect(table.get("db") != null);
    try std.testing.expectError(error.ProviderAlreadyRegistered, table.register("db", .{ .apply = countProvider, .free = countFree }));

    table.unregister("db");
    try std.testing.expect(table.get("db") == null);
}

test "Definition 27: σ(k) applied to merged metadata yields the resolved value" {
    var table = ProviderTable.init(std.testing.allocator);
    defer table.deinit();
    try table.register("db", .{ .apply = countProvider, .free = countFree });

    const md = try FlagSet.create(std.testing.allocator, &.{ "read-only", "audited" });
    defer FlagSet.freeFn(md, std.testing.allocator);

    const p = table.get("db").?;
    const value = try p.apply(std.testing.allocator, md);
    defer p.free(value, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), @as(*usize, @ptrCast(@alignCast(value))).*);

    // εₖ metadata (null) resolves to the provider's zero value.
    const empty = try p.apply(std.testing.allocator, null);
    defer p.free(empty, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), @as(*usize, @ptrCast(@alignCast(empty))).*);
}
