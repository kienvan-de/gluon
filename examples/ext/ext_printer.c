/*
 * ext_printer.c — A Gluon plugin written in pure C.
 *
 * Implements the same printer plugin as ext_printer.zig — subscribes to
 * "print" events on the shared EventBus and writes the JSON payload to stdout.
 *
 * Build (Linux):
 *   cc -shared -fPIC -o libext_printer.so ext_printer.c
 *
 * Build (macOS):
 *   cc -shared -o libext_printer.dylib ext_printer.c
 *
 * Build (Windows):
 *   cl /LD ext_printer.c /Fe:ext_printer.dll
 *
 * Load in Gluon:
 *   var loader = try gluon.ExtLoader.open(allocator, "libext_printer.so");
 *   defer loader.deinit();
 *   const id = try orch.loadWithConfig(
 *       loader.pluginComponent(),
 *       gluon.component.root,
 *       loader.vtableConfig(),
 *   );
 */

#include "gluon_abi.h"
#include <stdio.h>
#include <stdlib.h>

/* ── Ext metadata ─────────────────────────────────────────────── */

static const char* INJECT[]  = { "gluon.dyn.bus", NULL };
static const char* PROVIDE[] = { NULL };

static const GluonExtMeta META = {
    .name    = "c_printer",
    .inject  = INJECT,
    .provide = PROVIDE,
};

/* ── Private handle ──────────────────────────────────────────────── */

typedef struct {
    GluonSubToken token;
    const GluonHostApi* host;   /* valid until deactivate() returns */
} PrinterHandle;

/* ── Event handler ───────────────────────────────────────────────── */

static void on_print(void* state, const char* json) {
    (void)state;
    /* In a real plugin: parse json with a C JSON library. */
    printf("[c_printer] %s\n", json);
    fflush(stdout);
}

/* ── Vtable functions ────────────────────────────────────────────── */

static const GluonExtMeta* plugin_meta(void) {
    return &META;
}

static GluonExtHandle* plugin_activate(const GluonHostApi* host) {
    PrinterHandle* h = malloc(sizeof(PrinterHandle));
    if (!h) return NULL;

    h->token = host->subscribe(host->ctx, "print", on_print, NULL);
    h->host  = host;
    return (GluonExtHandle*)h;
}

static void plugin_deactivate(GluonExtHandle* handle) {
    PrinterHandle* h = (PrinterHandle*)handle;
    h->host->unsubscribe(h->host->ctx, h->token);
    free(h);
}

/* ── The exported symbol ─────────────────────────────────────────── */

static const GluonExtVTable VTABLE = {
    .meta       = plugin_meta,
    .activate   = plugin_activate,
    .deactivate = plugin_deactivate,
};

GLUON_EXPORT const GluonExtVTable* gluon_plugin_vtable(void) {
    return &VTABLE;
}
