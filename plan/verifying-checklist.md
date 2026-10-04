# TASK: audit a Zig implementation of the Cordis kernel against its paper

Paper: "A Programming Paradigm for Spatiotemporal Composability",
arXiv:2608.25512 (https://arxiv.org/pdf/2608.25512). You are auditing an
existing Zig implementation of the runtime it defines.

## Ground rules
1. The paper is the source of truth. This checklist was extracted from the full
   text, but verify every [PAPER ...] claim against the PDF yourself. If the PDF
   disagrees with an item, report "Spec-conflict" and do NOT change code to
   satisfy the item.
2. Tags. [PAPER x] = stated or proved at x. [PAPER-derived] = follows directly
   from stated definitions but is not stated as a theorem. [IMPL] = engineering
   guidance that is not in the paper.
3. Never invent semantics. Whatever the paper leaves open goes under
   "Unspecified" together with the choice the implementation made.
4. Optional references for differential testing (not authoritative over the
   paper): TypeScript https://github.com/cordiverse/cordis (packages/core:
   fiber.ts, reflect.ts, v4.0.0-rc.8) and the Python port
   https://github.com/s2005/cordispy (docs/source-review.md lists defects its
   author found in the TypeScript source).

## Deliverables
A. Table: | # | verdict (OK / Bug / Spec-conflict / Not-implemented / N/A) |
   file:line | paper ref | test name |
B. For every Bug / Not-implemented: failing test first, then the minimal fix,
   then rerun the whole suite. Do not weaken existing tests or refactor
   unrelated code.
C. The property tests of Section L.
D. A short "Unspecified / ambiguous" list.
Run everything with std.testing.allocator (zero leaks), Debug and ReleaseSafe.

---
# CHECKLIST

## A. Registry, fibers, well-formedness
1. [PAPER Def 49] Fiber = <d,p,e,parent,table,retired,state>. State is exactly
   one of Inactive, Reloading(i,g,w), Active(g,w), Unloading(g,w)
   (g = accumulator, w = committed view). Implementation labels map as:
   LOADING = Reloading; FAILED = Inactive + error outcome (Sec 4.4);
   "pending" = Inactive with target = bottom. Any extra label must be documented.
2. [PAPER Lemma 59(5)] d, p, e, parent never change after insertion. The retired
   flag is monotone: only false -> true, only via O-Retire. There is no
   "un-retire" rule; re-enabling creates a fresh fiber (Sec 4.4, Configuration).
3. [PAPER Table 1, Lemma 59] Write-set discipline. After every step, diff the
   whole state and assert that only these fields changed: O-Insert = new entry
   and registry domain; O-Retire = retired flag only; O-Remove = entry removed;
   L-Begin / L-Leave = state only; L-Iter / L-Finish = state plus tables moved
   by that iteration; L-Divert = state (plus tables if it lands the iteration);
   L-Unload = state plus tables moved by the accumulator.
4. [PAPER Def 63, Thm 64] Well-formedness after every step:
   (1) parent is in the registry or root; (2) provisions of distinct fibers are
   disjoint; (3) an installed fiber's committed view is total on its declared
   keys and valued in the registry; (4) if an installed fiber's view names m
   then m is installed. "Installed" = state is not Inactive (so Reloading counts).
5. [PAPER Lemma 60, Thm 73(B)] Rule applicability and target views depend only
   on control fields, d/p/e, lifecycle states, and the DOMAINS of tables, never
   on bound values. Test: replace a bound value by an observationally equivalent
   one; the set of enabled rules must not change.
6. [PAPER Lemma 61, Thm 64 remark] Names are atoms compared only by equality.
   Reusing a name after O-Remove is allowed by the calculus (invariant 4 means
   no stale view can name it). [IMPL] The reference implementation draws fresh
   uids that are never reused; prefer monotonic ids. Test: two different id
   allocation schemes must reach states equal up to renaming.

