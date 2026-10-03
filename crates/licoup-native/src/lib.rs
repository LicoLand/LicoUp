#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

pub mod contracts;
pub mod core;
pub mod domain;
pub mod ffi;
pub mod platform;
// The Agent inventory port: the facts `licoup-agent-targets` reads from the
// layers above it. It is declared by the inventory crate and composed by
// `domain::target_port`; this alias keeps the two naming one path without
// widening the host's public surface.
pub(crate) use licoup_agent_targets::port;
