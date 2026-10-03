//! Gluon — a Zig implementation of spatiotemporal composability.
//! See plan/building-blocks.md for the paper-to-module map.
//!
//! Implements the core library of the Cordis meta-framework (arXiv:2608.25512):
//! revertible effects, reactive coeffects, the unified context paradigm, the
//! component lifecycle calculus, and a declarative loader with HMR.

pub const accumulator = @import("effect/accumulator.zig");
pub const Accumulator = accumulator.Accumulator;
pub const Inverse = accumulator.Inverse;

pub const effect_fn = @import("effect/effect_fn.zig");
pub const Effect = effect_fn.Effect;

pub const effect_iter = @import("effect/effect_iter.zig");
pub const Iterator = effect_iter.Iterator;
pub const Guard = effect_iter.Guard;
pub const execute = effect_iter.execute;

pub const type_id = @import("context/type_id.zig");
pub const TypeId = type_id.TypeId;
pub const typeId = type_id.typeId;

pub const store = @import("coeffect/store.zig");
pub const Store = store.Store;
pub const Key = store.Key;

pub const context = @import("context/context.zig");
pub const Context = context.Context;

pub const spec = @import("coeffect/spec.zig");
pub const Spec = spec.Spec;
pub const Classification = spec.Classification;

pub const interception = @import("coeffect/interception.zig");
pub const InterceptTable = interception.InterceptTable;

pub const loader = @import("loader/loader.zig");
pub const Loader = loader.Loader;
pub const ConfigEntry = loader.ConfigEntry;

pub const key_registry = @import("coeffect/key_registry.zig");
pub const Coeffect = key_registry.Coeffect;
pub const CommutativityWitness = key_registry.CommutativityWitness;
pub const CommutativityKind = key_registry.CommutativityKind;

pub const component = @import("component/component.zig");
pub const Component = component.Component;
pub const Fiber = component.Fiber;
pub const FiberId = component.FiberId;
pub const Phase = component.Phase;
pub const View = component.View;

pub const registry = @import("component/registry.zig");
pub const Registry = registry.Registry;

pub const lifecycle = @import("component/lifecycle.zig");
pub const Orchestrator = lifecycle.Orchestrator;

test {
    // Pull in referenced modules' tests.
    _ = accumulator;
    _ = effect_fn;
    _ = effect_iter;
    _ = type_id;
    _ = store;
    _ = context;
    _ = spec;
    _ = component;
    _ = registry;
    _ = lifecycle;
    _ = @import("component/lifecycle_test.zig");
    _ = interception;
    _ = loader;
    _ = @import("loader/loader_test.zig");
    _ = key_registry;
}