## B. Orchestration rules (Sec 4.2.1)
7. [PAPER O-Insert] Preconditions: name fresh; parent in registry or root; the
   new provision is disjoint from the provision of EVERY existing entry,
   including retired, Inactive entries. Violation = rejected, no state change.
   Consequence: a component with a non-empty provision has at most one fiber.
8. [PAPER O-Retire] Sets the retired flag only; legal in every state; frees
   nothing; carried out by the lifecycle rules.
9. [PAPER O-Remove] Requires: retired, Inactive, empty table, and no child.
   Removing earlier would drop the accumulator (leak).
10. [PAPER Def 52, Lemma 62] A child is instantiated by an iteration (O-Insert
    with parent = the acting fiber); its inverse is O-Retire(child), which needs
    only that the child exists. A retired Inactive child with an empty table is
    "vestigial": every rule at other fibers behaves as if it were absent,
    EXCEPT that it still reserves its name and its provision. Test: a new
    component claiming a key of a vestigial entry is rejected until O-Remove.

## C. Views and activation (Sec 4.2.2)
11. [PAPER Def 53] target(n) = bottom if retired or the declared keys are not all
    provided by ACTIVE fibers; otherwise the map key -> provider fiber NAME.
    Providers are compared by fiber name, never by value. Test: replace a
    provider by a new fiber exposing an equal value; the consumer must still
    unload and reload.
12. [PAPER Eq 46, Sec 4.1] Only Active fibers' tables form the published
    context. Reloading and Unloading fibers publish nothing, so a dependent can
    never activate against a half-initialized or departing provider. Each key
    has at most one provider.
13. [PAPER L-Begin] Inactive and target != bottom -> Reloading(e, id, w = target).
    The committed view is fixed here.
14. [PAPER L-Iter, L-Finish, Def 18] Each iteration requires target == w and
    composes its inverse onto the accumulator as g o h, newest inverse applied
    first. [PAPER Thm 71] Every iteration runs against the one resolution w. A
    Reloading fiber leaves Reloading only through L-Finish (to Active) or
    L-Divert (to Unloading).
15. [PAPER L-Divert] When target != w the fiber moves to Unloading carrying the
    accumulator built so far, at an iteration boundary. Two alternatives: abort
    the pending iteration (state map = identity) or let it land (state map =
    that iteration, its inverse accumulated). A synchronous host may abort; an
    asynchronous host must land (Sec 4.4, inertia).
16. [PAPER Thm 70, first claim] Every L-Begin happens at a state that satisfies
    the fiber's declared keys.
17. [PAPER-derived] Self-dependency: a component with d intersect p non-empty
    needs an Active provider that can only be itself, so it never activates
    (the relation n < n is a precedence cycle, Def 72).

## D. Withdrawal (L-Leave, L-Unload, Def 54, Thm 70)
18. [PAPER L-Leave] Active -> Unloading with the same accumulator and committed
    view; no accumulator is run; the fiber's table leaves the published context.
19. [PAPER Def 54, L-Unload] relied(n) = some OTHER installed fiber's committed
    view names n. L-Unload requires NOT relied(n); it runs the accumulator,
    discards the committed view, and the fiber becomes Inactive. This is the
    only rule that runs an accumulator.
20. [PAPER Thm 70] If consumer c's episode has w_c(k) = m then: m's episode
    opens at a smaller step index than c's; m's L-Unload (if it happens) has a
    strictly larger index than c's L-Unload; the binding at k stays in m's
    table for the whole episode of c; its value changes only through
    operations at k by fibers that declare k. In the window only L-Leave and
    O-Retire may act on m.
21. [PAPER Sec 4.2.2, Thm 70 remark] The consumer reads the provider through
    its committed view during its whole Unloading phase; the view is discarded
    only as the last act of L-Unload.
22. [PAPER Sec 4.2.2] The guard orders deactivation along coeffects, not along
    the fiber tree. A parent may run its accumulator while a child is still
    Unloading. Do not assert "children before parent" as an invariant, nor the
    reverse.
