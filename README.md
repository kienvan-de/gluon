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

### 1. Defining a Composable Component

```zig
const std = @import("std");
const gluon = @import("gluon");

// 1. Declare the Coeffects (Dependencies/Environment Configuration)
pub const ServerConfig = struct {
    port: u16,
    db_url: []const u8,
};

pub const MyService = struct {
    // Tell Gluon what dependencies this component expects
    pub const coeffects = .{
        .config = ServerConfig,
    };

    // The runtime handles initialization when coeffects are satisfied
    pub fn init(ctx: *gluon.Context) !MyService {
        const cfg = ctx.getCoeffect(.config);
        
        // Let's spawn a hypothetical background web server
        const server = try WebServer.start(cfg.port, cfg.db_url);
        
        // Register a Revertible Effect. 
        // If this component is ever unloaded, Gluon guarantees this action is run.
        try ctx.effect(server, struct {
            fn revert(s: WebServer) void {
                s.stop();
            }
        }.revert);

        std.log.info("MyService started successfully on port {d}", .{cfg.port});
        return MyService{};
    }
};
```

### 2. Loading and Managing Components

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the Gluon Runtime
    var runtime = try gluon.Runtime.init(allocator);
    defer runtime.deinit();

    // 1. Set the environment context (Coeffects)
    try runtime.setCoeffect(.config, ServerConfig{
        .port = 8080,
        .db_url = "postgresql://localhost:5432/db",
    });

    // 2. Load the component. Since its coeffects are satisfied, it immediately activates.
    const component_id = try runtime.loadComponent(MyService);

    // 3. Reconcile Configuration (Spatial Reactivity)
    // Changing the port will trigger an automatic teardown of the old instance,
    // propagation of the new coeffects, and reactivation with the new configuration.
    try runtime.setCoeffect(.config, ServerConfig{
        .port = 9090,
        .db_url = "postgresql://localhost:5432/db",
    });

    // 4. Unload (Temporal Reversion)
    // Under the hood, this triggers the registered `revert` function, stopping the web server cleanly.
    try runtime.unloadComponent(component_id);
}
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
