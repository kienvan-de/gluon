# Gluon Building Blocks Analysis

**Source Paper:** [A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512) (arXiv:2608.25512v1)

This document maps every formal construct in the paper to a concrete Zig building block, organized top-down from architectural layers to primitives.

---

## ✅ Implementation Status — ALL PHASES COMPLETE

| Phase | Scope | Module(s) | Tests |
|-------|-------|-----------|-------|
| 1–2 | Effect foundations: accumulator φ, 𝔈Γ, iterator ℑΓ, execute | `effect/accumulator.zig`, `effect/effect_fn.zig`, `effect/effect_iter.zig` | ✅ |
| 3 | Coeffects: TypeId, store Σiso, Context Γ∞, spec/satisfaction/classify | `context/type_id.zig`, `coeffect/store.zig`, `context/context.zig`, `coeffect/spec.zig` | ✅ |
| 4 | Component, Fiber, lifecycle (Alg 5), notify (Alg 3), orchestration | `component/component.zig`, `component/registry.zig`, `component/lifecycle.zig` | ✅ |
| 5 | Orchestration + metatheory (guard, ordering, confluence) | folded into Phase 4 | ✅ |
| 6 | Interception wired into Context (Def 26/27); isolation in store | `coeffect/interception.zig`, `context/context.zig` | ✅ |
| 6.5 | Failure handling (FAILED state) | folded into `lifecycle.zig` (`markFailed`) | ✅ |
| 7 | Loader: reconciliation + HMR | `loader/loader.zig` | ✅ |
| 8 | Commutativity witnesses + comptime gate + load enforcement (Thm 47) | `coeffect/key_registry.zig`, `component/lifecycle.zig` | ✅ |

**78 tests, all passing in Debug and ReleaseSafe.** Every error path is
OOM-safe (verified via `std.testing.checkAllAllocationFailures`, which found
and fixed ~10 real/latent leaks during reviews).

**Property/theorem coverage (executable):** Thm 7 (soundness invariant),
Thm 16 (LIFO revert), Thm 10/11 (monoid), Def 22 (reactive classification),
Def 53 (provided-by), Def 54 / Thm 70 (ordering guard), Cor 69 (terminal
recovery), Def 52 (instantiation cascade, transitive), Thm 80 (confluence /
reconcile-endpoint = from-scratch load), Def 44/46/47 (commutativity witness,
comptime-gated AND enforced at load), §4.4 Failure (FAILED route), §5.2.2 HMR
(fiber swap), Def 26/27 (interception merge, context-carried 𝜄).

Run: `zig build test` (add `-Doptimize=ReleaseSafe` for the safe-optimized run).

---

## 🔍 Implementation vs. Plan — Fidelity Notes

A post-implementation audit mapped every plan item to code. Summary of items
that are **realized differently than the plan literally wrote**, or that are
**intentionally not runtime-enforced**:

