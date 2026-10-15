# Dynamic Plugin Support — Review Findings

Review of Gluon's dynamic plugin (dlopen) implementation against the
Spatiotemporal Composability paper's guarantees.

**Scope reviewed:** `src/ext/gluon_abi.zig`, `src/ext/loader.zig`,
`src/ext/host.zig`, and supporting infrastructure (`src/coeffect/store.zig`,
`src/event/bus.zig`, `src/effect/accumulator.zig`, `src/context/context.zig`,
`src/component/lifecycle.zig`, `src/component/registry.zig`), plus the example
plugins under `examples/ext/`.

**Overall:** The core design is sound — a plugin's `activate`/`deactivate` is
mapped onto Gluon's effect/inverse (LIFO) model, so unload drives plugin
cleanup through the same path native components use. The issues below cluster
around (a) opaque-service ownership/lifecycle and (b) dynamic provisions
bypassing the registry's spatial-reconciliation model.

Each finding is ranked and marked with its confirmation status.

---

## Critical

### C1 — Double `free_fn` on explicit `withdraw_opaque` + LIFO rollback
**Status: FIXED** (regression test added) · `src/ext/host.zig` (withdraw / inv_a),
`src/ext/gluon_abi.zig` (`ExtService.live`)

**Resolution:** `ExtService` gained a `live` flag and `free()` is now idempotent
— it runs `free_fn` only on the first call and clears `live`. `cWithdrawOpaque`
and the tracked Inverse A both route through it, so withdraw-then-unload calls
`free_fn` exactly once. Fixed together with M8 (`live` is set true only after
`store.set` succeeds). Regression test: "C1: explicit withdraw then unload calls
free_fn exactly once" (counts invocations; was 2, now 1). Full `zig build test`
and `zig build test-ext` (real dlopen) pass.

---

<details><summary>Original finding (for reference)</summary>

**Status: CONFIRMED** · `src/ext/host.zig:272` (withdraw), `:234-254` (inv_a)

`cProvideOpaque` tracks two inverses on the accumulator (`inv_a` = `svc.free()`
+ destroy `ExtService`; `inv_b` = `store.restrict`). `cWithdrawOpaque` calls
`svc.free()` and `store.restrict(key)` directly but does **not** cancel or
remove `inv_a`/`inv_b`.

