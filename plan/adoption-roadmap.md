# Gluon Adoption Roadmap — Features Worth Taking from Cordis

**Status:** exploratory / reference. Nothing here is committed to the codebase
yet. This document captures a detailed comparison of Gluon against **Cordis**
(the reference meta-framework of arXiv:2608.25512, the TypeScript library that
Koishi is built on) and a prioritized list of features worth adopting, ordered
by **Zig 0.16.x readiness**.

> ⚠️ **Knowledge caveat.** Cordis specifics below are a best-effort
> reconstruction from the paper (Table 2 especially) plus general TypeScript-
> ecosystem knowledge of the real `cordis` / Koishi design. They are not
> verified against a specific Cordis version. Treat them as "informed
> reference," not authoritative API.

---

## 1. Where Gluon stands vs. Cordis

| Dimension | Winner | Notes |
|-----------|--------|-------|
| Context access ergonomics | **Cordis** | Proxy + TS declaration merging (`ctx.database`); we use explicit `ctx.get(V, key)` (Zig has no `Proxy`) |
| Reactive coeffect lifecycle | **Tie** | Our `refresh`/`reload`/`unload` state machine *is* the formalization of their fork/scope behavior (§4.2/§4.3) |
| **Async / inertia** | **Cordis** | Biggest capability gap — we are synchronous run-to-completion (was C2); see §3 below |
| Isolation (realms) | **Tie** | Both implement Def 24/25 |
| Event system (`on`/`emit`) | **Cordis** | We have the primitive (revertible effects) but not the API |
| Config schema/validation | **Cordis** | We reconcile (Thm 80 endpoint) but config is opaque `?*anyopaque` |
| Interception | **Tie-ish** | Both implement Def 26/27; theirs is proxy-integrated, ours exposes `interceptOf` |
| Commutativity enforcement | **Gluon** | We enforce the Def 46 witness at `load` (Thm 47); unclear Cordis does |
| Memory safety / leak discipline | **Gluon** | OOM-injection testing, explicit ownership, no GC |
| Executable theorem coverage | **Gluon** | Property tests mapped to Thm 7/16/70/80, Cor 69, Def 52 |
| Maturity / ecosystem | **Cordis** | 4000+ community plugins vs. our 77 tests |

**Summary:** Gluon is a *sound, verified, synchronous subset* of what Cordis
offers. We match or exceed on rigor and memory safety; Cordis leads on async,
ergonomics, and application-level layers (events, schema config).

---

## 2. Zig 0.16 changes the async picture

The original plan (decision **C2**) assumed stable Zig has no `async`/`await`
and committed to a synchronous scheduler. **This is now outdated.** Zig 0.16
ships `std.Io`:

- `std.Io.async(fn, args) -> Future(T)` and `std.Io.concurrent(...)`
- `Future(T).await(io)` and `Future(T).cancel(io)` (cooperative cancelation
  surfacing as `error.Canceled` at the next cancelation point)
- `std.Io.Group` for spawning/awaiting a set of tasks
- Two concrete implementations in std: **`Io.Threaded`** (thread pool, ~19k LOC,
  real) and **`Io.Uring`** (io_uring)

The async-inertia gap is therefore **no longer a hard language limitation** — it
is a dependency-maturity tradeoff (`std.Io` is new and will churn across
0.16.x → 0.17).

> **Supersedes plan/building-blocks.md decision C2.** That document (an archived
> record of the completed build) committed to a synchronous explicit state
> machine on the premise that stable Zig had no async. That premise is now
> outdated. building-blocks.md is intentionally left unchanged as a historical
> record; this roadmap is the live view. The synchronous model it describes
> remains correct — it is the degenerate schedule, and is what the current
> implementation uses — so async is an additive upgrade, not a correction.

---

## 3. Deep dive: async inertia (§4.4) → `std.Io`

Cordis realizes the paper's inertial `UNLOADING` with Promises:

```
refresh():  recompute target
            if inertia != null: update target only, return   // don't interrupt
            else: start reload/unload, store its Promise in inertia

reload():   commit view; await execute(apply, guard)          // async
            if target still matches: ACTIVE else chain unload  // inertial chaining

unload():   await all(dependents.map(d => d.await()))          // drain (async)
            await dispose()                                    // async teardown
            INACTIVE, or chain into reload()
```

The two `await` points in `unload` are what the synchronous model cannot
express: awaiting a departing dependency's async teardown (e.g. closing a
connection pool — the paper's own §4.2.2 motivating example).

**Direct 0.16 mapping:**

| Cordis (Promise) | Zig 0.16 `std.Io` |
|------------------|-------------------|
| `const p = reload()` | `var fut = io.async(reload, .{...})` → `Future(void)` |
| `fiber.inertia = p` | `fiber.inertia: ?Future(void)` |
| `await p` | `fut.await(io)` |
| `p.cancel()` (L-Divert abort) | `fut.cancel(io)` → cooperative `error.Canceled` |
| `await all(deps…)` | `std.Io.Group` + `group.await(io)` |
| Node event loop | `Io.Threaded` or `Io.Uring` (both in std) |

`Future.cancel`'s "surfaces at the next cancelation point" semantics match the
paper's "abort at an iteration boundary" (§4.2.2 L-Divert) almost exactly.

**Migration shape (additive, not a rewrite):** our `reload`/`unload` are already
discrete functions returning `LifecycleError!void` (the C2 step-function design).
Converting is mechanical:
- `fiber.in_transition: bool` → `fiber.inertia: ?Future(void)`
- `drainDependents`'s `while(changed)` busy-loop → `Group.await` over dependents
- `targetGuard.poll` → a cancelation-point / `CancelProtection` check

The synchronous version stays valid as the degenerate schedule (every §4.3
theorem quantifies over all schedules, including synchronous), so async is
purely additive.

---

## 4. Prioritized adoption list (by Zig 0.16.x readiness)

### Tier 1 — Ready now · pure library code · zero new deps

**1. `{ required, optional }` dependency distinction** — ✖ **EXCLUDED — the paper defines the opposite (verified 2026-10)**
- Split `inject` into required (gates activation) vs optional (reactive but
  non-gating). A struct-field change + a tweak to `computeTarget`/satisfaction.
- *Value (as a Cordis ergonomic):* High. But it is **incompatible with the
  paper's calculus**, confirmed by reading the paper text (not memory):
  - **Def 21** (§3.2.2): `𝔇Σ ≔ Set(K)` — a flat set of keys, with **no**
    required/optional annotation.
  - **Def 22 / Eq. 22:** `σ ⊧ d ≔ ∀k ∈ d. k ∈ dom(σ)` — satisfaction is
    universally quantified: **every** declared key must be present. Binary
    classification (activating/deactivating/neutral) only.
  - §3.2.2 **explicitly rejects** the optional behavior: "a component should
    activate only once **all** the dependencies it declares are present,
    **rather than accessing them optimistically and failing when one is
    missing**." An optional dep is exactly that optimistic access.
  - The word "optional" (and non-gating / soft / weak / partial-satisfaction /
    best-effort) appears **0 times** in all 92 pages.
- Adopting it would require a richer `𝔇Σ` than Def 21 and a weaker satisfaction
  relation than Eq. 22, breaking the local-composability criterion the paper
  proves and the coeffect half of Thm 70 — and would move our code (which
  already encodes `∀k ∈ d` in `spec.zig`) **away** from the paper. Permanently
  excluded on fidelity grounds. See §5.

**2. Transparent interception merge inside `get`** — ✅✅ **ADOPTED (2026-10)**
- Automate Def 27's `σ(k)(μ ⊕ 𝜄(k))`: a `getIntercepted(key, declared_meta)`
  applies a provider function to the merged metadata, instead of leaving the
  merge to the component. We already have `InterceptTable` + `interceptOf`.
