# Async Inertial Lifecycle — Design (roadmap #6)

**Status:** design. Implemented in three steps (this doc = step 1); steps 2–3
land the code. Target: Zig 0.16.0 (`std.Io`).

This document maps the paper's inertial lifecycle (§4.4, Algorithm 5) onto Zig
0.16's `std.Io`, via a thin Gluon-owned **Scheduler seam** so the churn-exposed
`std.Io` surface is isolated to one file.

---

## 1. Goal and non-goal

**Goal.** Let `reload`/`unload` *suspend* — specifically, let `unload` await a
departing dependency's asynchronous teardown (the paper's §4.2.2 example:
closing a connection pool means handing connections back to whatever provided
them), and let an in-flight transition be aborted mid-step (L-Divert) via
cooperative cancelation.

**Non-goal.** Changing any lifecycle *semantics*. The paper proves every §4.3
result for all schedules; the synchronous schedule is one of them. Async is
**additive**: the existing run-to-completion behavior must remain available and
correct as the degenerate (`.blocking`) schedule.

---

## 2. Churn containment: the Scheduler seam

`std.Io` is new in the 0.x series and Zig does not freeze stdlib APIs pre-1.0
(the `Reader`/`Writer` interfaces were reworked across 0.14→0.16). We therefore
do **not** thread `std.Io` types through the orchestrator. Instead:

```
┌───────────────────────────────────────────────┐
│ Orchestrator (lifecycle.zig)                    │
│   speaks only the Scheduler vocabulary:         │
│   spawn / await / cancel / drain                │
└───────────────┬─────────────────────────────────┘
                │  Gluon-owned interface (scheduler.zig)
                ▼
┌───────────────────────────────────────────────┐
│ Scheduler                                        │
│   .blocking  → runs the fn inline, no std.Io     │
│   .evented   → wraps std.Io async/await/cancel   │
└───────────────────────────────────────────────┘
```

If `std.Io` changes in 0.17, only `scheduler.zig`'s `.evented` backend changes.
`.blocking` has **zero** `std.Io` dependency, so the library keeps working even
if `std.Io` broke entirely. The orchestrator never imports `std.Io`.

---

## 3. The Scheduler interface (step 2)

A closure-free, type-erased task abstraction mirroring our existing C1 pattern
(`{state, call}` pairs). Minimal surface — exactly what Algorithm 5 needs:

```zig
pub const Scheduler = struct {
    vtable: *const VTable,
    state: *anyopaque,

    /// A handle to an in-flight task. In .blocking it is already complete.
    pub const Task = struct { ... };

    pub const VTable = struct {
        /// Start `run(ctx)` as a task. .blocking runs it inline and returns a
        /// completed Task; .evented spawns it via std.Io.async.
        spawn: *const fn (state, run: TaskFn, run_state: *anyopaque) Task,
        /// Block until the task completes; returns its result.
        await: *const fn (state, task: *Task) TaskResult,
        /// Request cooperative cancelation; the task observes it at its next
        /// cancelation point and unwinds. Returns the (possibly partial) result.
        cancel: *const fn (state, task: *Task) TaskResult,
    };
};

/// A cancelation flag a running task polls at step boundaries (the cooperative
/// cancelation point). In .blocking it never trips during a run.
pub const CancelToken = struct {
    pub fn requested(self: *const CancelToken) bool { ... }
};
```

**Why this shape (vs. exposing `std.Io.Future` directly):**
- `Task` hides whether completion is eager (`.blocking`) or deferred
  (`.evented`), so the orchestrator code is identical for both.
- `CancelToken.requested()` is our own cooperative-cancelation point. It maps to
  `std.Io`'s "surfaces `error.Canceled` at the next cancelation point" in
  `.evented`, and to "always false mid-run" in `.blocking`. This is exactly the
  paper's "abort at an iteration boundary" (§4.2.2 L-Divert) and plugs into the
  existing `effect_iter.Guard` without changing the engine.

**Backends:**
- `.blocking` — `spawn` calls `run` immediately, stores the result in the Task,
  `await`/`cancel` just return it. No `std.Io`. This is today's behavior.
