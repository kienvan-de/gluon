// ext_greeter.c — A Gluon plugin written in pure C.
//
// Provides a "greeter.service" opaque C service struct.
// Demonstrates Pattern A (service via coeffect store) from C.
//
// The GreeterService struct is the shared contract between this plugin and
// its consumers. In a real project it would live in a shared header
// (e.g. greeter_service.h) that both the provider and consumers include.
//
// Build (Linux):   cc -shared -fPIC -o libext_greeter.so ext_greeter.c
// Build (macOS):   cc -shared -o libext_greeter.dylib ext_greeter.c
// Build (Windows): cl /LD ext_greeter.c /Fe:ext_greeter.dll

#include "gluon_abi.h"
#include <stdio.h>
#include <stdlib.h>

// ── Shared service contract (would be in greeter_service.h) ────────
//
// Both this plugin AND any consumer agree on this struct layout.
// Consumers cast `GluonExtService.ptr` to `GreeterService*`.

typedef struct {
    void (*greet)(const char* name);
} GreeterService;

// ── Concrete implementation ─────────────────────────────────────────

static void greet_impl(const char* name) {
    printf("[c_greeter] Hello, %s!\n", name);
    fflush(stdout);
}

// Static service instance — valid for the process lifetime.
static const GreeterService GREETER_SVC = {
    .greet = greet_impl,
};

// ── Ext metadata ─────────────────────────────────────────────────

static const char* INJECT[]  = { NULL };
static const char* PROVIDE[] = { "greeter.service", NULL };

static const GluonExtMeta META = {
    .name    = "c_greeter",
    .inject  = INJECT,
    .provide = PROVIDE,
};

// ── Private handle ──────────────────────────────────────────────────

typedef struct {
    const GluonHostApi* host;
} GreeterHandle;

// ── Vtable functions ────────────────────────────────────────────────

static const GluonExtMeta* plugin_meta(void) {
    return &META;
}

static GluonExtHandle* plugin_activate(const GluonHostApi* host) {
    GreeterHandle* h = malloc(sizeof(GreeterHandle));
    if (!h) return NULL;

    // Provision the service — free_fn is NULL because GREETER_SVC is static.
    int rc = host->provide_opaque(host->ctx, "greeter.service",
                                  (void*)&GREETER_SVC, NULL);
    if (rc != 0) { free(h); return NULL; }

    h->host = host;
    return (GluonExtHandle*)h;
}

static void plugin_deactivate(GluonExtHandle* handle) {
    GreeterHandle* h = (GreeterHandle*)handle;
    // Explicit withdraw (optional — Gluon's LIFO also does it automatically).
    h->host->withdraw_opaque(h->host->ctx, "greeter.service");
    free(h);
}

// ── The exported symbol ─────────────────────────────────────────────

static const GluonExtVTable VTABLE = {
    .meta       = plugin_meta,
    .activate   = plugin_activate,
    .deactivate = plugin_deactivate,
};

GLUON_EXPORT const GluonExtVTable* gluon_plugin_vtable(void) {
    return &VTABLE;
}