23. [PAPER Sec 4.4] Chaining: after L-Unload the fiber is Inactive and an
    L-Begin may follow at once if target != bottom. L-Unload has no premise on
    the target view, so a deactivation in flight is never declined.
24. [PAPER Sec 4.2.2] Rules are nondeterministic and no scheduler is
    specified. Assert outcome properties only, never one particular order.

## E. Effects, recovery, equivalence (Sec 3.1, 3.3, 4.3.2)
25. [PAPER Def 8, 12] Inverses are witnessed per state: g(new) == old at the
    state where the effect ran, and may differ from one application to the
    next. Test an effect whose inverse remembers the previous value.
26. [PAPER Thm 16, Def 18] Reverting in reverse order of application is exact
    (LIFO). WARNING: Algorithm 1 lines 6 and 17 and Algorithm 5 line 16 print
    "value o inverse" / "dispose o ctx.dispose"; with "g o f runs g after f"
    that reads FIFO, contradicting Def 18 / Thm 16. Implement newest-first and
    verify against the reference implementation.
27. [PAPER Thm 68, Cor 69] While a fiber is installed, running its accumulator
    leaves every table where the other fibers' steps alone would have left it.
    When its episode closes, its own table is EMPTY (needed by O-Remove).
28. [PAPER Sec 3.3.2, 4.3.2] Recovery is exact up to observational equivalence,
    not bit equality: compare through each key's public operations INCLUDING
    their outcomes. A monotone allocator is not rewound, a heap layout is not
    restored, a message already sent stays sent. Never compare raw memory,
    addresses or generated ids.
29. [PAPER Def 20] get requires the key present; set requires it absent. A
    violated precondition = error, no transition, no inverse registered.
30. [PAPER Def 55-56] Confinement: an effect writes only its fiber's own table
    and values at keys it declared; it reads only those. It can neither read
    nor write control fields of other fibers. Instantiation is the one
    exception.

## F. Independence across components (Sec 3.4, 4.3.2)
31. [PAPER Def 42-47, Lemma 66, Thm 43] Reverting one fiber's effects while
    others stay is exact only for pairwise independent effects. Distinct keys
    are always independent; effects on one key need that key to be
    commutative, a witness the PROVIDER of the key owes.
32. [PAPER Sec 3.4.2] Table-of-entries keys (routes, event listeners) are
    commutative only if each registration gets its own unique entry id and the
    inverse removes exactly that entry (stable ids, never positional indices).
    Ordered chains (middleware) are NOT commutative: do not test that removing
    from the middle preserves the others unless order comes from a declared
    dependency.
33. [PAPER Lemma 67] Entangled fibers (one's provision meets the other's
    declarations) are covered by the rules, not by independence. Operations on
    a provider's value occur only under a committed view, so they never
    interleave with the provider's extension or restriction in the bad order.

## G. Progress, quiescence, confluence (Sec 4.3.4-4.3.5)
34. [PAPER Def 53] quiet(state): every Inactive fiber has target = bottom; every
    Active fiber has target == committed view; no fiber is Reloading or
    Unloading (a failed fiber is admitted, see H). Use as the final assertion
    of every scenario.
35. [PAPER Thm 73] Assuming the precedence relation (n < m iff p_n intersects
    d_m) is acyclic, every iterator has length <= L, and the set of names is
    finite: (1) if not quiet, some lifecycle rule applies (no deadlock);
    (2) the steps acting on fiber n number at most (L+3)(T_n+1), where T_n =
    number of times n's target view turned; within an interval of constant
    target at most L+3 steps act on n. Test both bounds and quiescence.
36. [PAPER Sec 4.3.4] The guard cannot deadlock: after L-Leave / L-Divert marks
    n, its table leaves the published context, so no target can name n and
    every consumer committed to n is itself leaving. Test chains A <- B <- C
    and diamonds, retiring the root provider.
