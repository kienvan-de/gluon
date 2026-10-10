/*
 * gluon_abi.h — C ABI contract for Gluon dynamic plugins.
 *
 * This header is the ONLY file a plugin needs to include.
 * It is the canonical translation of src/dynplugin/abi.zig into C.
 * Any language with C FFI (C, C++, Rust, Go, Python/cffi, ...) can
 * implement a Gluon plugin by conforming to this interface.
 *
 * ── What a plugin must export ────────────────────────────────────
 *
 *   The single symbol Gluon resolves via dlopen/LoadLibrary:
 *
 *     const GluonExtVTable* gluon_plugin_vtable(void);
 *
 *   Return a pointer to a static vtable. Gluon calls it once after
 *   loading the library; the pointer must be valid for the process lifetime.
 *
 * ── How plugins communicate ───────────────────────────────────────
 *
 *   All communication goes through the GluonHostApi passed to activate().
 *
 *   Pattern A — Opaque service (tight coupling, shared C struct):
 *     Provider: host->provide_opaque(ctx, "my.service", ptr, free_fn)
 *     Consumer: retrieved from the coeffect store as a GluonExtService*,
 *               then cast ptr to the agreed-upon C struct.
 *
 *   Pattern B — JSON events (loose coupling, no struct layout agreement):
 *     Publisher: host->emit(ctx, "my.event", "{\"value\":42}")
 *     Subscriber: host->subscribe(ctx, "my.event", handler_fn, state)
 *     Both sides agree only on the event name and the JSON schema.
 *
 * ── Lifecycle ─────────────────────────────────────────────────────
 *
 *   1. Gluon calls gluon_plugin_vtable() to get the vtable.
 *   2. Gluon calls vtable->meta() to read inject/provide key declarations.
 *   3. Once all inject keys are satisfied, Gluon calls vtable->activate(host).
 *      The plugin subscribes to events, provides services, allocates state.
 *      Returns an opaque handle on success, NULL on failure.
 *   4. When the plugin is removed (or a dependency disappears), Gluon calls
 *      vtable->deactivate(handle). The plugin must undo everything it did
 *      in activate(): unsubscribe, withdraw services, free memory.
 *      After deactivate() returns, `host` is invalid — do not use it.
 *
 * ── ABI stability guarantee ───────────────────────────────────────
 *
 *   New fields will only be added at the END of GluonHostApi and
 *   GluonExtVTable. Existing field offsets never change. Check
 *   GLUON_ABI_VERSION to detect which fields are available.
 */

#ifndef GLUON_ABI_H
#define GLUON_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Version ─────────────────────────────────────────────────────── */

/** Increment when the ABI changes in a backward-incompatible way. */
#define GLUON_ABI_VERSION 1

/* ── Forward declarations ─────────────────────────────────────────── */

typedef struct GluonHostApi    GluonHostApi;
typedef struct GluonExtMeta GluonExtMeta;
typedef struct GluonExtVTable GluonExtVTable;

/**
 * Opaque handle the plugin returns from activate().
 * Gluon stores it and passes it back to deactivate().
 * The plugin defines the struct; cast to its own type inside activate/deactivate.
 */
typedef void GluonExtHandle;

/* ── Primitive types ──────────────────────────────────────────────── */

/** Subscription token returned by subscribe(). Pass to unsubscribe(). */
typedef uint64_t GluonSubToken;

/**
 * Event handler registered via subscribe().
 *   state — the opaque pointer the plugin passed to subscribe().
 *   json  — null-terminated JSON payload. Valid ONLY for the duration of
 *           the call. Copy it if you need it after the handler returns.
 */
typedef void (*GluonHandlerFn)(void* state, const char* json);

/**
 * Optional cleanup callback for opaque service values.
 * Called by Gluon when the provision is withdrawn (on deactivation of the
 * providing plugin, or via withdraw_opaque). Pass NULL if no cleanup needed.
 */
typedef void (*GluonFreeFn)(void* ptr);

/* ── Ext metadata ──────────────────────────────────────────────── */

/**
 * Describes the plugin's coeffect interface.
 * Returned by GluonExtVTable.meta; all pointers must be valid for the
 * process lifetime (point to static/global data).
 */
struct GluonExtMeta {
    /** Human-readable plugin name (null-terminated, used in logs). */
    const char* name;

    /**
     * Keys this plugin REQUIRES from the environment before it can activate.
     * Null-terminated array of null-terminated C strings.
     * Pass a pointer to a single NULL entry if no dependencies.
     * Example: static const char* inject[] = {"db.port", "app.bus", NULL};
     */
    const char* const* inject;

    /**
     * Keys this plugin PROVIDES to the environment when active.
     * Null-terminated array of null-terminated C strings.
     * Pass a pointer to a single NULL entry if nothing is provided.
     * Example: static const char* provide[] = {"greeter.service", NULL};
     */
    const char* const* provide;
};

/* ── Host API ─────────────────────────────────────────────────────── */

/**
 * The interface Gluon passes to activate(). All calls are synchronous.
 * `ctx` is an opaque Gluon-internal pointer — pass it back unchanged to
 * every function. It routes the call to the correct fiber/context.
 *
 * IMPORTANT: `host` (and thus all functions reachable through it) is valid
 * ONLY until deactivate() returns. Do not store `host` beyond that point.
 * It IS safe to store `host` in your GluonExtHandle for use during
 * the plugin's active lifetime (between activate and deactivate).
 */
struct GluonHostApi {
    /** Opaque Gluon context — pass unchanged to every function below. */
    void* ctx;

    /* ── EventBus (Pattern B: pub/sub with JSON payloads) ──────────── */

