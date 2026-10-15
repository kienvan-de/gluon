# Gluon 🪐

A Zig implementation of **[A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512)** — a runtime for components that can be loaded, unloaded, and hot-swapped at runtime without leaving stray side effects or dangling dependencies.

---

## What it does

Gluon lets you compose software out of **components** that are safe to add and remove at runtime:

- **Temporal composability (revertible effects):** every side effect a component performs carries its inverse. On unload, Gluon runs the inverses in LIFO order — the system returns exactly to its prior state.
- **Spatial composability (reactive coeffects):** components declare their dependencies. A component activates only once its dependencies are available, and deactivates automatically when they disappear — load order doesn't matter.

Everything flows through one unified **`Context`** that carries both the environment (coeffects) a component reads and the effects it performs.

```
         ┌────────────────────────────┐
         │        Gluon Runtime        │
         └──────┬───────────────┬──────┘
                ▼               ▼
       ┌────────────────┐ ┌────────────────┐
       │ Spatial Engine │ │ Temporal Engine │
       │  (coeffects /  │ │  (effects /     │
       │  dependency    │ │  LIFO rollback) │
       │  reconcile)    │ │                 │
       └────────────────┘ └────────────────┘
```

---

## A component

A component is an `(inject, provide, apply)` triple. `apply` returns an **effect iterator**: each step performs a side effect and yields its inverse, which Gluon tracks and runs on unload.

```zig
const gluon = @import("gluon");
const db_key = gluon.Key.of(u32, "db.port");

const db_component = gluon.Component{
    .inject = &.{},          // depends on nothing
    .provide = &.{db_key},   // provides db.port
    .apply = dbApply,        // sets db.port, yields a restrict inverse
};

var orch = try gluon.Orchestrator.init(allocator);
defer orch.deinit();

const id = try orch.load(db_component, gluon.component.root);
// orch.isProvided(db_key) == true

try orch.unloadFiber(id);
// orch.isProvided(db_key) == false  — the inverse withdrew it
```

See [`examples/`](examples/) for complete, runnable programs:

| Example | Shows |
|---|---|
| [`readme_quickstart.zig`](examples/readme_quickstart.zig) | the snippet above, plus the Loader, events, and typed keys |
| [`hello_greeter.zig`](examples/hello_greeter.zig) | end-to-end: dependency ordering, provider swap, host I/O |
| [`pattern_a_service.zig`](examples/pattern_a_service.zig) | sharing a service between components via the coeffect store |
| [`pattern_b_eventbus.zig`](examples/pattern_b_eventbus.zig) | pub/sub between components via the EventBus |
| [`examples/ext/`](examples/ext/) | **dynamic plugins** — load `.so`/`.dll`/`.dylib` at runtime via a C ABI |

---

## Dynamic plugins (any language)

Gluon can load compiled shared libraries at runtime through a stable C ABI
([`include/gluon_abi.h`](include/gluon_abi.h)). A plugin written in **C, C++, Zig, Rust, or Go**
exports one symbol and gets the full lifecycle — dependency gating, LIFO
rollback, hot-swap — for free. See [`examples/ext/`](examples/ext/) for the same
plugin written in Zig, C, and Rust.

---

## Installation

Add `gluon` to your `build.zig.zon`:

```zig
.dependencies = .{
    .gluon = .{
        .url = "https://github.com/kienvan-de/gluon/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "gluon-0.1.0-b6bf0N_wBgCGgqtxtMuK_LT74CfStDBnTKxz-zn4xpp9",
    },
},
```

Expose it in `build.zig`:

```zig
const gluon = b.dependency("gluon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gluon", gluon.module("gluon"));
```

---

## Documentation

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — building, testing, architecture, and how the paper maps to the code
- **[plan/building-blocks.md](plan/building-blocks.md)** — the paper-to-module map
- The paper: [arXiv:2608.25512](https://arxiv.org/abs/2608.25512)

---

## License

[MIT](LICENSE).