| Plan item | Status | Note |
|-----------|--------|------|
| 1.2 Effect Composition `⋄` (Def 9) | Operational | No standalone `compose(f,g)` combinator; realized by `applySequence`/`execute` folding inverses. The monoid is exercised through sequence recovery (Thm 7/16) rather than a direct `⋄` law test. |
| 1.4 Effect Lifting `effectΓ` (Def 12) | Operational | No named `effectΓ : 𝔈Γ → 𝔈∂Γ` function. The ∂²Γ recursion is realized by `Context.derive`'s parent-composition (a child's `dispose` is prepended to the parent's accumulator), tested via the parent→child cascade. |
| 4.5 Confinement (Def 55) | **Not enforced** | The runtime does not restrict a fiber's writes to its declared `inject ∪ provide`. The paper itself treats confinement as a *discipline consequence* of the context-mediated iterator form, not a runtime check (§5.1.1: “an obligation on the component author rather than a property the runtime verifies”). A buggy component could write foreign keys. Enforcing it would require per-fiber write interposition on the store — deferred as out of scope. |
| 6.2 Observational Equivalence `≃ₖ` (Def 31) | Conceptual | Represented as `CommutativityKind` (the *evidence* a key's equivalence rests on) rather than a runtime relation. Values compare by exact equality; `≃ₖ` is a design-time notion the witness documents. |
| Eq. 46 (σ_γ = union over ACTIVE fibers) | Emulated | The physical store is a flat shared table, not a per-fiber-table union. The *satisfaction* layer emulates Eq. 46 exactly — `isProvided` requires `phase == .active`, so a loading/unloading provider's binding is not observable to dependents. `ctx.get` reads the flat store directly; the “not-yet-visible” invariant holds because the lifecycle gates *when* consumers run, not by structural partitioning. |
| 3.4 `ctx.use` (Alg 4) | Named `Orchestrator.load` | Instantiation is driven by the orchestrator rather than a `ctx.use` method; the Def 52 cascade (child retire on parent unload) is wired via `retireChildren`. |

Everything else in the plan is implemented as written and tested.

---

## 🏗️ Building Block Hierarchy

### **Layer 0: Foundation Primitives** (Paper: §3.1, §3.2, §3.3.1)

| # | Building Block | Paper Section | Responsibility |
|---|----------------|---------------|----------------|
| 0.1 | **Context Type (`Γ∞`)** | §3.3.1, Def 28 | Recursive unified context: `struct { state: Γ, accumulator: Γ→Γ, coeffects: Σ }` |
| 0.2 | **Effect Context (`∂Γ`)** | §3.1.1, Def 2 | Pair `(γ, φ)` where `φ: Γ→Γ` accumulates inverses (LIFO rollback) |
| 0.3 | **Coeffect Context (`Σ`)** | §3.2.1, Def 19 | Dependent partial function `K ⇀ Vₖ` — typed dependency table |
| 0.4 | **Twisted Composition Monoid (`𝔗Γ`)** | §3.1.1, Def 1 | `(f₁,g₁) ∘ (f₂,g₂) = (f₁∘f₂, g₂∘g₁)` — composes effects with inverse order |
| 0.5 | **Track/Recover** | §3.1.1, Def 3,6 | `track(f,g)(γ,φ) = (f(γ), φ∘g)`; `recover(γ,φ) = (φ(γ), id)` |

---

### **Layer 1: Effect System** (Paper: §3.1.2–3.1.3, §5.1.1)

| # | Building Block | Paper Section | Zig Mapping |
|---|----------------|---------------|-------------|
| 1.1 | **Witnessed Effect Function (`𝔈Γ*`)** | §3.1.2, Def 8 | `fn(ctx: *Context) !EffectResult` returning `{ new_ctx, inverse: fn(Context) void }` |
| 1.2 | **Effect Composition (`⋄`)** | §3.1.2, Def 9 | Chains effects: `f ⋄ g = γ → let (δ,s)=g(γ); (ε,t)=f(δ) in (ε, s∘t)` |
| 1.3 | **Effect Iterator (`ℑΓ`)** | §3.1.3, Def 17 | Generator yielding `{ δ, inverse, continuation? }` — maps to Zig `std.Iterator` |
| 1.4 | **Effect Lifting (`effectΓ`)** | §3.1.2, Def 12 | ⚠️ Realized operationally via `Context.derive` parent-composition, not a named `effectΓ`. See Fidelity Notes. |
| 1.5 | **`ctx.effect(callback, guard)`** | §5.1.1, Alg 1 | **Core primitive** — executes iterator, folds inverses, returns `dispose()` closure |

---

### **Layer 2: Coeffect System** (Paper: §3.2.1–3.2.3, §5.1.2)

| # | Building Block | Paper Section | Zig Mapping |
|---|----------------|---------------|-------------|
| 2.1 | **Coeffect Specification (`𝔇Γ`)** | §3.2.2, Def 21 | `struct { inject: []const CoeffectKey }` — declared dependencies |
| 2.2 | **Coeffect Provision (`𝔓Γ`)** | §4.1, Def 48 | `struct { provide: []const CoeffectKey }` — keys this component installs |
| 2.3 | **`ctx.get(key)` / `ctx.set(key, value)`** | §3.2.1, Def 20 | Read/write through realm indirection `ρ(k) → σ(ρ(k))` |
| 2.4 | **Reactive Notification (`notify_d`)** | §3.2.2, Def 22 | Classifies transitions: *activating* / *deactivating* / *neutral* |
| 2.5 | **Isolation (`ctx.isolate`)** | §3.2.3, Def 24–25 | Derives child context with overridden realm table `ρ[k ↦ r]` |
| 2.6 | **Interception (`ctx.intercept`)** | §3.2.3, Def 26–27 | ✅ `ctx.intercept(key, meta, merge, free)` merges into context-carried `𝜄` (right-biased); `ctx.interceptOf(key)` reads it. Per-context table, derived realization. |
| 2.7 | **`notify(ctx, keys)`** | §5.1.2, Alg 3 | Propagates changes to dependent fibers, calls `refresh(fiber)` |

---

### **Layer 3: Component & Fiber** (Paper: §4.1, §5.1.3)

| # | Building Block | Paper Section | Zig Mapping |
|---|----------------|---------------|-------------|
| 3.1 | **Component (`ℭΓ`)** | §4.1, Def 48 | `struct { inject: []Key, provide: []Key, apply: EffectIterator }` |
| 3.2 | **Fiber** | §4.1, Def 49 | Runtime instance: `{ component, parent, ctx, state, accumulator, committed_view, target_view, inertia }` |
| 3.3 | **Lifecycle State (`ΘΓ`)** | §4.1, Def 43 + §4.4 | Tagged union: `INACTIVE \| LOADING(iter, acc, view) \| ACTIVE(acc, view) \| UNLOADING(acc, view) \| FAILED(err)`. `FAILED` carries the error outcome of §4.4 |
| 3.8 | **Failure Handling** | §4.4 (Failure) | A raise exits `RELOADING` via the aborting-`L-Divert` route (premise on target dropped), lands `INACTIVE` having installed nothing (Cor 69), records error on fiber, withholds re-entry (`L-Begin` requires error-free fiber). Failure stays on the fiber, siblings keep running |
| 3.4 | **`ctx.use(component, config)`** | §5.1.3, Alg 4 | Instantiates fiber, binds config into `apply`, registers `callback` as parent effect |
| 3.5 | **`refresh(fiber)`** | §5.1.3, Alg 5 | Recomputes `target_view`; initiates `reload` or `unload` task |
| 3.6 | **`reload(fiber)`** | §5.1.3, Alg 5 | Runs `execute(fiber.apply, guard)`; on success → `ACTIVE` + `notify`; on target change → `unload` |
| 3.7 | **`unload(fiber)`** | §5.1.3, Alg 5 | `await` dependents; `fiber.dispose()`; clears `committed`; chains to `reload` if target changed |

---

### **Layer 4: Orchestration & Calculus** (Paper: §4.2, §4.3)

| # | Building Block | Paper Section | Responsibility |
|---|----------------|---------------|----------------|
| 4.1 | **Registry (`F_γ`)** | §4.1, Def 50 | `Map<FiberId, Fiber>` — fiber tree rooted at `root` |
| 4.2 | **Orchestration Rules** | §4.2.1 | `O-Insert`, `O-Retire`, `O-Remove` — external API: `load`, `unload`, `replace` |
| 4.3 | **Lifecycle Rules** | §4.2.2 | `L-Begin`, `L-Iter`, `L-Finish`, `L-Divert`, `L-Leave`, `L-Unload` — implemented in `refresh/reload/unload` |
| 4.4 | **Guard (`¬relied_n`)** | §4.2.2, Def 54 | Blocks provider unload until all dependents deactivated |
| 4.5 | **Confinement** | §4.2.3, Def 55 | ⚠️ NOT runtime-enforced (paper treats it as a discipline, not a check). See Fidelity Notes. |

---

### **Layer 5: Component Loader** (Paper: §5.2)

| # | Building Block | Paper Section | Responsibility |
|---|----------------|---------------|----------------|
| 5.1 | **Declarative Config** | §5.2.1 | Load component from config: `{ component, config, realms?, enabled? }` |
| 5.2 | **Configuration Reconciliation** | §5.2.1 | Diff old vs new config → compute minimal `disable`/`enable`/`reload`/`realm-reassign` ops |
| 5.3 | **Hot Module Replacement (HMR)** | §5.2.2 | Swap component code at runtime: retire old fiber, insert new fiber at same `uid`, preserve identity |

---

### **Layer 6: Observational Equivalence & Independence** (Paper: §3.3.2, §3.4)

| # | Building Block | Paper Section | Zig Mapping |
|---|----------------|---------------|-------------|
| 6.1 | **Coeffect Operations (`𝒜ₖ`)** | §3.3.1, Def 29 | Per-key operations with witness: `{ value_type, ops: []Op, commutativity_proof }` |
| 6.2 | **Observational Equivalence (`≃ₖ`)** | §3.3.2, Def 31 | Indistinguishability under key's operations — for Zig: structural equality of exposed API |
| 6.3 | **Commutativity Witness** | §3.4.2, Def 46 | ✅ `CommutativityWitness` on `Component.provide_witness`; comptime `assertCommutative` gate AND runtime enforcement in `load` (rejects non-commutative provisions). |
| 6.4 | **Pairwise Independence** | §3.4.1, Def 42 | ✅ `P₁∩S₂ = P₂∩S₁ = ∅` enforced by registry single-source; shared-key commutativity reduces (Thm 45) to each provider's witness, checked at `load`. |

---

---

## ⚡ Zig Correctness Foundations (read before any code)

These three decisions underpin the entire implementation. Getting them wrong means rewriting Layers 0–3.

### C1. No Closures → Context-Pointer + Fn-Pointer Pairs

The paper assumes first-class closures everywhere (`φ: Γ→Γ`, yielded inverses, `dispose`). **Zig has no closures.** Every function value that captures state must be modeled explicitly:

```zig
/// A revertible action: the inverse `g` of Definition 8, carrying its captured state.
pub const Inverse = struct {
    state: *anyopaque,                         // captured environment (heap-owned)
    call: *const fn (state: *anyopaque, ctx: *Context) void,
    free: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,
};
```

- **Accumulator (`φ`)** is NOT a composed function — it is an **intrusive singly-linked list of `Inverse` nodes**, prepended on each `track` (LIFO), walked head-to-tail on `recover`.
- **Composition `g₂ ∘ g₁`** (Def 1 twisted order) = list prepend; `recover` = iterate + each `free`.
- Every `Inverse` is **heap-allocated** and owned by the fiber's accumulator; `unload` frees them after calling.

### C2. No `async`/`await` → Explicit Lifecycle State Machine

Stable Zig has no `async`/`await`. The inertia model (§4.4, §5.1.3 `fiber.inertia`) is **core to correctness, not optional** — it is what makes `L-Divert`/reload-unload chaining safe. Commit to an **explicit state machine driven by a scheduler queue**, not language coroutines.

- `fiber.inertia` becomes a `?TransitionHandle` (index into a pending-transition queue), not a coroutine handle.
- `reload`/`unload` are **step functions** the scheduler pumps; each returns `.pending \| .done` so a transition can span many scheduler ticks (modeling the paper's "transition spread over an interval").
- The host decides sync vs async by how it pumps the queue. **Inertia = "a transition in flight runs to completion before responding to a new target"** — enforced by: while `fiber.inertia != null`, `refresh` only updates `target_view` and returns (Alg 5 Line 5).
- This is a **Phase-4 blocking design decision** — resolve the scheduler shape before writing `fiber.zig`.

### C3. Type-Erased Coeffect Store → `*anyopaque` + comptime `TypeId`

`Map(RealmId, anytype)` is **not legal Zig** (`anytype` is not a storable type). The store `σ : (r:R) ⇀ Vᵣ` must be type-erased:

```zig
pub const CoeffectKey = struct {
    name: []const u8,
    type_id: TypeId,                 // comptime-stable id of Vₖ, checked on get()
};

const StoredValue = struct { ptr: *anyopaque, type_id: TypeId };
// @@store:    AutoHashMap(RealmId, StoredValue)
// @@isolate:  AutoHashMap(CoeffectKey, RealmId)      // ρ, default ρ(k)=k
// @@intercept:AutoHashMap(CoeffectKey, Metadata)     // 𝜄
```

- `ctx.get(key)` resolves `ρ(k)` → reads `σ(ρ(k))`, asserts `type_id` match, `@ptrCast`/`@alignCast` back to `Vₖ`.
- Keys are **registered at comptime** (`coeffect_keys/key_registry.zig`) so `TypeId` and the operation set `𝒜ₖ` are statically known.
- The static type-safety of Def 19's dependent `𝒱` is recovered by the comptime `TypeId` check, not by Zig's type system directly.

---

## 📦 Suggested Zig Module Structure

```
src/
├── gluon.zig                    // Public API re-exports
├── context/
│   ├── context.zig              // Γ∞ - unified context type
│   ├── effect_context.zig       // ∂Γ - effect context + accumulator
│   ├── coeffect_context.zig     // Σ - coeffect store + realm + intercept tables
│   └── operations.zig           // get/set/isolate/intercept
├── effect/
│   ├── effect_fn.zig            // 𝔈Γ - witnessed effect function type
│   ├── effect_iter.zig          // ℑΓ - effect iterator (generator)
│   ├── composition.zig          // ⋄ - effect composition
│   ├── lifting.zig              // effectΓ - lift to ∂Γ
│   └── tracker.zig              // ctx.effect() - Alg 1 (execute + dispose)
├── coeffect/
│   ├── spec.zig                 // 𝔇Γ - inject specification
│   ├── provision.zig            // 𝔓Γ - provide declaration
│   ├── notification.zig         // notify_d - reactive classification
│   ├── isolation.zig            // isolate - realm derivation
│   ├── interception.zig         // intercept - metadata merge
│   └── notifier.zig             // notify() - Alg 3 (propagation)
├── component/
│   ├── component.zig            // ℭΓ - component definition
│   ├── fiber.zig                // Fiber - runtime instance + lifecycle state
│   ├── lifecycle.zig            // refresh/reload/unload - Alg 4,5
│   └── registry.zig             // F_γ - fiber registry + tree
├── orchestration/
│   ├── orchestrator.zig         // O-Insert/Retire/Remove - public API
│   └── rules.zig                // Lifecycle rule implementations
├── loader/
│   ├── config.zig               // Declarative configuration schema
│   ├── reconciler.zig           // Configuration diff + minimal ops
│   └── hmr.zig                  // Hot module replacement
└── coeffect_keys/
    ├── key_registry.zig         // Global key registry with 𝒜ₖ + commutativity witness
    └── builtin_keys.zig         // Common keys: logger, config, http, db, etc.
```

---

## 🎯 Implementation Priority Order

| Phase | Components | Paper Validation |
|-------|------------|------------------|
| **Phase 1** | Context, Effect Context, Coeffect Context, Track/Recover | §3.1.1, §3.2.1, §3.3.1 |
| **Phase 2** | `ctx.effect()`, Effect Iterator, Effect Composition | §3.1.2, §3.1.3, §5.1.1 |
| **Phase 3** | Coeffect Spec/Provision, get/set, notify | §3.2.1, §3.2.2, §5.1.2 |
| **Phase 4** | Component, Fiber, Lifecycle (refresh/reload/unload) | §4.1, §4.2.2, §5.1.3 |
| **Phase 5** | Orchestration (load/unload), Registry, Guard | §4.2.1, §4.3.1–4.3.3 |
| **Phase 6** | Isolation, Interception | §3.2.3, §5.1.2 |
| **Phase 6.5** | Failure handling (`FAILED` state, raise → abort route) | §4.4 (Failure) |
| **Phase 7** | Loader (Config Reconciliation, HMR) | §5.2 |
| **Phase 8** | Commutativity Witnesses, Key Registry | §3.4, §4.3.2–4.3.5 |

---

## ⚠️ Key Zig-Specific Design Decisions

| Paper Concept | Zig Implementation Strategy |
|---------------|----------------------------|
| **Effect Iterator (`ℑΓ`)** | `std.Iterator` yielding `EffectStep{ ctx: *Context, inverse: fn(*Context) void, done: bool }` |
| **Accumulator (`φ: Γ→Γ`)** | Composed `fn(*Context) void` closures — prepended for LIFO |
| **Recursive Context (`Γ∞`)** | `Context` struct with `parent: ?*Context` — derived contexts for isolation |
| **Realm Indirection** | `Map(CoeffectKey, RealmId)` → `Map(RealmId, anytype)` — type-erased store with comptime key registration |
| **Commutativity Witness** | `comptime` verification on key registration: `fn check_commutative(comptime Ops: []Op) void` |
| **Async/Lifecycle** | **Explicit state machine** (see C2) — stable Zig has no `async`/`await`; `fiber.inertia` = pending-transition handle, pumped by a scheduler |
| **Closures / Accumulator** | **No closures in Zig** (see C1) — `Inverse = { state: *anyopaque, call, free }`; accumulator is an intrusive LIFO list, not a composed fn |
| **Observational Equivalence** | Structural equality on exposed operations — no runtime cost, compile-time guarantee |

---

## 🔑 Core Insight

> **`ctx.effect()` (Algorithm 1) is the single primitive everything else builds on.**
>
> - Coeffect `set` is just an effect
> - Component lifecycle is just effects with a guard
> - The loader is just orchestration rules
> - Isolation/Interception are derived contexts (no tracking needed)

This means the **entire implementation rests on getting `ctx.effect()` right** — the execute loop, inverse folding, guard checking, and parent composition (`dispose ∘ ctx.dispose`).

---

## ✅ Property-Based Validation Strategy

The paper's metatheory is a set of **testable invariants**. Each theorem maps to a property-test suite (Zig `test` blocks + a small generator of orchestration sequences). Build these alongside the phases they validate.

| Theorem / Property | Paper | What to assert | Validates Phase |
|--------------------|-------|----------------|-----------------|
| **Soundness invariant** `φ(γ) ≃ γ₀` | Thm 7 | After any tracked effect sequence, `recover` returns the context to its start state (up to `≃ₖ`) | 1–2 |
| **track is a monoid hom** | Thm 5 | `track(f₁∘f₂, g₂∘g₁) = track(f₁,g₁) ∘ track(f₂,g₂)` on random pairs | 2 |
| **effect preserves `⋄`** | Thm 13 | `effect(f) ⋄ effect(g) = effect(f ⋄ g)` | 2 |
| **LIFO revert** | Thm 16 | Reverting a sequence in reverse order recovers each intermediate state | 2 |
| **Reactive classification** | Def 22 | Every satisfaction flip is detected as activating/deactivating; neutral changes are no-ops (idempotent `refresh`) | 3–4 |
| **Preservation** (registry well-formed) | Thm 64 | After every orchestration/lifecycle step, Def 63 clauses 1–4 still hold | 5 |
| **Recovery Exactness** | Thm 68 | Applying fiber `n`'s accumulator at any later state leaves every table where the same steps would from the pre-episode state (`≃_K`) | 5 |
| **Terminal Recovery** | Cor 69 | On episode close, `σ_n = ∅` (nothing leaked) | 5 |
| **Ordering** (guard) | Thm 70 | A provider never withdraws a binding while an installed dependent still resolves it | 5 |
| **Resolution Coherence** | Thm 71 | No single transition straddles two resolutions of its coeffects | 4–5 |
| **Progress** (no deadlock + termination) | Thm 73 | Under acyclic `≺`, every maximal lifecycle run reaches a quiescent state | 5 |
| **Confluence** | Thm 80 | Any schedule of the same inputs quiesces at the same state (up to renaming + `≃`) — i.e. runtime history leaves no trace vs. from-scratch load | 5, 7 |
| **Independence/commutativity** | Thm 43, 47 | Reordering independent effects' inverses still reaches `γ₀`; distinct-key ops commute | 8 |

**Test harness shape:** a generator emits random well-formed sequences of `O-Insert / O-Retire / O-Remove` over a fixed component pool with declared `inject`/`provide`; the runner pumps the scheduler to quiescence; assertions check the invariants above. Confluence (Thm 80) is tested by running the **same input set under multiple random schedules** and comparing the quiescent registries up to renaming.