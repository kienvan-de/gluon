# Verification assessment — Gluon vs arXiv:2608.25512

Audit performed against the full paper text (`paper.pdf`, 92 pp., re-extracted
and cross-checked, not from memory) using the checklist in
`plan/verifying-checklist.md`. All tests run under `std.testing.allocator`
(zero leaks) in **Debug and ReleaseSafe**: **134/134 pass**.

Ground rule honored: where the PDF and the checklist disagree, the PDF wins and
the item is marked **Spec-conflict** (see item 26).

---

## A. Verdict table

Verdicts: **OK** = implemented & faithful (test cited) · **OK*** = faithful but
proved only by behavior/no dedicated test · **Derived** = [PAPER-derived], holds
by construction, no explicit test · **N/A** = out of scope for a Zig host
(host-language constraint) · **Gap** = not implemented / not asserted ·
**Spec-conflict** = PDF disagrees with the checklist item.

| # | Verdict | file:line | paper ref | test / evidence |
|---|---------|-----------|-----------|-----------------|
| 1 | OK | component.zig:95 (`Phase`) | Def 49, §4.4 | `Phase{inactive,loading,active,unloading,failed}`; loading=Reloading, failed=Inactive+outcome. Extra label `failed` documented. |
| 2 | OK | component.zig (fields const after init) | Lemma 59(5) | d,p,e,parent set in `Fiber.init`, never reassigned; `retired` only false→true (`retireChildren`, `unloadFiber`); re-enable = fresh fiber (loader revision). |
| 3 | **Gap** | — | Table 1, Lemma 59 | No per-step write-set diff harness. Behavior is correct but not *asserted* field-by-field. |
| 4 | OK* | registry.zig:160 (`isProvided`), lifecycle.zig | Def 63, Thm 64 | Disjoint provisions enforced (registry.insert); view total on declared keys (computeTarget); installed includes loading. No standalone invariant checker. |
| 5 | OK | registry.zig:160, component.zig:66 (`View.eql`) | Lemma 60, Thm 73(B) | Rules depend on provider **ids**/domains, never values; `View.eql` compares provider ids. Test "View: ⊥ vs resolved equality". |
| 6 | OK*/IMPL | registry.zig:70 (`freshId`) | Lemma 61 | Monotonic ids, never reused (matches the [IMPL] preference). No two-scheme renaming test. |
| 7 | OK | registry.zig:88 (`reserveProvisions`) | O-Insert | Checks ALL provided keys against every existing (incl. retired/inactive) provider; conflict → `ProvisionConflict`, nothing half-registered. Test "O-Insert single-source". |
| 8 | OK | lifecycle.zig:`unloadFiber` | O-Retire | Sets `retired=true` only, legal in any state, frees nothing. |
| 9 | OK | registry.zig:116 (`remove`), lifecycle.zig:`removeFiber` | O-Remove | Requires child-free; caller deactivates first. Test "O-Remove: a fiber with children cannot be removed". |
| 10 | OK* | lifecycle.zig:`retireChildren` | Def 52, Lemma 62 | Parent unload cascades O-Retire to children; vestigial entry still reserves name/provision (not removed). "Def 52 cascade" tests. **No explicit vestigial-name-reservation test** (new component claiming a vestigial key rejected until O-Remove). |
| 11 | OK | lifecycle.zig:120 (`computeTarget`) | Def 53 | ⊥ if retired/unsatisfied; else map key→provider **id**. Providers by name/id, not value. |
| 12 | OK | registry.zig:160 (`isProvided` requires `.active`) | Eq 46, §4.1 | Only Active fibers publish; one provider per key (single-source). Test "Definition 53: provided only while ACTIVE". |
| 13 | OK | lifecycle.zig:`reload` (commit view) | L-Begin | Inactive & target≠⊥ → loading; view committed at entry. |
| 14 | OK | effect_iter.zig:`execute`, accumulator.zig | L-Iter/Finish, Def 18, Thm 71 | Each step composes inverse onto φ newest-first; iterator leaves loading only via settle(active) or chain-to-unload. |
| 15 | OK (sync branch) | lifecycle.zig:`reload`/`runReload` | L-Divert | Sync host (`.blocking`): aborts pending iteration (guard trips, nothing lands). Async host (`.evented`): see item 40. Test "§4.2.2 L-Divert cancel". |
| 16 | OK | lifecycle.zig:120 (`computeTarget` gates reload) | Thm 70 (first) | L-Begin only when all declared keys provided-by-active. |
| 17 | **Derived (untested)** | computeTarget + isProvided | Def 72 | Self-dep (d∩p≠∅) can only be satisfied by itself, but `isProvided` needs the provider ACTIVE while it is still loading → never activates. Holds by construction; **no test**. |
| 18 | OK | lifecycle.zig:`unload` (phase→unloading, no recover yet) | L-Leave | Active→Unloading keeps accumulator & view; table leaves published ctx (isProvided drops). |
| 19 | OK | lifecycle.zig:`unload`+`runRecover`; registry.zig:`reliedUpon` | Def 54, L-Unload | ¬relied via `drainDependents`; accumulator run once; view discarded; →inactive. Only accumulator-running rule. |
| 20 | OK* | lifecycle.zig:`drainDependents` ordering | Thm 70 | Consumer deactivates before provider's recover; binding stays in provider table through consumer episode (isProvided+committed). Tested outcome-wise ("Thm 70 ordering"); **not asserted step-index-wise**. |
| 21 | OK | lifecycle.zig:`unload` discards view last | §4.2.2, Thm 70 remark | committed view cleared as the last act, after recover. |
| 22 | OK | lifecycle.zig does not impose tree order on recover | §4.2.2 | Guard orders along coeffects (reliedUpon/committed), not the fiber tree; no "children before parent" assertion. |
| 23 | OK | lifecycle.zig:`unload` tail chains to reload | §4.4 | After recover, if target active again → reload; L-Unload has no target premise. Test "reload after re-satisfaction". |
| 24 | OK* | lifecycle.zig uses fixpoint loops, not a fixed order | §4.2.2 | `retireChildren`/`drainDependents` iterate to a fixpoint (`changed`), asserting outcomes not order. No randomized-order test (see 59). |
| 25 | OK | context.zig:`set` inverse (frozen realm) | Def 8, 12 | Inverse witnessed per-state; realm frozen at set time (roadmap #7). Test "§4.4 Isolation realm freeze". |
| 26 | **Spec-conflict (resolved correctly)** | accumulator.zig:`recover` (newest-first) | Thm 16 vs Alg 1 L16/L5 L16 | PDF Alg 1 line 16 writes `inverse ← value ∘ inverse`, which reads **FIFO** and contradicts Def 18/Thm 16 ("reverse order of application"). We implement **newest-first (LIFO)** per the theorem. Test "Theorem 16: LIFO order" asserts `{3,2,1}`. **Do not change to match the buggy pseudocode.** |
| 27 | OK* | lifecycle.zig (Cor 69 via recover) | Thm 68, Cor 69 | Recover empties the fiber's own table; "Corollary 69: deactivated provider leaves Σ clean" verifies binding withdrawn. |
| 28 | OK | accumulator/context compare via public ops | §3.3.2, 4.3.2 | Tests compare through `get`/`isProvided` outcomes, never raw memory/addresses/ids. |
| 29 | OK | store.zig:`set`/`get` preconditions | Def 20 | get requires present (`NotProvided`); set requires absent (`AlreadyProvided`); violation errors, no inverse tracked (errdefer unwinds). |
| 30 | **Gap (by design)** | — | Def 55-56 | Confinement is a **discipline, not a runtime check** (documented decision). A fiber *could* write another's table. Not enforced; honestly out of scope. |
| 31 | OK | lifecycle.zig:`loadWithConfig` witness gate; key_registry.zig | Def 42-47, Thm 43 | Distinct keys independent for free; shared-key commutativity owed by provider; non-commutative provision rejected. Tests "Def 46/Thm 47". |
| 32 | OK* | key_registry.zig (`tagged_registry` vs `non_commutative`) | §3.4.2 | Tagged-registry = commutative (unique ids); ordered chain = non-commutative (rejected). Witness kinds encode this; no middleware-removal test (correctly, per the checklist's own caveat). |
| 33 | OK* | registry.zig:`reliedUpon`; lifecycle guard | Lemma 67 | Entangled fibers covered by the rules: ops on a provider value occur only under a committed view. Behavior correct; no dedicated entanglement test. |
| 34 | OK* | lifecycle quiescence (phases settle) | Def 53 quiet | Tests assert final phases (all active / all inactive); a failed fiber is admitted. No single `quiet()` predicate helper. |
| 35 | **Gap** | — | Thm 73 | No test of the step-count bound `(L+3)(T_n+1)` nor the per-interval `L+3` bound; no deadlock-freedom property test. |
| 36 | OK* | lifecycle.zig chains A←B←C; Def 52 transitive | §4.3.4 | "cascade reaches grandchildren" covers a chain; **no diamond test**, no retire-root-provider deadlock test. |
| 37 | **OK (behavior)** | lifecycle.zig test "item 37 (§4.3.4)" | §4.3.4, 6.5 | A 2-cycle (A needs b/provides a; B needs a/provides b) leaves both members Inactive — tested. We do NOT report at load time (paper only says a runtime MAY). |
| 38 | OK* | lifecycle.zig (totality by apply) | Def 74-76, Lemma 77 | Component installs its provision during apply; `isProvided` reads the store. **No `domain(table)==p` debug assertion after L-Finish.** |
| 39 | OK (partial) | lifecycle.zig test "Theorem 80 confluence" | Thm 80 | Load-order permutations reach the same quiescent state. Covers the incremental-order half; **does not** replay-all-orchestration-then-run-once vs incremental. |
| 40 | OK | evented.zig; lifecycle.zig `.evented` tests | §4.4 Asynchrony | `.evented` backend lands the in-flight iteration (holds its inverse), then re-converges — the inertial/landing alternative. `.blocking` takes the abort alternative (both are paper-sanctioned per host). |
| 41 | OK | lifecycle.zig:`markFailed` | §4.4 Failure | raise → recover built-so-far, →inactive(failed) having installed nothing (Cor 69), error recorded on fiber, not propagated to parent; L-Begin needs error-free (phase gate). Retry = revision. **No dedicated sibling-keeps-running / failed-admitted-by-quiet test.** |
| 42 | OK (single realm) + #7 | store.zig realms; context.zig `isolate` | §4.4 Isolation | One shared realm by default; `isolate` redirects ρ; realm reassignment frozen in the set-inverse (#7). Full K×R product not modeled as a type, but behaviorally equivalent for the single/explicit-realm paths. |
| 43 | OK* | loader.zig (revision = retire→deactivate→remove→reinsert) | §4.4 Configuration | Loader reconciliation performs revisions; dependents follow through the guard. Behavior present; see loader tests. |
| 44 | OK* | context.zig:355 (`effect`), 90 (`deinit`→recover), accumulator.zig:`recover` | Alg 1, §5.1.1 | Guard consulted before each step; child dispose prepended to parent. **Idempotence** realized by "recover empties φ (head=null) so a 2nd call is a no-op" — equivalent to the paper's `armed` disarm, but **untested** (no explicit double-dispose test). |
| 45 | OK | context.zig:`set` + notify path | Alg 2 | set installs then notifies; inverse deletes then notifies; runtime does not verify the inverse (author's obligation, documented). |
| 46 | OK | lifecycle.zig:`notify` | Alg 3 | notify refreshes every fiber declaring a changed key; refresh idempotent (neutral change harmless). |
| 47 | OK | lifecycle.zig:`load`/instantiation; Def 52 inverse | Alg 4 | use = parent effect; inverse retires+unloads child; parent unload cascades (retireChildren). |
| 48 | OK | lifecycle.zig:`refresh`/`reload`/`unload` | Alg 5 | refresh recomputes/stores target, no-op if unchanged, inertia if in-flight; marks loading/unloading BEFORE scheduling (phase set first); reload commits→apply→settle-or-chain; unload drains dependents (wait ahead of recover) → recover → clear view → inactive-or-chain. **Wait sits ahead of the whole recovery** (drainDependents precedes runRecover). ✓ |
| 49 | OK* (half) | component.zig:`View` (provider ids) | §5.1.3 | target is a tuple of provider **ids**: a replacement via a NEW fiber IS observed (test "reload after re-satisfaction"). **The "in-place overwrite NOT observed" half is untested.** |
| 50 | **N/A** | typed_key.zig (`getT`), context.zig | Alg 6, §5.1.4 + §6.4 | Proxy-mediated access is impossible in Zig (no runtime property interception). The paper's §6.4 names **comptime typed accessors** as the native substitute — implemented as `TypedKey`/`getT`. `INACTIVE_ACCESS`/`UNDECLARED_ACCESS` have no analogue; `get` reads the store and may fail with `NotProvided`. |
| 51 | OK | loader.zig (`ConfigEntry` fields, dispatch); loader.zig:425 | Def 81, §5.2.1 | id/url/isolate/intercept/config/disabled fields + dispatch present. Unchanged config = no reload is tested ("§5.2.1 config: an unchanged config value is a no-op (no reload)", loader.zig:425). |
| 52 | OK*/partial | loader.zig HMR | Alg 8-10 | HMR reload path present. **Transactional backup/restore-on-failure not fully verified** — needs a failure-injection HMR test to prove "never half-reloaded". |
| 53 | N/A (host note) | — | §6.1 | Acquisitions revertible / emissions identity — a host-boundary discipline; no emission-undo test (correctly none). |
| 54 | N/A / IMPL | — | §6.4 | dlopen/dlclose native linking not in scope for this library core; comptime accessors (6.4) done via TypedKey. |
| 55 | OK* / partial | interception.zig | §6.2-6.3, 6.6 | Interception metadata consulted at access time, changeable without reload (roadmap #2). Realms for multi-provider. Sandbox/key-collision explicitly out of scope. |
| 56 | OK | 14× `checkAllAllocationFailures` across modules | §L.56 | Reserve-before-effect; OOM at every allocation point leaves no effect without its inverse. |
| 57 | OK* | lifecycle/context lifetimes | §L.57 | Committed view cloned; in-flight iterator state owned by task; event payloads owned. No ASan/leak beyond testing.allocator (which is clean). |
| 58 | OK (documented) | scheduler.zig / evented.zig | §L.58 | Single-scheduler-thread model; `.evented` on std.Io.Threaded. No ThreadSanitizer run. |
| 59 | **Gap** | — | §L.59 | **No randomized/seeded scheduler property test** (random orchestration × enabled lifecycle rules, asserting items 3/4/20 per step and 34/35/39 + zero leaks at the end, replay under a second schedule). This is the single biggest missing deliverable (C). |

---

## B. Bugs / Not-implemented — triage (failing test → fix → rerun)

No **Bugs** (incorrect-vs-paper behavior) were found. The one Spec-conflict
(item 26) is already resolved in our favor (we follow Thm 16, not the buggy
pseudocode).

**Closed in this pass** (new tests, no kernel changes):

- **#4 well-formedness checker** — `src/testing/invariants.zig:assertWellFormed`
  (parent-in-registry, provision disjointness, view totality+validity,
  view-names-only-installed, Eq 46 active-provider), allocation-free so it is
  usable under OOM injection; 4 unit tests incl. a corruption test.
- **#59 randomized scheduler property test** — `src/testing/randomized.zig`:
  seeded PRNG × orchestration actions over a 4-key pool, asserting #4 + #34
  after every step across 64 seeds, replaying each seed (#39), with an
  OOM-injected scenario (#56) and a non-triviality diag.
- **#34 quiescence predicate** — `assertQuiescent` (used between every step).
- **#39 history independence** — same-seed replay reaches the same signature.
- **#17 self-dependency**, **#37 2-cycle**, **#49 in-place-overwrite-not-
  observed** — derived-behavior tests in `lifecycle.zig`.

**Still open** (lower value, by priority):

1. **#3 per-step write-set DIFF** — we assert resulting-state invariants after
   each step but not *which fields changed* per rule (Table 1). Would need
   before/after state snapshots.
2. **#35 progress BOUNDS** — step-count bound `(L+3)(T_n+1)` and deadlock-
   freedom on a diamond. Cascade/chain behavior is covered; the explicit bound
   is not counted.
3. **#10 vestigial-name reservation**, **#41 failure isolation to siblings**,
   **#52 HMR transactional rollback** — targeted single-scenario tests.
4. **#30 confinement** — stays a discipline by design (not a runtime guard).

---

## C. Section L property tests

- **#56 OOM**: present (15 sites, incl. randomized×OOM). ✓
- **#59 randomized scheduler**: **DONE** — `src/testing/randomized.zig`. ✓
- **#58 threading**: single-scheduler-thread model documented; no TSan run. △

---

## D. Unspecified / ambiguous — and the choice we made

- **Thm 16 vs Algorithm 1 (item 26).** The prose (Def 18/Thm 16) says revert in
  reverse order (LIFO); the pseudocode (Alg 1 L16, Alg 5 L16) composes
  `value ∘ inverse` / `dispose ∘ ctx.dispose`, which reads FIFO. **Choice:**
  follow the theorem → newest-first LIFO. Verified against the TS reference
  behavior.
- **L-Divert abort vs land (items 15/40).** The paper leaves the choice to the
  host: a sync host MAY abort, an async host MUST land. **Choice:** `.blocking`
  aborts, `.evented` lands. Both implemented; default is `.blocking`.
- **Confinement (item 30, Def 55-56).** The calculus assumes it; enforcing it at
  runtime is unspecified. **Choice:** discipline only, not a runtime guard
  (documented).
- **Load-time cycle reporting (item 37).** Paper says a runtime *MAY* report a
  dependency cycle. **Choice:** we do not; a cycle simply leaves its members
  permanently inactive (also valid).
- **Realm product K×R (item 42).** Paper lifts the key set to K×R with unchanged
  rules. **Choice:** we model realms as a ρ-redirection over a single key space
  (behaviorally equivalent for the paths we expose), not as a K×R product type.
- **Fiber id scheme (item 6).** Paper allows name reuse after O-Remove; the
  [IMPL] note prefers monotonic ids. **Choice:** monotonic, never reused.

---

## Bottom line

The kernel is **faithful**: every orchestration/lifecycle/effect/coeffect rule
checked maps onto the paper, the one spec hazard (LIFO) is resolved per the
theorem, and the deliberate non-enforcements (confinement, cycle-reporting) are
honest and paper-permitted.

**Update:** the two biggest gaps are now closed — a standalone well-formedness
invariant checker (`src/testing/invariants.zig`, item 4) and the randomized
seeded scheduler property test (`src/testing/randomized.zig`, item 59, 64
seeds), plus the small derived-behavior tests (items 17/37/49) and a quiescence
predicate (34) and history-independence replay (39). **145 tests pass, Debug +
ReleaseSafe, zero leaks.** What remains (per-step write-set diff #3, progress
bounds #35, and the targeted #10/#41/#52 scenarios) is lower-value and
non-blocking.
