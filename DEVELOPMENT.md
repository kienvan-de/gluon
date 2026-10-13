# Development

Building, testing, and the internals of Gluon.

---

## Build & test

```sh
zig build test        # unit + integration tests (175 tests, no dlopen)
zig build test-ext    # dynamic-plugin tests: builds .so/.dylib, loads via dlopen
zig build run-hello   # run the hello-greeter example against real stdin/stdout
zig build ext-plugins # build the example plugin shared libraries
```

Add `-Doptimize=ReleaseSafe` for the safe-optimized run. Every error path is
OOM-safe, verified with `std.testing.checkAllAllocationFailures`.

> **Note:** `test-ext` is a separate step (not part of `test`) because it
> compiles shared libraries and runs them as a standalone executable — dlopen
> inside the Zig 0.17 test-runner IPC loop deadlocks on macOS, so the
> integration test runs as a plain `main()` instead of test blocks.

---

## Why Zig

The paper's reference framework (Cordis) is written in a managed environment.
Zig suits a low-level, zero-GC implementation of the Context Paradigm:

- **Zero-overhead abstractions:** `comptime` resolves coeffect requirements and
  generates dependency tables at compile time — no runtime dictionary lookups.
- **Explicit memory management:** the allocator model matches effect-context
  lifetimes exactly, enabling precise allocation tracking and deterministic
  rollback with no garbage collector.
- **Infallible revert paths:** error unions (`!T`) plus `defer`/`errdefer` give
  a natural syntax for the inverse half of every revertible effect.

Three decisions underpin the whole implementation (see `plan/building-blocks.md`):

| # | Constraint | Resolution |
|---|---|---|
| C1 | Zig has no closures | An inverse is a `{state, call, deinit}` triple; the accumulator (`φ`) is an intrusive LIFO stack, not a composed function |
| C2 | Stable Zig had no async | The lifecycle is an explicit state machine driven by a scheduler seam (`.blocking` default, `.evented` over `std.Io`) |
| C3 | `Map(Key, anytype)` is illegal | The store is type-erased: `*anyopaque` + a comptime `TypeId` checked on `get` |

---

## Key concepts

### The unified Context

All components interact with the system through a `Context`, which carries:

- **The environment (coeffects):** upward dependencies and configuration a
  component reads.
- **The side effects (effects):** downward changes and registrations a
  component makes.

### Revertible effects

An effect is a `(do, undo)` pair. When a component binds a port, allocates a
buffer, or spawns a thread, it registers a revertible action. On unload Gluon
runs the registered inverses in LIFO order (`Theorem 16`), returning the
context to its prior state (`Theorem 7`).

### Reactive coeffects

Components declare their requirements as structured keys. If a dependency
becomes unavailable or a config value changes, the runtime deactivates affected
components, propagates the change, and reactivates them when conditions are met
again (`Algorithm 3`, `Algorithm 5`).

---

## A complete component

`apply` returns an effect iterator; each `next` performs one forward effect and
returns its inverse. Gluon tracks the inverse on the fiber's accumulator and
runs it on unload.

```zig
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
    .inject = &.{},
    .provide = &.{db_key},
    .apply = dbApply,
};
```

### Orchestrating

```zig
var orch = try gluon.Orchestrator.init(gpa.allocator());
defer orch.deinit();

const db_id = try orch.load(db_component, gluon.component.root);
std.debug.assert(orch.isProvided(db_key));

try orch.unloadFiber(db_id); // dependents deactivate first, then this reverts
std.debug.assert(!orch.isProvided(db_key));
```

### Declarative loading & HMR

The `Loader` reconciles a declarative config against the running system,
emitting the minimal set of load/unload/reload steps. The quiescent state always
equals a from-scratch load of the final config (`Theorem 80`, confluence).

```zig
var loader = try gluon.Loader.init(allocator);
defer loader.deinit();

try loader.reconcile(&.{ .{ .name = "db", .component = db_component } });
// Re-reconciling the same config is a no-op (reload only on material change).
// Changing a component's code or config value triggers an HMR fiber swap.
// Removing an entry retires and removes it.
```

---

## Architecture