- `.evented` — `spawn` → `io.async(run, .{...})` producing a `Future`; `await`
  → `future.await(io)`; `cancel` → `future.cancel(io)`. Holds an `io: std.Io`
  obtained from `std.Io.Threaded` or `std.Io.Evented` (Dispatch/Uring/Kqueue;
  `fiber.supported` is true on aarch64/x86_64/riscv64).

---

## 4. Algorithm 5 → Scheduler mapping (step 3)

The orchestrator gains a `scheduler: Scheduler` field (default `.blocking`, so
existing `Orchestrator.init` behavior is unchanged). The three transition
functions change as follows. **Every line below already exists synchronously;
the change is only *where suspension points are allowed*.**

### 4.1 `fiber.inertia`

| Today | Async |
|-------|-------|
| `fiber.in_transition: bool` | `fiber.inertia: ?Scheduler.Task` |

`in_transition` becomes "there is a Task in flight". The inertial guard in
`refresh` (Alg 5 line 5) is unchanged in spirit:

```
refresh():
    recompute target
    if target unchanged: return
    fiber.target = new_target
    if fiber.inertia != null: return          // in flight — don't interrupt
    start the transition (reload or unload)
```

In `.blocking`, `spawn` completes inline, so `inertia` is set and cleared within
the same call — identical to today's `in_transition = true; defer = false`.

### 4.2 `reload`

```
reload():
    target0 = fiber.target
    fiber.phase = LOADING
    commit view ω := target0
    fiber.inertia = scheduler.spawn(runApply)   // runApply builds+drives iter
    result = scheduler.await(fiber.inertia)      // suspends in .evented
    fiber.inertia = null
    on component failure → markFailed (unchanged)
    if target still == committed: ACTIVE + notify(provide)
    else: chain into unload                      // inertial chaining (L-Divert)
```

`runApply` = today's body: `component.apply(ctx, config)` then
`effect_iter.execute(iter, guard, ...)`. The `guard` already polls
`targetGuard(fiber)`; we additionally OR in `cancel_token.requested()` so a
cancel request stops the iterator at the next step boundary (L-Divert abort).

### 4.3 `unload` — the one with real async payoff

```
unload():
    fiber.phase = UNLOADING
    drainDependents(fiber)       // ← may now AWAIT each dependent's inertia
    retireChildren(fiber.id)     // ← Def 52 cascade; may AWAIT each child
    fiber.inertia = scheduler.spawn(runRecover)  // ctx.dispose.recover
    scheduler.await(fiber.inertia)                // ← async teardown happens here
    fiber.inertia = null
    discard committed view
    fiber.phase = INACTIVE
    if target became active again: chain into reload   // inertial chaining
```

`runRecover` = today's `fiber.ctx.dispose.recover(ctx)`. In `.evented`, an
inverse that itself does async work (closing a pool) suspends here; `drain`
below ensures a parent does not finish unloading until its dependents' and
children's teardown has been awaited (Thm 70 ordering + Def 52 cascade preserved
exactly).

### 4.4 `drainDependents` / `retireChildren`

Both are `while (changed)` fixpoint loops that call `refresh` on each affected
fiber. In the async world a `refresh` may leave a dependent *mid-transition*
(its `inertia` set). The loop must then **await** those tasks before concluding
the fixpoint, so the ordering guarantee (a provider's `recover` runs only after
every dependent has fully deactivated — Def 54 ¬relied, Thm 70) is preserved:

```
drainDependents(fiber):
    loop:
        changed = false
        for each installed dependent dep that resolves a key to `fiber`:
            refresh(dep)                      // may set dep.inertia
            if dep.inertia != null: scheduler.await(dep.inertia); dep.inertia=null
            if dep.phase changed: changed = true
        if not changed: break
```

In `.blocking`, `refresh` already ran to completion, so `dep.inertia` is null
and the `await` is a no-op — the loop is byte-for-byte today's behavior.

---

## 5. Correctness argument (why this is still the paper)

1. **Semantics unchanged.** No transition's *effect* changes; only suspension
   points are introduced, at boundaries the paper already treats as step
   boundaries (iterator steps, Alg 5 lines).
2. **Degenerate schedule preserved.** `.blocking` makes every `spawn/await`
   complete inline, reproducing the current synchronous schedule exactly. The
   existing 121 tests must pass unchanged against `.blocking`.