37. [PAPER Sec 4.3.4, 6.5] The calculus assumes names stay finite: no component
    may instantiate itself without bound (directly or indirectly). A
    dependency cycle leaves its members permanently Inactive; it is
    predictable from declarations, so a runtime MAY report it at load time.
38. [PAPER Def 74-76, Lemma 77] Components must be TOTAL on their provision: a
    finished activation has installed every key of p. At quiescence the Active
    fibers are exactly the supported fibers (not retired, parent supported,
    every declared key provided by a supported fiber). [IMPL] Assert
    domain(table) == p after L-Finish in debug builds.
39. [PAPER Thm 80] Confluence / history independence. Hypotheses: quiescent,
    components total, precedence acyclic, no failed fibers. Conclusion: the
    quiescent state equals the one reached by a canonical run (same
    orchestration steps in order, one activation episode per supported fiber
    in dependency order, no deactivations), up to renaming and ignoring
    vestigial entries. Test: for scenarios whose orchestration steps act only
    on orchestrator-inserted fibers, replay all orchestration steps first, then
    run the lifecycle to quiescence once, and compare with the incremental
    run's final state up to equivalence.

## H. Extensions (Sec 4.4)
40. [PAPER Asynchrony] An async host is "inertial": it takes only the landing
    alternative of L-Divert. A fiber whose target turns during an iteration
    deactivates after that iteration lands, holding the inverse it produced.
    An accumulator application in flight needs no inertia (steps of other
    fibers commute with the inverses not yet applied).
41. [PAPER Failure] An iteration may raise an error instead of yielding. A
    raise leaves Reloading like an aborting L-Divert whose target premise is
    dropped: the fiber moves to Unloading with the accumulator built up to the
    failing iteration, ends Inactive having installed nothing (Cor 69), and
    the error is recorded as an outcome on the fiber. L-Begin requires an
    error-free fiber, so it is not retried against an unchanged environment;
    quiet admits a failed fiber whatever its target; the failure stays on that
    fiber and does not reach its parent; siblings keep running. A retry is a
    revision (a fresh fiber without outcome). Confluence excludes failed fibers.
42. [PAPER Isolation] The calculus uses one shared realm; with realms the key
    set becomes K x R and the rules are unchanged. Reassigning a fiber's realm
    at runtime is a revision of that fiber.
43. [PAPER Configuration] Every revision of a running fiber (new config, new
    realms, disable / enable) is a composite of rules: O-Retire, let the
    lifecycle deactivate it, O-Remove (children before parent), reinsert. Dependents
    follow unprompted through the guard and the target comparison.

## I. Core library (Sec 5.1, Algorithms 1-6)
44. [PAPER Alg 1, Sec 5.1.1] effect(callback): the guard is consulted before
    each iteration step; once it trips, only the inverses accumulated so far
    remain. dispose is idempotent: the first call disarms the guard (halting an
    in-flight iteration at its step boundary), waits for the in-flight step to
    land, then runs the recovery; later calls do nothing (running an inverse
    twice would apply it at a state no application produced). The child's
    dispose is composed into the parent context's dispose (see item 26).
45. [PAPER Alg 2] set(key, value) is an effect: install the binding then notify;
    its inverse deletes the binding then notifies. The runtime does not verify
    that an inverse truly reverts its effect; that is the author's obligation.
46. [PAPER Alg 3] notify(keys) calls refresh on every fiber that declares a
    changed key and resolves it in the same realm, and returns those fibers so
    a caller can wait. refresh is idempotent: a neutral change is harmless.
47. [PAPER Alg 4] use(ctx, component, config) is an effect of the parent: its
    callback calls refresh(fiber); its inverse sets target = bottom and unloads.
    Unloading a parent therefore cascades to its children through the tracked
    effect.
