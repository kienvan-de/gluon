// ext_printer.rs — A Gluon plugin written in Rust.
//
// Implements the printer plugin (subscribes to "print" events) using the
// same C ABI as the C and Zig versions. No Gluon Rust crate needed —
// only the types from gluon_abi.h, transcribed to Rust below.
//
// Build:
//   # Add to Cargo.toml:
//   #   [lib]
//   #   crate-type = ["cdylib"]
//   cargo build --release
//   # Output: target/release/libext_printer_rs.so  (Linux)
//   #         target/release/libext_printer_rs.dylib (macOS)
//
// The plugin is loaded with ExtLoader.open exactly like the C and Zig versions.

#![allow(non_snake_case, non_camel_case_types)]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::io::Write;

// ── C ABI types (transcription of gluon_abi.h) ─────────────────────
//
// In a real project these would come from a `gluon-sys` crate generated
// by `bindgen` from gluon_abi.h. Here they are written by hand to show
// the correspondence is mechanical.

type GluonSubToken = u64;

type GluonHandlerFn = unsafe extern "C" fn(state: *mut c_void, json: *const c_char);
type GluonFreeFn    = unsafe extern "C" fn(ptr: *mut c_void);

/// Opaque plugin handle. Rust uses `Box<PrinterState>` erased to *mut c_void.
type GluonExtHandle = c_void;

#[repr(C)]
struct GluonExtMeta {
    name:    *const c_char,
    inject:  *const *const c_char,   // null-terminated array
    provide: *const *const c_char,   // null-terminated array
}

// Required: repr(C) + all fields are C function pointers with matching sigs.
#[repr(C)]
struct GluonHostApi {
    ctx:              *mut c_void,
    subscribe:        unsafe extern "C" fn(*mut c_void, *const c_char, GluonHandlerFn, *mut c_void) -> GluonSubToken,
    unsubscribe:      unsafe extern "C" fn(*mut c_void, GluonSubToken),
    emit:             unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char),
    provide_opaque:   unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_void, Option<GluonFreeFn>) -> c_int,
    withdraw_opaque:  unsafe extern "C" fn(*mut c_void, *const c_char),
}

#[repr(C)]
struct GluonExtVTable {
    meta:       unsafe extern "C" fn() -> *const GluonExtMeta,
    activate:   unsafe extern "C" fn(*const GluonHostApi) -> *mut GluonExtHandle,
    deactivate: unsafe extern "C" fn(*mut GluonExtHandle),
}

// ── Ext metadata ─────────────────────────────────────────────────

// Static null-terminated C strings and arrays.
// SAFETY: these are `'static` and immutable — safe to return from `meta()`.
static INJECT_LIST:  [*const c_char; 2] = [c"gluon.dyn.bus".as_ptr(), std::ptr::null()];
static PROVIDE_LIST: [*const c_char; 1] = [std::ptr::null()];

static META: GluonExtMeta = GluonExtMeta {
    name:    c"rust_printer".as_ptr(),
    inject:  INJECT_LIST.as_ptr(),
    provide: PROVIDE_LIST.as_ptr(),
};

// ── Private plugin state ─────────────────────────────────────────────

struct PrinterState {
    token: GluonSubToken,
    host:  *const GluonHostApi,   // valid until deactivate() returns
}

// SAFETY: Gluon calls activate/deactivate on one thread at a time.
unsafe impl Send for PrinterState {}

// ── Event handler ────────────────────────────────────────────────────

unsafe extern "C" fn on_print(_state: *mut c_void, json: *const c_char) {
    let msg = unsafe { CStr::from_ptr(json) }.to_string_lossy();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let _ = writeln!(out, "[rust_printer] {}", msg);
}

// ── Vtable functions ─────────────────────────────────────────────────

unsafe extern "C" fn plugin_meta() -> *const GluonExtMeta {
    &META
}

unsafe extern "C" fn plugin_activate(host: *const GluonHostApi) -> *mut GluonExtHandle {
    let host_ref = unsafe { &*host };

    let token = unsafe {
        (host_ref.subscribe)(
            host_ref.ctx,
            c"print".as_ptr(),
            on_print,
            std::ptr::null_mut(),
        )
    };

    let state = Box::new(PrinterState { token, host });
    Box::into_raw(state) as *mut GluonExtHandle
}

unsafe extern "C" fn plugin_deactivate(handle: *mut GluonExtHandle) {
    let state = unsafe { Box::from_raw(handle as *mut PrinterState) };
    let host = unsafe { &*state.host };
    unsafe { (host.unsubscribe)(host.ctx, state.token) };
    // state is dropped here, freeing PrinterState.
}

// ── The exported symbol ──────────────────────────────────────────────

static VTABLE: GluonExtVTable = GluonExtVTable {
    meta:       plugin_meta,
    activate:   plugin_activate,
    deactivate: plugin_deactivate,
};

#[no_mangle]
pub unsafe extern "C" fn gluon_plugin_vtable() -> *const GluonExtVTable {
    &VTABLE
}