3. **Ordering preserved.** `drainDependents`/`retireChildren` await in-flight
   dependent/child tasks before a provider recovers, so Def 54 (¬relied) and
   Thm 70 (relied-upon ordering) hold under suspension, not just under
   run-to-completion.
4. **Inertia preserved.** `refresh` still refuses to interrupt an in-flight
   transition (`fiber.inertia != null`), updating only `target`; the in-flight
   transition observes the new target at its settle point and chains
   (reload↔unload) — the §4.4 inertial discipline, now across real suspension.
5. **L-Divert preserved.** The iterator guard ORs the cancel token; a target
   change (or cancel) trips it at the next step boundary, exactly §4.2.2.

---

## 6. Test strategy

- **Regression:** all existing tests run against `.blocking` (default) — must
  stay green, proving the refactor is behavior-preserving.
- **Scheduler unit tests:** `.blocking` spawn/await/cancel completeness; cancel
  token semantics.
- **Async integration (.evented):** (a) an async teardown inverse that suspends,
  asserting the parent awaits it; (b) a target flip mid-reload chaining to
  unload; (c) a cancel aborting a long iterator at a step boundary with Cor 69
  (nothing left installed).
- **OOM:** keep OOM-injection on `.blocking` paths (deterministic). Async paths
  get targeted leak checks; full `checkAllAllocationFailures` under concurrency
  is not reliable, so `.evented` leak coverage is structural (await-then-free)
  plus a single-threaded `.evented` smoke test.

---

## 7. Step breakdown

- **Step 1 (this doc).** Design + mapping + correctness argument.
- **Step 2.** `src/scheduler/scheduler.zig`: Scheduler interface + `.blocking`
  backend + CancelToken. Refactor `lifecycle.zig` to route transitions through
  the scheduler, defaulting to `.blocking`. **No behavior change; all existing
  tests stay green.** `fiber.in_transition` → `fiber.inertia: ?Task`.
- **Step 3.** `.evented` backend over `std.Io`; async `unload`/recover; await in
  the drain/cascade fixpoints; cancel-token in the reload guard. New async
  integration tests.

---

## 8. Implementation notes (as built)

Two refinements emerged during implementation, both recorded here for honesty:

1. **A `run` (must-complete) seam method was added** beyond spawn/await/cancel.
   `unload`'s recover MUST always run or tracked inverses leak — routing it
   through a *fallible* `spawn` (which allocates a task handle) risked skipping
   teardown on OOM. So the Scheduler gained `run(fn, state) → TaskResult`: an
   allocation-free, infallible-to-schedule call. `.blocking` runs it inline;
   `.evented` runs it on the current fiber (an async inverse still suspends via
   its own `io` use, but no task handle is allocated). `reload`'s apply+execute
   still uses the fallible `spawn`/`await` (an apply that fails to even schedule
   is a real error the loader backs out).

2. **Cancel must route reload → unload, not settle ACTIVE.** Adding the cancel
   token exposed that a reload whose guard trips on *cancel* (not a target
   change) would otherwise settle ACTIVE on a half-installed effect, because
   `fiber.target` is unchanged. Fixed: `runReload` records `token.requested()`
   into the TransitionCtx, and `reload` settles ACTIVE only if the target held
   AND the transition was not cancelled; otherwise it chains to unload (recover
   → Cor 69 leaves nothing), then inertial chaining re-converges toward the
   still-valid target. This is L-Divert's "abort then re-settle" (§4.2.2).

**Scheduler binding (no self-referential field).** The orchestrator does not
cache a `Scheduler` pointing into itself (which would break when the
by-value orchestrator moves). It owns a `.blocking` backend and builds the
Scheduler on demand via a private `scheduler()` accessor, with an optional
`scheduler_override` set by `useScheduler(...)` for `.evented`.

**Test coverage delivered.** `.blocking` regression (all prior tests green
unchanged); scheduler seam unit tests (`.blocking` + `.evented` on a real
`std.Io.Threaded`); orchestrator `.evented` integration (load/activate,
reactive activation + Thm 70 ordered teardown); and a deterministic L-Divert
cancel test (one-shot canceling scheduler) proving the token reaches the
iterator guard. 131 tests, Debug + ReleaseSafe.
