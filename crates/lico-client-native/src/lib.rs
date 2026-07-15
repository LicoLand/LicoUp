#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

pub mod core;
pub mod domain;
pub mod ffi;
pub mod platform;

pub use core::secure_mesh_relay_envelope;
