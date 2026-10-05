//! Gluon end-to-end example: "Hello, {name}!"
//!
//! Four components wired through the coeffect store, proving Gluon's spatial and
//! temporal composability on a tiny, observable program:
//!
//!   name_reader   provide "name"                 (prompt + read a line)
//!        │
//!   greeter       inject "name", provide "greeting"  (two COMPETING providers)
//!        │
//!   printer       inject "greeting"               (print — a §6.1 emission)
//!
//! What this demonstrates about the paper (arXiv:2608.25512):
//!
//!   • Spatial composability / dependency ordering (Thm 70): the printer
//!     activates only AFTER name_reader → greeter are active. Load order does
//!     not matter — a component whose keys are not yet provided waits Inactive
//!     until Alg 3 (notify) wakes it.
//!   • Single-source discipline (Def 50 / O-Insert): the two greeters both
//!     provide "greeting"; loading both rejects the second with
//!     ProvisionConflict. They are INTERCHANGEABLE providers of one key.
//!   • Temporal composability (Thm 7 / Cor 69): retiring the active greeter
//!     deactivates the printer (its dependency vanished) and withdraws
//!     "greeting" exactly; loading the OTHER greeter reactivates the printer
//!     with the new wording (reload after re-satisfaction).
//!   • Host boundary (§6.1): reading a line from stdin is a revertible
//!     acquisition (the inverse frees the name); writing to stdout is an
//!     emission that stays done (never reverted).
//!
//! IO is injected (the `Io` struct) so the `test` block can script stdin
//! deterministically and capture stdout, while `main()` uses the real streams.

const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;
const Component = gluon.Component;
const Orchestrator = gluon.Orchestrator;
const Step = gluon.effect_iter.Step;

// ── Keys (the coeffect wiring) ────────────────────────────────────
// "name" and "greeting" carry owned, heap-allocated strings; the provider that
// sets a key also owns the bytes and frees them in its inverse.

const name_key = Key.of([]const u8, "name");
const greeting_key = Key.of([]const u8, "greeting");

// ── Injected IO (so tests are deterministic) ──────────────────────
//
// A tiny indirection over "read a line" and "write a line". main() wires the
// real stdin/stdout; the test wires a scripted reader and a capturing writer.
// Stored in the context under this key so every component can reach it.

pub const Io = struct {
    state: *anyopaque,
    /// Prompt (write without newline) then read one line. Caller owns the
    /// returned slice (allocated with `allocator`); empty slice ⇒ EOF.
    readLine: *const fn (state: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) anyerror![]u8,
    /// Write a line (adds the newline).
    writeLine: *const fn (state: *anyopaque, line: []const u8) anyerror!void,
};

const io_key = Key.of(*const Io, "app.io");

// ── Component 1: name_reader ──────────────────────────────────────
// provide "name". Prompts, reads a line, sets name := the input. Its inverse
// restricts "name" AND frees the heap string (the §6.1 acquisition revert).

fn nameReaderApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const io = try c.get(*const Io, io_key);
            const name = try io.readLine(io.state, a, "What is your name? ");
            errdefer a.free(name);
            // Install the binding. The store copies the SLICE (ptr+len); we
            // keep ownership of the bytes and free them in the inverse.
            try c.store.set([]const u8, name_key, name);

            // Inverse: `call` restricts "name"; `dfn` frees BOTH the state
            // struct AND the owned bytes. The accumulator always runs `dfn`
            // after `call` on recover, and runs `dfn` alone if tracking the
            // inverse fails (the drop path) — so freeing bytes in `dfn` frees
            // them exactly once on every path (OOM-safe, §6.1 acquisition).
            const St = struct { bytes: []u8 };
            const inv = try a.create(St);
            errdefer a.destroy(inv);
            inv.* = .{ .bytes = name };
            const Inv = struct {
                fn call(s: *anyopaque, cc: *Context) void {
                    _ = s;
                    cc.store.restrict(name_key) catch {};
                }
                fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                    const st: *St = @ptrCast(@alignCast(s));
                    aa.free(st.bytes);
                    aa.destroy(st);
                }
            };
            return .{ .inverse = .{ .state = inv, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
        }
        fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
        }
    };
    return Iter.make(ctx.allocator);
}

// Note: `io_key` is ambient infrastructure installed on the root context, NOT a
// component-provided coeffect — so it is read via `c.get(io_key)` but is NOT in
// `inject`. Only keys that must GATE activation (and are provided by an active
// fiber) belong in `inject` (Def 52 / Thm 70).
const name_reader = Component{
    .inject = &.{},
    .provide = &.{name_key},
    .apply = nameReaderApply,
};

// ── Components 2 & 3: greeters (competing providers of "greeting") ──
// Both inject "name" and provide "greeting" with a template. A comptime
// `template` with one "{s}" slot keeps the two greeters a single factory.