48. [PAPER Alg 5] refresh recomputes the target; if unchanged do nothing; store
    it; if a transition is in flight do nothing more (it chains on completion);
    otherwise mark LOADING or UNLOADING BEFORE scheduling anything (the fiber
    stops providing immediately) and start reload / unload. reload commits the
    resolved view first, runs apply, then if target still equals the one it
    started with becomes ACTIVE and notifies dependents of its provided keys,
    else chains into unload. unload first notifies dependents of its provided
    keys and WAITS until they reach INACTIVE (the guard), then runs the
    accumulator, clears the committed view, and becomes INACTIVE or chains into
    reload if the target is not bottom. The wait must sit ahead of the whole
    recovery, not inside one inverse.
49. [PAPER Sec 5.1.3] fiber.target is a digest of the tuple of provider uids. An
    in-place overwrite of a provider's own binding is NOT observed by
    dependents; to propagate a replacement the provider withdraws the binding
    and installs it afresh. Test both behaviours.
50. [PAPER Alg 6, Sec 5.1.4] Proxy-mediated access resolves against the accessing
    fiber's committed view, walking up the parent fibers: first committed
    binding wins; a declared but uncommitted key raises INACTIVE_ACCESS; no
    declaration up to the root raises UNDECLARED_ACCESS. The bare get(key)
    reads the store and never fails (returns the value or nothing).

## J. Loader and HMR (Sec 5.2)
51. [PAPER Def 81, Sec 5.2.1] Entry fields: id (stable reconciliation key), url,
    isolate, intercept, config, disabled. Change dispatch: id/url = rebuild;
    isolate = reassign realms; intercept = update in place with no reload;
    config = handed to the component, a group does a keyed diff over child ids;
    disabled = unload when set, reload when cleared. No load order is needed:
    a fiber whose keys are not yet provided simply waits at L-Begin.
52. [PAPER Alg 8-10] HMR classifies modules (accepted / declined fixed point),
    finds stale entries (dependency tree meets accepted), then reloads
    transactionally: invalidate caches keeping a backup, dispose each stale
    fiber and instantiate from the new module; on any failure restore the
    caches, rebuild every stale entry from the backup, and rethrow. The system
    must never be left half-reloaded.

## K. Boundary and host notes (Sec 6)
53. [PAPER 6.1] Acquisitions (open, malloc, fork) are tracked inside the boundary
    and revertible; emissions (write, send) cross it and act as identity. Never
    test that an emission is undone. Compensation actions compose LIFO but the
    commutation results are proved only against the finer equivalence.
54. [PAPER 6.4] For native hosts, code introduction / retraction is explicit
    dynamic linking (dlopen / dlclose); loading a module is itself an effect
    whose inverses undo the registration of the symbols, types and handlers the
    module introduced. [IMPL] dlclose only after those inverses ran and no
    function pointer into the library is still registered. Zig comptime may
    generate typed accessors (6.4).
55. [PAPER 6.2-6.3, 6.6] Several providers of one key need realms or a broker
    service; interception metadata is consulted at access time and can change
    without any reload; untrusted code needs an external sandbox; key
    identity is nominal (key collision and interface drift are out of scope).

## L. Zig-specific tests [IMPL]
56. Allocation failure: reserve capacity BEFORE performing an effect so OOM can
    never leave an effect without its inverse. Run with
    std.testing.FailingAllocator failing at every allocation point.
57. Lifetimes: nothing frees memory that a committed view, an in-flight
    iteration, or an event payload still references.
58. Single scheduler thread recommended; otherwise state the threading rule and
    add a ThreadSanitizer run.
59. Randomized scheduler test (seeded RNG): random orchestration actions
    (insert with random d/p, retire, remove when legal, provision effects, plus
    injected iteration errors) interleaved with randomly chosen ENABLED
    lifecycle rules. After every step assert items 3, 4 and 20. At the end
    assert items 34, 35 (both bounds), 39 and zero leaks. Replay each seed
    under a second schedule and compare the final states (item 39).
