//! Gluon — a Zig implementation of spatiotemporal composability.
//! See plan/building-blocks.md for the paper-to-module map.
//!
//! Phase 1 (in progress): effect foundations.

pub const accumulator = @import("effect/accumulator.zig");
pub const Accumulator = accumulator.Accumulator;
pub const Inverse = accumulator.Inverse;

pub const effect_fn = @import("effect/effect_fn.zig");
pub const Effect = effect_fn.Effect;

test {
    // Pull in referenced modules' tests.
    _ = accumulator;
    _ = effect_fn;
}