fn GreeterApply(comptime template: []const u8) gluon.component.Apply {
    const Impl = struct {
        fn apply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
            const Iter = struct {
                fn make(a: std.mem.Allocator) !Context.Iterator {
                    const self = try a.create(@This());
                    self.* = .{};
                    return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
                }
                fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
                    const name = try c.get([]const u8, name_key);
                    const greeting = try std.fmt.allocPrint(a, template, .{name});
                    errdefer a.free(greeting);
                    try c.store.set([]const u8, greeting_key, greeting);

                    const St = struct { bytes: []u8 };
                    const inv = try a.create(St);
                    errdefer a.destroy(inv);
                    inv.* = .{ .bytes = greeting };
                    const Inv = struct {
                        fn call(s: *anyopaque, cc: *Context) void {
                            _ = s;
                            cc.store.restrict(greeting_key) catch {};
                        }
                        fn dfn(s: *anyopaque, aa: std.mem.Allocator) void {
                            const st: *St = @ptrCast(@alignCast(s));
                            aa.free(st.bytes);
                            aa.destroy(st);
                        }
                    };
                    return .{ .inverse = .{ .state = inv, .call = Inv.call, .deinit = Inv.dfn }, .done = true };
                }
                fn deinit(s: *anyopaque, a: std.mem.Allocator) void {
                    a.destroy(@as(*@This(), @ptrCast(@alignCast(s))));
                }
            };
            return Iter.make(ctx.allocator);
        }
    };
    return Impl.apply;
}

const formal_greeter = Component{
    .inject = &.{name_key},
    .provide = &.{greeting_key},
    .apply = GreeterApply("Hello, {s}!"),
};

const casual_greeter = Component{
    .inject = &.{name_key},
    .provide = &.{greeting_key},
    .apply = GreeterApply("Hi, {s}! How are you?"),
};

// ── Component 4: printer ──────────────────────────────────────────
// inject "greeting". Prints it — a §6.1 EMISSION, so the inverse is identity
// (we never "unprint"). It reactivates and prints again whenever "greeting"
// changes (e.g. after swapping greeters).

fn printerApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, _: std.mem.Allocator, c: *Context) anyerror!Step(Context) {
            const io = try c.get(*const Io, io_key);
            const greeting = try c.get([]const u8, greeting_key);
            try io.writeLine(io.state, greeting); // emission (§6.1): not reverted
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

const printer = Component{
    .inject = &.{greeting_key},
    .provide = &.{},
    .apply = printerApply,
};

// ── Wiring: build an orchestrator with IO installed ───────────────

/// Build an orchestrator and install the IO handle into its root context so
/// every fiber (whose context derives from root) can resolve `io_key`.
fn makeApp(allocator: std.mem.Allocator, io: *const Io) !Orchestrator {
    var orch = try Orchestrator.init(allocator);
    errdefer orch.deinit();
    try orch.root_ctx.set(*const Io, io_key, io);
    return orch;
}

// ── Real IO for main() ────────────────────────────────────────────

// Real stdin/stdout. The host boundary (§6.1) is the ONLY place std.Io is
// touched — the components and the tests never see it. Reads use std.posix
// (stable); writes go through std.Io.File's writer (the 0.16 way).
const StdIo = struct {
    io_impl: std.Io,

    fn writeLineRaw(self: *StdIo, line: []const u8) anyerror!void {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(self.io_impl, &buf);
        try w.interface.writeAll(line);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }
    fn readLine(state: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) anyerror![]u8 {
        const self: *StdIo = @ptrCast(@alignCast(state));
        {
            var buf: [256]u8 = undefined;
            var w = std.Io.File.stdout().writer(self.io_impl, &buf);
            try w.interface.writeAll(prompt);
            try w.interface.flush();
        }
        var buf: [4096]u8 = undefined;
        const n = try std.posix.read(std.posix.STDIN_FILENO, &buf);
        var line = buf[0..n];
        while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
            line = line[0 .. line.len - 1];
        }
        return allocator.dupe(u8, line);
    }
    fn writeLine(state: *anyopaque, line: []const u8) anyerror!void {
        const self: *StdIo = @ptrCast(@alignCast(state));
        try self.writeLineRaw(line);
    }
    fn io(self: *StdIo) Io {
        return .{ .state = self, .readLine = readLine, .writeLine = writeLine };
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var std_io = StdIo{ .io_impl = threaded.io() };
    const io = std_io.io();

    var orch = try makeApp(allocator, &io);
    defer orch.deinit();

    // Load the chain. Order is irrelevant to the final wiring, but reading the
    // name first means the single stdin prompt happens up front.
    _ = try orch.load(name_reader, gluon.component.root);
    _ = try orch.load(formal_greeter, gluon.component.root);
    _ = try orch.load(printer, gluon.component.root);
    // By now the printer has already printed "Hello, {name}!".
}

// ─────────────────────────── Tests ───────────────────────────────
//
// Deterministic drive: a scripted reader returns a fixed name; a capturing
// writer records every printed line. These assert the composability claims
// without touching real stdin/stdout, and run under the leak-checking
// testing.allocator.

const ScriptedIo = struct {
    name: []const u8,
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, name: []const u8) ScriptedIo {
        return .{ .name = name, .lines = .empty, .allocator = allocator };
    }
    fn deinit(self: *ScriptedIo) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
    fn readLine(state: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *ScriptedIo = @ptrCast(@alignCast(state));
        return allocator.dupe(u8, self.name);
    }
    fn writeLine(state: *anyopaque, line: []const u8) anyerror!void {
        const self: *ScriptedIo = @ptrCast(@alignCast(state));
        const copy = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(copy); // append may fail under OOM injection
        try self.lines.append(self.allocator, copy);
    }
    fn io(self: *ScriptedIo) Io {
        return .{ .state = self, .readLine = readLine, .writeLine = writeLine };
    }
    fn lastLine(self: *ScriptedIo) ?[]const u8 {
        if (self.lines.items.len == 0) return null;
        return self.lines.items[self.lines.items.len - 1];
    }
};