    /**
     * Subscribe to `event` on the shared EventBus.
     * `handler` is called synchronously for each emit on this event.
     * `state` is passed through to `handler` unchanged (may be NULL).
     *
     * Returns a GluonSubToken to pass to unsubscribe(), or 0 on failure.
     * NOTE: token 0 is ALSO a valid token (the first subscription ever gets
     * tag 0). Check success via bus listener count, not by token == 0.
     */
    GluonSubToken (*subscribe)(void* ctx,
                               const char* event,
                               GluonHandlerFn handler,
                               void* state);

    /**
     * Remove the subscription identified by `token`. Idempotent — safe to
     * call even if the subscription was already removed.
     */
    void (*unsubscribe)(void* ctx, GluonSubToken token);

    /**
     * Emit `json` to all current listeners of `event`.
     * `json` must be a null-terminated string. It is valid ONLY during the
     * call — listeners must copy it if they need it after their handler returns.
     * This is a "fire and forget" — no return value, no inverse tracked.
     */
    void (*emit)(void* ctx, const char* event, const char* json);

    /* ── Opaque service store (Pattern A: typed service provision) ──── */

    /**
     * Provision an opaque service pointer under `key`.
     *
     * `ptr`     — your service pointer (e.g. a struct with function pointers).
     * `free_fn` — called with `ptr` when the provision is withdrawn. Pass
     *             NULL if the pointed-to data needs no cleanup (static lifetime).
     *
     * Gluon tracks the inverse: on deactivation, free_fn(ptr) is called and
     * the key is removed from the coeffect store automatically.
     *
     * Returns 0 on success, non-zero on failure (e.g. key already provided
     * by another plugin — Gluon enforces single-source per key).
     */
    int (*provide_opaque)(void* ctx,
                          const char* key,
                          void* ptr,
                          GluonFreeFn free_fn);  /* nullable */

    /**
     * Explicitly withdraw a previously provisioned service.
     * Calls free_fn(ptr) (if non-NULL) and removes the key from the store.
     * This is optional — Gluon's LIFO rollback calls it automatically on
     * deactivation. Use this for hot-unprovisioning while staying active.
     */
    void (*withdraw_opaque)(void* ctx, const char* key);
};

/* ── Ext vtable ────────────────────────────────────────────────── */

/**
 * The vtable a plugin exports via the `gluon_plugin_vtable` symbol.
 * Gluon resolves this symbol once after dlopen and calls it to get the vtable.
 * The vtable pointer must be valid for the process lifetime — return &my_vtable
 * where my_vtable is a static/global GluonExtVTable.
 */
struct GluonExtVTable {
    /**
     * Return static plugin metadata. Called once after dlopen; result cached.
     * The returned pointer must be valid for the process lifetime.
     */
    const GluonExtMeta* (*meta)(void);

    /**
     * Activate the plugin.
     * `host` provides all Gluon runtime services and is valid until
     * deactivate() returns. Store it (in your handle) if you need it later.
     *
     * Perform all setup here:
     *   - Subscribe to events: host->subscribe(ctx, "event", handler, state)
     *   - Provide services:    host->provide_opaque(ctx, "key", ptr, free_fn)
     *   - Allocate private state.
     *
     * Return an opaque handle on success (cast your own struct to void*).
     * Return NULL on failure — Gluon marks the plugin as FAILED.
     */
    GluonExtHandle* (*activate)(const GluonHostApi* host);

    /**
     * Deactivate the plugin.
     * Undo everything activate() did:
     *   - Unsubscribe from events: host->unsubscribe(ctx, token)
     *   - Withdraw services:       host->withdraw_opaque(ctx, "key")
     *   - Free private state (your handle).
     *
     * After this function returns:
     *   - `host` is INVALID — do not call any host functions.
     *   - Gluon's LIFO rollback also runs automatically for any effects tracked
     *     through the host API (events subscribed via host->subscribe, services
     *     provided via host->provide_opaque). Calling unsubscribe/withdraw here
     *     is optional but recommended for explicitness.
     */
    void (*deactivate)(GluonExtHandle* handle);
};

/* ── The exported symbol ──────────────────────────────────────────── */

/**
 * Every Gluon plugin must export this function.
 * Gluon resolves it by name ("gluon_plugin_vtable") after dlopen.
 *
 * Implementation pattern:
 *
 *   static const GluonExtVTable MY_VTABLE = {
 *       .meta       = my_meta,
 *       .activate   = my_activate,
 *       .deactivate = my_deactivate,
 *   };
 *
 *   GLUON_EXPORT const GluonExtVTable* gluon_plugin_vtable(void) {
 *       return &MY_VTABLE;
 *   }
 */
#ifdef _WIN32
#  define GLUON_EXPORT __declspec(dllexport)
#else
#  define GLUON_EXPORT __attribute__((visibility("default")))
#endif

/* ── GluonExtService ─────────────────────────────────────────────── */

/**
 * The Zig-side wrapper stored in the coeffect store for opaque services.
 * When a plugin calls provide_opaque(), Gluon boxes the pointer into this
 * struct and stores it under the key.
 *
 * A consumer (native Zig or another dynamic plugin that knows the key) reads
 * it from the store as a `*const GluonExtService`, then casts `.ptr` to the
 * expected C struct type.
 *
 * Note: consumers that are native Zig components retrieve this via
 *   ctx.get(*const GluonExtService, extServiceKey("my.service"))
 * and then cast .ptr.
 */
typedef struct {
    /** The opaque service pointer the plugin provided. */
    void* ptr;
    /** Cleanup callback (may be NULL). Called when the provision is withdrawn. */
    GluonFreeFn free_fn;  /* nullable */
} GluonExtService;

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GLUON_ABI_H */
