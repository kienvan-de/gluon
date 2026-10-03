# Gluon 🪐

An elegant, high-performance implementation of **[A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512)** in the **Zig** programming language.

---

## 📖 Overview

In modern software systems—ranging from dynamic plugin architectures to self-evolving LLM agent harnesses—components must be composed, reconfigured, and hot-swapped at runtime. Traditional programming paradigms lack the formal foundations to guarantee that components can be cleanly added or removed without leaving stray side effects or dangling dependencies.

**Gluon** solves this by implementing the core primitives of **Spatiotemporal Composability** as described by Yifan Shi, Wei Zhang, and Tianyi Cui (2026):

1. **Temporal Composability (Revertible Effects):** The guarantee that any side effect introduced by a component's activation can be completely and safely reverted upon its removal. Every context-transforming effect carries its mathematical inverse.
2. **Spatial Composability (Reactive Coeffects):** The ability to declare and reactively manage inter-component dependencies. When a component's dependency or configuration environment changes, the runtime automatically activates or deactivates components to satisfy the spatial topology.

By unifying **Effects** and **Coeffects** into a single, cohesive **Context** type (the *Context Paradigm*), Gluon enables robust dynamic composition, configuration reconciliation, and hot module replacement with compile-time type-safety and zero-cost abstraction in Zig.

---

## ⚡ Why Zig?

While the reference meta-framework (Cordis) is written in dynamic/managed environments, **Zig** is uniquely suited for a low-level, high-performance implementation of the Context Paradigm:

- **Zero-Overhead Abstractions:** Zig's `comptime` allows us to resolve coeffect requirements and generate component dependency tables at compile time, eliminating dictionary lookups and runtime overhead.
- **Explicit Memory Management:** Spatiotemporal tracking requires strict control over resources. Zig’s allocator model matches the lifetime of effect contexts perfectly, allowing precise allocation tracking and deterministic rollbacks without a garbage collector.
- **Safety and Predictability:** Revertible effects require rock-solid error handling. Zig's error union types (`!T`) and `defer` / `errdefer` semantics provide a natural syntax for defining infallible revert paths.

---

## 🛠️ Key Concepts

### 1. The Unified Context (`Context`)
In Gluon, all components interact with the system solely through a `Context`. The context manages both:
* **The Environment (Coeffects):** Upward dependencies and configurations required by the component.
* **The Side Effects (Effects):** Downward changes and registrations made by the component.

### 2. Revertible Effects
An effect is not just an action; it is a pair of `(do, undo)`. When a component performs a side effect (e.g., binding to a port, allocating a buffer, spawning a thread), it registers a revertible action. When the component is unloaded, Gluon executes the registered rollbacks in LIFO (Last-In, First-Out) order.

### 3. Reactive Coeffects
Components declare their requirements (coeffects) as structured data. If a dependent service becomes unavailable, or if configuration parameters change, the Gluon runtime automatically deactivates affected components, propagates the updates, and reactively re-activates them when conditions are met.

---

## 🚀 Quick Start

Here is a conceptual example of how to declare and run a spatiotemporally composable component using Gluon in Zig.

### 1. Defining a Component

A component is a `(inject, provide, apply)` triple. `apply` returns an **effect
iterator**: each step performs a side effect and yields its **inverse**, which
Gluon tracks and runs in LIFO order on unload.

```zig
const std = @import("std");
const gluon = @import("gluon");

const Context = gluon.Context;
const Key = gluon.Key;

// A coeffect key: a logical name + the type of its value.
const db_key = Key.of(u32, "db.port");

// A database component: it PROVIDES `db.port` on activation and withdraws it
// (automatically, via the tracked inverse) on deactivation.
fn dbApply(ctx: *Context, _: ?*anyopaque) anyerror!Context.Iterator {
    const Iter = struct {
        fn make(a: std.mem.Allocator) !Context.Iterator {
            const self = try a.create(@This());
            self.* = .{};
            return .{ .state = self, .next_fn = next, .deinit_fn = deinit };
        }
        fn next(_: *anyopaque, a: std.mem.Allocator, c: *Context) anyerror!gluon.effect_iter.Step(Context) {
            try c.store.set(u32, db_key, 5432); // forward effect: provision
            const kb = try a.create(Key);
            kb.* = db_key;
            const Inv = struct { // the inverse Gluon holds and runs on unload
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
    .inject = &.{}, // depends on nothing
    .provide = &.{db_key}, // provides db.port
    .apply = dbApply,
};
```