- *Value:* Medium. Completes Def 26/27 faithfully.
- **Shipped:** `ProviderTable` + `Provider` + `Resolved(V)` in
  `src/coeffect/interception.zig`; `ctx.provide(key, provider)` and
  `ctx.getIntercepted(V, key, declared)` in `src/context/context.zig`. The
  provider table is shared with the store's lifetime (root owns, children
  borrow). `ctx.provide` is a revertible effect (registers σ(k), tracks
  unregister — Def 26, Thm 7/16) and single-source
  (`error.ProviderAlreadyRegistered`, mirroring the store's O-Insert).
  `getIntercepted` performs the full Def 27 get: merge μ ⊕ₖ 𝜄(k) right-biased
  toward the carried 𝜄(k), then apply σ(k); handles all four εₖ cases. 9 new
  tests (provider-table unit + context integration + OOM), 99 total passing
  Debug + ReleaseSafe. `interceptOf` is retained as the lower-level accessor.

**3. Events-as-revertible-effects (`on`/`emit`)** — ✅✅ **ADOPTED (2026-10)**
- An event bus: `ctx.on(event, handler)` returns a disposer (tracked effect);
  `ctx.emit` dispatches. This is exactly the tagged-registry commutativity case
  (§3.4.2) whose witness we already built.
- *Value:* Very high. Biggest application-level gap; unlocks real plugin
  ergonomics.
- **Paper-grounded:** §3.4.2 (tagged registry) + Def 8 (revertible effect) +
  Def 46/Thm 47 (commutativity witness, already built). See §5.
- **Shipped in** `src/event/bus.zig` (`EventBus`, `Handler`, `Subscription`,
  `busWitness`) + `ctx.on`/`ctx.emit` in `src/context/context.zig`. 13 new
  tests (bus unit + context integration + OOM), 90 total passing Debug +
  ReleaseSafe. Fidelity realized exactly as planned: each listener carries a
  unique tag (§3.4.2), `on` tracks its `off` disposer on the accumulator so
  recover/unload withdraws it (Def 8 / Thm 7/16), the bus certifies a
  `tagged_registry` witness (Def 46). One real invariant surfaced and is
  documented: **the bus must outlive its subscribers** (the disposer calls back
  into `off` on recover); in the fiber model this holds structurally via Thm 70
  + Def 52 ordering.

### Tier 2 — Ready · adds comptime machinery or API surface

**4. Schema-validated config** — ✅✅ **ADOPTED (2026-10)**
- Replace opaque `?*anyopaque` config with a comptime-typed config per component
  + validation; diff *config values* (not just code identity) in `reconcile`.
  Zig `comptime` is ideal (compile-time schema from a struct type).
- *Value:* High. Turns HMR/reconcile from code-identity to true material-change
  detection.
- **Shipped:** `src/loader/schema.zig` — `Schema(T)` (comptime constraints:
  `int_range`, `non_empty`, `predicate`), `Config` (type-erased validated
  carrier with value-`eql` for the material diff + owned heap copy),
  `ValidationError`. `ConfigEntry.config: ?Config` (optional — existing
  config-less entries unchanged); `Fiber.config` + `Orchestrator.loadWithConfig`
  thread it to `apply`. `reconcile` now treats a config VALUE change as a
  material revision → HMR reload (previously only code-identity changes
  reloaded; a config-only change was a silent no-op). The loader owns each
  realized config and frees it on teardown/replace/deinit. 15 new tests (schema
  unit + config-driven reconcile + OOM), 114 total passing Debug + ReleaseSafe.

**5. Comptime-typed service accessors** — ✅✅ **ADOPTED (2026-10)**
- Generate typed accessors from a comptime key registry so call sites read
  `ctx.get(DbKey)` with the type inferred. Zig has no `Proxy`/declaration
  merging, so we get typed-but-explicit, not Cordis's transparent `ctx.database`.
- *Value:* Medium.
- **Shipped:** `src/context/typed_key.zig` — `TypedKey(V, name)` carries V at
  comptime and lowers to the same `store.Key`. Context accessors `getT`/`setT`/
  `hasT`/`getInterceptedT` read `V = K.Value` off the key, so the call site
  never restates the type — and `setT(K, value)` types `value` as `K.Value`, so
  a mismatch is a COMPILE error (vs the untyped `set`'s runtime TypeMismatch).
  Pure ergonomics, zero overhead (K.key is comptime), fully interoperable with
  the untyped accessors on the same binding. No new store semantics. 7 new
  tests (typed_key unit + context integration), 121 total passing Debug +
  ReleaseSafe. This is the closest Zig gets to Cordis's transparent
  `ctx.service` — typed-but-explicit; Tier-4 #8 (true Proxy access) remains
  impossible in Zig.

### Tier 3 — Newly ready in 0.16 · stabilizing (churn risk)

**6. Async inertial lifecycle via `std.Io`** — ✅✅ **ADOPTED (2026-10)** *(the big one)*
- **Shipped (3 steps, see `plan/async-inertia-design.md`):** a Gluon-owned
  Scheduler seam (`src/scheduler/scheduler.zig`) isolating `std.Io` to one
  file, with two backends: `.blocking` (default; run-to-completion, zero
  `std.Io` dependency — the paper's degenerate schedule) and `.evented`
  (`src/scheduler/evented.zig`; wraps `std.Io` async/await/cancel, runs on
  `std.Io.Threaded`/`Evented`). The orchestrator routes `reload`/`unload`
  through the seam (`fiber` recover is a must-complete `run`; apply+execute is
  a fallible `spawn`/`await`), awaits in-flight dependents/children in the
  drain + Def 52 cascade (Thm 70 ordering preserved under suspension), and ORs
  a cancel token into the reload guard (L-Divert abort → route to unload →
  re-converge). The orchestrator never imports `std.Io`. All 121 prior tests
  pass unchanged under `.blocking` (behavior-preserving refactor); +10 new
  (seam unit, `.evented` integration, L-Divert cancel), 131 total Debug +
  ReleaseSafe. **Churn containment realized:** if `std.Io` changes, only
  `evented.zig` changes; `.blocking` keeps the library working regardless.

  _Original assessment (kept for context):_
- Thread `io: Io` through the orchestrator; make `reload`/`unload` async with
  `fiber.inertia: ?Future(void)`; drain dependents with `Io.Group`; abort
  L-Divert with `Future.cancel`. Primitives map 1:1 to the paper (§3 above).
- *Readiness upgraded* from ★☆☆☆☆ now that `std.Io` + `Io.Threaded` ship. **But**
  `std.Io` is new and will churn (0.16.x → 0.17); adopting now means tracking
  std changes or pinning a Zig version.
- *Value:* Highest capability gain — closes the single largest gap (async
  teardown awaiting departing dependencies). Synchronous model remains valid as
  the degenerate schedule.

**7. Realm freeze at fiber insertion (§4.4 Isolation)** — ✅✅ **ADOPTED (2026-10)**
- Freeze a fiber's `ρ` at insertion so realm reassignment becomes a revision
  (new fiber), fixing the documented set-inverse-resolves-at-recover-time
  limitation. Pure Zig, but only meaningful once multi-realm multi-tenancy is
  actually used.
- *Value:* Low now; higher if multi-tenancy is pursued.
- **Shipped:** realized at the effect level (equivalent to a per-fiber ρ freeze
  for the provision path, which is where the bug lived). `Store.restrictRealm`
  withdraws an EXPLICIT realm, bypassing live ρ; `ctx.set` now resolves ρ(k)
  ONCE at set time and freezes it into the restriction inverse, so a later
  `isolate()` can no longer make the inverse withdraw the wrong binding — the
  inverse undoes exactly what the set did (Def 20 inverse, Thm 7). The former
  `KNOWN LIMITATION` test is replaced by a passing §4.4-Isolation test; +3 new
  tests (store `restrictRealm`, context realm-freeze property, OOM), 134 total
  Debug + ReleaseSafe. Note: test fixtures that build their own set-inverses
  bind under the default realm and never reassign ρ, so they are unaffected;
  the general `ctx.set` path is the one that needed the fix.

### Tier 4 — Not Zig-expressible / out of scope

**8. Transparent `Proxy`-style context** — Zig has no runtime property
interception; cannot replicate `ctx.database` transparent access. Tier-2 #5 is
the closest achievable.

**9. Confinement enforcement (Def 55)** — orthogonal to Cordis (the paper treats
it as discipline, not a runtime check); would need per-fiber store-write
interposition. Tracked separately in building-blocks.md.

---

## 5. Recommended sequencing (when work resumes)

> **Fidelity gate (added after review).** A feature only qualifies if it is
> faithful to the paper's calculus — *even if Cordis has it*. Each candidate was
> re-screened against the paper, not just against Cordis. One Tier-1 item failed
> this gate (see below), which changed the ordering.

**Adopt first: #3 Events-as-revertible-effects (optionally bundled with #2).**
It is the strongest fit because it is grounded in the *paper*, not merely in
Cordis:
- §3.4.2's **tagged-registry commutativity example** *is* the event-listener
  case (a key whose value is a table of entries; concurrent registrations
  commute).
- An event listener is a **revertible effect** (Def 8): `on()` returns a
  disposer = the inverse — our core abstraction, already implemented
  (`ctx.effect`).
- We **already built** the commutativity witness (Def 46 / Thm 47) for exactly
  this shape; it is currently under-exercised.

So `on`/`emit` is not importing a Cordis idea — it *surfaces a construction the
paper explicitly describes* and composes three implemented-but-latent pieces
(revertible effects + tagged-registry key + commutativity witness). Zero
fidelity risk, highest value.

**Sequencing:**
1. **#3 Events** (+ optionally **#2 interception merge** — both are small and
   both merely *complete* paper definitions, Def 8/46 and Def 26/27, that we
   only partially realized).
2. **#4 schema config** — faithful strengthening of §5.2.1 reconciliation;
   natural follow-on.
3. **#6 async `std.Io`** — the *most* paper-faithful item (§4.4 inertia is "core
   to correctness, not optional") and the headline capability, but defer until
   comfortable tracking `std.Io` churn (or pin a Zig version).

### ✖ Excluded on fidelity grounds (VERIFIED against the paper): #1 optional dependencies

The earlier draft of this section recommended **#1 (optional deps) first**. On
re-screening it was flagged with a paper-fidelity question mark; that question
has now been **resolved by reading the paper text** (arXiv:2608.25512, 92 pp.),
and the verdict is **exclude, permanently**:

- **Def 21** (§3.2.2): `𝔇Σ ≔ Set(K)` — a flat set of declared keys, with **no**
  required/optional annotation. There is no syntactic place for "optional".
- **Def 22 / Eq. 22:** `σ ⊧ d ≔ ∀k ∈ d. k ∈ dom(σ)` — satisfaction is universally
  quantified; **every** declared key must be present. Classification is binary.
- §3.2.2 **explicitly designs against** the optional behavior: a component
  "should activate only once **all** the dependencies it declares are present,
  **rather than accessing them optimistically and failing when one is
  missing**." An optional (non-gating) dependency *is* that optimistic access.
- The local-composability criterion the paper proves ("a component activates
  only at a state satisfying its specification, so it never reads a binding
  that is absent") would be violated by a non-gating dep, taking the coeffect
  half of Thm 70 with it.
- Textual check: "optional" and non-gating / soft / weak / partial-satisfaction
  / best-effort appear **0 times** in all 92 pages.

Adopting #1 would require a richer `𝔇Σ` than Def 21 and a weaker satisfaction
relation than Eq. 22 — i.e. inventing semantics the paper not only omits but
argues against — and would move our code (already `∀k ∈ d` in `spec.zig`) *away*
from the paper. **Permanently excluded.** The fidelity gate did its job: the one
item it flagged was genuinely incompatible with the calculus.

**Key correction to the original plan:** C2's "stable Zig has no async" is
obsolete. 0.16's `std.Io` makes the async-inertia model a maturity tradeoff, not
an impossibility — meaningfully raising Gluon's ceiling.
