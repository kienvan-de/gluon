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

**1. `{ required, optional }` dependency distinction** — ★★★★★ Zig-readiness, ⚠️ **fidelity-gated**
- Split `inject` into required (gates activation) vs optional (reactive but
  non-gating). A struct-field change + a tweak to `computeTarget`/satisfaction.
- *Value:* High. The most-used Cordis ergonomic we lack.
- ⚠️ **Paper-fidelity concern — do NOT adopt first.** "the paper models it" is
  **unverified**; the paper's model treats injection as a *hard gating*
  precondition (Def 52 cascade, Thm 70 ordering). Non-gating deps need their own
  soundness story. See §5 "Held back on fidelity grounds."

**2. Transparent interception merge inside `get`** — ★★★★★
- Automate Def 27's `σ(k)(μ ⊕ 𝜄(k))`: a `getIntercepted(key, declared_meta)`
  applies a provider function to the merged metadata, instead of leaving the
  merge to the component. We already have `InterceptTable` + `interceptOf`.
- *Value:* Medium. Completes Def 26/27 faithfully.

**3. Events-as-revertible-effects (`on`/`emit`)** — ★★★★☆ ✅ **recommended first (fidelity-clean)**
- An event bus: `ctx.on(event, handler)` returns a disposer (tracked effect);
  `ctx.emit` dispatches. This is exactly the tagged-registry commutativity case
  (§3.4.2) whose witness we already built. Mild friction: type-erasing handler
  signatures (the `*anyopaque` pattern we use everywhere).
- *Value:* Very high. Biggest application-level gap; unlocks real plugin
  ergonomics.
- **Paper-grounded:** §3.4.2 (tagged registry) + Def 8 (revertible effect) +
  Def 46/Thm 47 (commutativity witness, already built). See §5.

### Tier 2 — Ready · adds comptime machinery or API surface

**4. Schema-validated config** — ★★★★☆
- Replace opaque `?*anyopaque` config with a comptime-typed config per component
  + validation; diff *config values* (not just code identity) in `reconcile`.
  Zig `comptime` is ideal (compile-time schema from a struct type).
- *Value:* High. Turns HMR/reconcile from code-identity to true material-change
  detection.

**5. Comptime-typed service accessors** — ★★★☆☆
- Generate typed accessors from a comptime key registry so call sites read
  `ctx.get(DbKey)` with the type inferred. Zig has no `Proxy`/declaration
  merging, so we get typed-but-explicit, not Cordis's transparent `ctx.database`.
- *Value:* Medium.

### Tier 3 — Newly ready in 0.16 · stabilizing (churn risk)

**6. Async inertial lifecycle via `std.Io`** — ★★★☆☆ *(the big one)*
- Thread `io: Io` through the orchestrator; make `reload`/`unload` async with
  `fiber.inertia: ?Future(void)`; drain dependents with `Io.Group`; abort
  L-Divert with `Future.cancel`. Primitives map 1:1 to the paper (§3 above).
- *Readiness upgraded* from ★☆☆☆☆ now that `std.Io` + `Io.Threaded` ship. **But**
  `std.Io` is new and will churn (0.16.x → 0.17); adopting now means tracking
  std changes or pinning a Zig version.
- *Value:* Highest capability gain — closes the single largest gap (async
  teardown awaiting departing dependencies). Synchronous model remains valid as
  the degenerate schedule.

**7. Realm freeze at fiber insertion (§4.4 Isolation)** — ★★★★☆ readiness, low urgency
- Freeze a fiber's `ρ` at insertion so realm reassignment becomes a revision
  (new fiber), fixing the documented set-inverse-resolves-at-recover-time
  limitation. Pure Zig, but only meaningful once multi-realm multi-tenancy is
  actually used.
- *Value:* Low now; higher if multi-tenancy is pursued.

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

### ⚠️ Held back on fidelity grounds: #1 optional dependencies

The earlier draft of this section recommended **#1 (optional deps) first**. On
re-screening it is the one candidate with a **paper-fidelity question mark**, so
it must *not* lead:
- The paper's dependency model rests on injection as a **hard activation
  precondition** — the `relied` guard, the unload cascade (Def 52), and the
  relied-upon ordering (Thm 70) all assume *injection = gating*.
- "Optional dependency" (observed-but-non-gating) is a **Cordis ergonomic**. The
  claim in §4 that "the paper models it" is **unverified** — no definition number
  backs it, and it is absent from the fidelity table in building-blocks.md.
- Adopting it would require its own soundness story: does an optional dep's
  departure trigger `refresh` *without* the unload cascade? How does Thm 70's
  ordering treat a non-gating edge?

Until grounded in a specific paper definition, #1 risks diverging from the
calculus and is **deferred pending that grounding**.

**Key correction to the original plan:** C2's "stable Zig has no async" is
obsolete. 0.16's `std.Io` makes the async-inertia model a maturity tradeoff, not
an impossibility — meaningfully raising Gluon's ceiling.