```
                 ┌────────────────────────────────┐
                 │          Gluon Runtime          │
                 └──────┬──────────────────┬───────┘
                        ▼                  ▼
             ┌──────────────────┐  ┌──────────────────┐
             │  Spatial Engine  │  │  Temporal Engine  │
             │   (Coeffects)    │  │     (Effects)     │
             └──────────┬───────┘  └────────┬──────────┘
                        ▼                   ▼
             ┌──────────────────┐  ┌──────────────────┐
             │ Dependency DAG / │  │   LIFO Rollback   │
             │  Reconciliation  │  │     Registry      │
             └──────────────────┘  └──────────────────┘
```

- **Temporal engine:** tracks effect lifespans. As components act through the
  context, Gluon builds an implicit graph of revert actions.
- **Spatial engine:** a DAG of the dependency/config topology. When a coeffect
  changes, it computes the minimal set of components to deactivate/reactivate.

### Source layout

```
src/
├── gluon.zig              public API re-exports
├── effect/               accumulator (φ), effect iterator, execute (Alg 1)
├── coeffect/             store (Σ), spec, interception, key registry
├── context/              the unified Context, TypeId, typed keys
├── component/            Component, Fiber, lifecycle (Alg 3/5), registry
├── event/                EventBus (listeners as revertible effects)
├── loader/               declarative reconcile + HMR + schema config
├── scheduler/            scheduler seam (.blocking / .evented over std.Io)
├── ext/                  dynamic plugins (C ABI, dlopen)
│   ├── gluon_abi.zig       shared ABI types (Zig; no Gluon internals)
│   ├── host.zig            GluonHostApi bridge (C fn ptrs → Context)
│   └── loader.zig          ExtLoader: dlopen wrapper, vtable → Component
└── testing/              invariant checker + randomized schedule property test

include/
└── gluon_abi.h           C header for non-Zig plugin authors

examples/
├── readme_quickstart.zig, hello_greeter.zig
├── pattern_a_service.zig, pattern_b_eventbus.zig
└── ext/                  the same dynamic plugin in Zig, C, and Rust
```

---

## Dynamic plugins (the `ext` subsystem)

A plugin is a shared library exporting one symbol:

```c
const GluonExtVTable* gluon_plugin_vtable(void);
```

The vtable has three functions:

- `meta()` → declares the plugin's `inject`/`provide` keys
- `activate(host)` → the plugin subscribes to events / provides services
- `deactivate(handle)` → the plugin cleans up

Gluon passes a `GluonHostApi` to `activate` that bridges into the runtime:

| Host API call | Routes to | Pattern |
|---|---|---|
| `subscribe` / `unsubscribe` / `emit` | EventBus (JSON `[]const u8` payload) | pub/sub |
| `provide_opaque` / `withdraw_opaque` | coeffect store (`ExtService` wrapper) | shared service |

The plugin never imports any Gluon source — only the ABI contract:

- **Zig plugins:** `@import("gluon_abi")` → `src/ext/gluon_abi.zig`
- **C/C++/Rust/Go plugins:** `#include "gluon_abi.h"` → `include/gluon_abi.h`

Once loaded, a plugin is an ordinary Gluon `Component` — it gets dependency
gating, LIFO rollback, Theorem 70 ordering, and hot-swap exactly like a native
Zig component. `ExtLoader.open(path)` does the `dlopen`, reads the vtable, and
returns the Component.

---

## Theorem coverage (executable)

The paper's metatheory is encoded as tests:

| Theorem / definition | Property asserted |
|---|---|
| Thm 7 | `recover` returns the context to its initial state |
| Thm 16 | inverses run in LIFO order |
| Def 53 / Thm 70 | a provider never withdraws while an installed dependent resolves it |
| Cor 69 | a deactivated provider leaves the store clean |
| Def 52 | retiring a parent cascades to instantiated children (transitive) |
| Thm 80 | reconcile endpoint equals a from-scratch load (confluence) |
| Def 46 / Thm 47 | commutativity witness enforced at load |
| §4.4 Failure | a failed activation installs nothing and withholds re-entry |
| §5.2.2 HMR | a code/config change swaps the fiber, preserving entry identity |

---

## References

```bibtex
@article{shi2026spatiotemporal,
  title={A Programming Paradigm for Spatiotemporal Composability},
  author={Shi, Yifan and Zhang, Wei and Cui, Tianyi},
  journal={arXiv preprint arXiv:2608.25512},
  year={2026}
}
```