test "end-to-end: the chain prints a formal greeting" {
    var scripted = ScriptedIo.init(std.testing.allocator, "Ada");
    defer scripted.deinit();
    const io = scripted.io();

    var orch = try makeApp(std.testing.allocator, &io);
    defer orch.deinit();

    _ = try orch.load(name_reader, gluon.component.root);
    _ = try orch.load(formal_greeter, gluon.component.root);
    _ = try orch.load(printer, gluon.component.root);

    try std.testing.expect(orch.isProvided(name_key));
    try std.testing.expect(orch.isProvided(greeting_key));
    try std.testing.expectEqualStrings("Hello, Ada!", scripted.lastLine().?);
}

test "spatial composability: printer waits (Inactive) until greeting appears" {
    // Load the printer FIRST — its "greeting" dep is absent, so it stays
    // Inactive and prints nothing until the chain upstream activates (Alg 3).
    var scripted = ScriptedIo.init(std.testing.allocator, "Grace");
    defer scripted.deinit();
    const io = scripted.io();

    var orch = try makeApp(std.testing.allocator, &io);
    defer orch.deinit();

    const printer_id = try orch.load(printer, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(printer_id).?.phase);
    try std.testing.expectEqual(@as(usize, 0), scripted.lines.items.len); // nothing printed yet

    // Now supply name → greeter → the printer reactivates and prints.
    _ = try orch.load(name_reader, gluon.component.root);
    _ = try orch.load(formal_greeter, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(printer_id).?.phase);
    try std.testing.expectEqualStrings("Hello, Grace!", scripted.lastLine().?);
}

test "single-source (Def 50): two greeters for one key — second is rejected" {
    var scripted = ScriptedIo.init(std.testing.allocator, "Linus");
    defer scripted.deinit();
    const io = scripted.io();

    var orch = try makeApp(std.testing.allocator, &io);
    defer orch.deinit();

    _ = try orch.load(name_reader, gluon.component.root);
    _ = try orch.load(formal_greeter, gluon.component.root);
    // casual_greeter ALSO provides "greeting" → O-Insert single-source rejects.
    try std.testing.expectError(
        error.ProvisionConflict,
        orch.load(casual_greeter, gluon.component.root),
    );
}

test "temporal composability: swap greeters, printer re-greets with new wording" {
    // Retire the formal greeter → "greeting" withdrawn, printer deactivates.
    // Remove it (O-Remove frees the provision), load the casual greeter → the
    // printer reactivates and prints the NEW greeting. The two greeters are
    // interchangeable providers of one key (the #2-vs-#3 punchline).
    var scripted = ScriptedIo.init(std.testing.allocator, "Edsger");
    defer scripted.deinit();
    const io = scripted.io();

    var orch = try makeApp(std.testing.allocator, &io);
    defer orch.deinit();

    _ = try orch.load(name_reader, gluon.component.root);
    const formal_id = try orch.load(formal_greeter, gluon.component.root);
    const printer_id = try orch.load(printer, gluon.component.root);
    try std.testing.expectEqualStrings("Hello, Edsger!", scripted.lastLine().?);

    // Retire + remove the formal greeter: printer deactivates, greeting gone.
    try orch.unloadFiber(formal_id);
    try std.testing.expectEqual(gluon.Phase.inactive, orch.registry.get(printer_id).?.phase);
    try std.testing.expect(!orch.isProvided(greeting_key));
    try orch.removeFiber(formal_id); // free the "greeting" provision for reuse

    // Load the casual greeter → printer reactivates with the new wording.
    _ = try orch.load(casual_greeter, gluon.component.root);
    try std.testing.expectEqual(gluon.Phase.active, orch.registry.get(printer_id).?.phase);
    try std.testing.expectEqualStrings("Hi, Edsger! How are you?", scripted.lastLine().?);
}

fn appScenario(allocator: std.mem.Allocator) !void {
    var scripted = ScriptedIo.init(allocator, "Dennis");
    defer scripted.deinit();
    const io = scripted.io();

    var orch = try makeApp(allocator, &io);
    defer orch.deinit();

    _ = try orch.load(name_reader, gluon.component.root);
    const formal_id = try orch.load(formal_greeter, gluon.component.root);
    _ = try orch.load(printer, gluon.component.root);
    try orch.unloadFiber(formal_id);
    try orch.removeFiber(formal_id);
    _ = try orch.load(casual_greeter, gluon.component.root);
}

test "OOM safety: the full greeter scenario leaks nothing on any failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, appScenario, .{});
}