On the fiber's later unload:
- `inv_a.call` runs `svc.free()` a **second** time → `free_fn(ptr)` is invoked
  twice on a pointer the plugin already released (double-free / UAF inside the
  plugin's allocator).
- `inv_b.call` runs `restrict` on an already-removed key (safe — fails
  silently).

The greeter example masks this because it passes `free_fn = null`
(`examples/ext/ext_greeter.zig:57`). Any plugin that passes a real `free_fn`
**and** calls `withdraw_opaque` explicitly will double-free.

**Fix direction:** give the provision a shared "live" flag (heap cell shared by
`inv_a` and `cWithdrawOpaque`). `withdraw_opaque` sets it false after freeing;
`inv_a.call` becomes a no-op when already withdrawn. Same flag resolves M8.

</details>

---

### C2 — Event payload silently truncated at 4096 bytes
**Status: CONFIRMED** · `src/ext/host.zig:99-107` (`wrappedCall`)

Payloads are copied into a fixed `buf: [4096]u8` and NUL-terminated at
`@min(msg.len, 4095)`. A payload ≥ 4096 bytes is silently truncated — the C
plugin receives corrupted/invalid JSON with no error signal. Given the ABI is
"JSON by convention," this is a real data-loss path for any non-trivial event.
Also a 4 KiB stack buffer per dispatch.

**Fix direction:** allocate a buffer sized to `msg.len + 1` for the duration of
the call (free after), or extend the ABI handler signature to carry an explicit
length so no NUL-termination/copy is required.

---

## High

### H3 — Dynamic opaque provisions bypass the registry (invisible to spatial reconcile)
**Status: PARTIALLY FIXED** — narrowed on re-review, guard applied

On re-verification: `meta.provide` keys ARE wired through the registry path
(`keysFromCList` → `component.provide` → `reserveProvisions` at insert;
`notify(component.provide)` fires at reload). The real gap was narrower:
**undeclared keys** — a plugin calling `provide_opaque` with a key not in
`meta.provide` bypassed the registry entirely.

**Fix:** runtime guard in `cProvideOpaque` rejects undeclared keys (`-1`).
`DynConfig` struct bundles vtable + `provide_keys` through `config` pointer so
`HostBridge.declared_provide` is populated at activation. Regression test:
"H3: cProvideOpaque rejects keys not declared in meta.provide" in `loader.zig`.

---

### H4 — Every plugin is asserted `.trivial` commutative regardless of what it provides
**Status: FIXED** (regression tests added) · `src/ext/loader.zig`, `src/ext/gluon_abi.zig`, `include/gluon_abi.h`

**Fix:** `GluonCommutativity` enum added to `gluon_abi.zig`; `commutativity`
field added to `GluonExtMeta` (default `.trivial` = 0, backward-compatible with
ABI v1 plugins). `loader.zig` translates it via `witnessFromMeta()` into
`Extension.provide_witness`; unknown future values map conservatively to
`.non_commutative`. C header updated with `GluonCommutativity` enum + field;
`GLUON_ABI_VERSION` bumped to 2.

---

### H5 — `cUnsubscribe` relies on an undocumented global-tag-uniqueness invariant
**Status: DOCUMENTED** · `src/ext/host.zig:cUnsubscribe`

The scan-all-buckets approach is correct because `EventBus.next_tag` is a
single global counter across all events, making each tag globally unique. An
O(1) `sub_map` optimization was attempted but encountered a Zig 0.17 alignment
bug with `AutoHashMapUnmanaged` in heap-allocated structs. The invariant is now
explicitly documented in the `cUnsubscribe` function comment. The O(1) fix is
deferred to a future Zig version.

---

## Medium

### M6 — No `dlclose`; a plugin mapping can never be reclaimed or hot-swapped
**Status: CONFIRMED** · `src/ext/loader.zig:27-29, 248-251`

By design, unloading a fiber never `dlclose`s; only `ExtLoader.deinit` closes,
and nothing reclaims the mapping while the loader lives. There is no path to
replace a recompiled `.so` at runtime. For a runtime whose headline is clean
add/remove and hot-swap, the inability to unmap the library is a real gap
(acceptable as a documented limitation, but should be explicit).

**Fix applied:** header comment in `loader.zig` now explicitly documents the
no-dlclose design, why (vtable pointer lifetime), and what a future
reference-counting implementation would require.

---

### M7 — Plugin-returned pointers trusted without validation; borrowed key strings
**Status: PARTIALLY FIXED** · `src/ext/loader.zig:keysFromCList`

**Fix applied (borrowed strings):** `keysFromCList` now dupes each key name
into host-owned memory (`allocator.dupe`), and `Extension.deinit` frees them.
Key names no longer borrow the plugin's static storage — the host lifetime is
fully independent. Affected test updated to free duped names.

Remaining (out of scope for this pass): unbounded array walk and immediate
`meta()` deref without validation remain unguarded. A malformed plugin still
causes OOB reads. This is acceptable for trusted plugins; hostile-plugin
sandboxing is a larger separate effort.

---

### M8 — `cProvideOpaque` runs `free_fn` on a value that was never provided (OOM path)
**Status: FIXED** (with C1) · `src/ext/host.zig:262-272`, `src/ext/gluon_abi.zig`

**Resolution:** `svc.live` is set true only after `store.set` succeeds. If the
provision fails before the binding is installed, `live` stays false, so the
recover-time inverse's `svc.free()` is a no-op and `free_fn` never runs on an
un-provided value. Covered by the existing OOM-safety discipline; no leak.

<details><summary>Original finding (for reference)</summary>

**Status: CONFIRMED** (author-documented) · `src/ext/host.zig:258-265`

If `store.set` fails, `inv_a` is already tracked, so recover calls
`svc.free()` → `free_fn(ptr)` on a service that never reached the store. Shares
a root cause with C1: the `ExtService` inverse fires regardless of whether the
provision actually took effect.

**Fix direction:** the shared "live/provided" flag from C1 — only set it true
after `store.set` succeeds; `inv_a.call` no-ops when false.

</details>

---

### M9 — No threading contract despite a surface that invites concurrency
**Status: FIXED (documented)** · `src/ext/gluon_abi.zig`, `include/gluon_abi.h`

**Fix applied:** explicit threading contract added to `gluon_abi.zig` module
doc and `include/gluon_abi.h`. Contract: all `GluonHostApi` calls are
single-threaded and synchronous; a plugin must not call host functions from
background threads. Plugins that spawn threads must complete all host
interactions before returning from `activate()` and must not call host
functions from threads during or after `deactivate()`.

<details><summary>Original finding (for reference)</summary>

`EventBus`, `Store`, and the accumulator have no synchronization. The ABI says
calls are synchronous, but the `host_api` pointer is deliberately made stable
so a plugin can store it, which naturally invites off-thread calls with no
guardrail.

</details>
as contract.

**Fix direction:** state the single-threaded-call contract explicitly in
`gluon_abi.zig` and the header, or provide a documented thread-safe entry point.

---

## Low

### L10 — `activate` null-handle convention is lossy
**Status: DOCUMENTED** · `src/ext/gluon_abi.zig:GluonExtHandle`

`null` from `activate` means failure, so a plugin with no handle state must
return a non-null sentinel. A doc comment on `GluonExtHandle` now explains the
convention and acknowledges the limitation (a `GluonActivateResult` enum would
fix it but is a breaking ABI change).

### L11 — Payload-type mismatch across the ABI boundary is silently dropped
**Status: FIXED (debug diagnostic added)** · `src/ext/host.zig:cEmit`

`cEmit` now checks in debug builds: if an event has listeners but zero were
invoked, it prints a warning naming the event and the required payload type
(`[]const u8`). The check only fires when listeners exist (registered but
wrong-typed), not on normal empty-event emits.

### L12 — Self-contradicting comment in `cSubscribe` OOM branch
**Status: FIXED** · `src/ext/host.zig:cSubscribe`

The `cSubscribe` function was rewritten cleanly during the H5 iteration;
the old stream-of-consciousness OOM comment is gone. The current code and
comment are consistent.

---

## Final status

| # | Finding | Status |
|---|---|---|
| C1 | Double `free_fn` on withdraw + rollback | **FIXED** |
| C2 | Payload truncated at 4096 B | **FIXED** |
| H3 | Undeclared key bypass guard | **FIXED** (narrowed scope) |
| H4 | Fabricated `.trivial` witness | **FIXED** |
| H5 | cUnsubscribe global-tag reliance | **DOCUMENTED** |
| M6 | No dlclose / no true hot-swap | **DOCUMENTED** |
| M7 | Borrowed key strings | **FIXED** (bounds-check deferred) |
| M8 | free_fn on never-provided value | **FIXED** (with C1) |
| M9 | No threading contract | **DOCUMENTED** |
| L10 | Lossy null-handle convention | **DOCUMENTED** |
| L11 | Silent payload TypeId mismatch | **FIXED** (debug diagnostic) |
| L12 | Self-contradicting comment | **FIXED** (rewritten) |