### 2. Orchestrating Components

The `Orchestrator` loads, retires, and removes components, driving the reactive
lifecycle: a consumer activates only once its dependencies are provided, and a
provider's withdrawal is deferred until its dependents have deactivated
(Theorem 70 ordering).

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var orch = try gluon.Orchestrator.init(gpa.allocator());
    defer orch.deinit();

    // Load the provider. With no unmet dependencies, it activates immediately
    // and provisions db.port into the shared context.
    const db_id = try orch.load(db_component, gluon.component.root);
    std.debug.assert(orch.isProvided(db_key));

    // Unload (Temporal Reversion): the tracked inverse withdraws db.port.
    // Any dependents are deactivated first, then this fiber's effects revert.
    try orch.unloadFiber(db_id);
    std.debug.assert(!orch.isProvided(db_key));
}
```

### 3. Declarative Loading & Hot Module Replacement

The `Loader` reconciles a declarative configuration against the running system,
emitting the minimal set of load/unload/reload steps. Swapping a component's
code hot-replaces its fiber while preserving the logical entry identity.

```zig
var loader = try gluon.Loader.init(allocator);
defer loader.deinit();

// Bring the system up to match a desired configuration.
try loader.reconcile(&.{
    .{ .name = "db", .component = db_component },
});

// Re-reconciling with the same config is a no-op (reload only on real change).
// Changing a component's code triggers an HMR swap of its fiber.
// Removing an entry retires and removes it. The quiescent state always equals
// a from-scratch load of the final config (Theorem 80, confluence).
```

---

## 🏗️ Architecture

```
                 ┌────────────────────────────────┐
                 │       Gluon Runtime            │
                 └──────┬──────────────────┬──────┘
                        │                  │
                        ▼                  ▼
             ┌──────────────────┐  ┌──────────────────┐
             │  Spatial Engine  │  │ Temporal Engine  │
             │   (Coeffects)    │  │     (Effects)    │
             └──────────┬───────┘  └────────┬─────────┘
                        │                   │
                        ▼                   ▼
             ┌──────────────────┐  ┌──────────────────┐
             │ Dependency DAG / │  │   LIFO Rollback  │
             │  Reconciliation  │  │     Registry     │
             └──────────────────┘  └──────────────────┘
```

- **Temporal Engine:** Keeps track of effect lifespans. As components perform actions through the context, Gluon builds an implicit graph of revert actions.
- **Spatial Engine:** A directed acyclic graph (DAG) representing the dependency and configuration topology. Whenever a coeffect is mutated or removed, the engine calculates the minimum spanning set of affected components that need deactivation and reactivation.

---

## 📦 Installation

Add `gluon` to your `build.zig.zon`:

```zig
.{
    .name = "my_project",
    .version = "0.1.0",
    .dependencies = .{
        .gluon = .{
            .url = "https://github.com/kienvan-de/gluon/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...", // Replace with actual hash
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

And expose it in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gluon = b.dependency("gluon", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("gluon", gluon.module("gluon"));
    b.installArtifact(exe);
}
```

---

## 📚 References

If you are interested in the theoretical background, please refer to the original paper:

```bibtex
@article{shi2026spatiotemporal,
  title={A Programming Paradigm for Spatiotemporal Composability},
  author={Shi, Yifan and Zhang, Wei and Cui, Tianyi},
  journal={arXiv preprint arXiv:2608.25512},
  year={2026}
}
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
