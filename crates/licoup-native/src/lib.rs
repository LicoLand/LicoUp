#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

pub mod contracts;
pub mod core;
pub mod domain;
pub mod ffi;
pub mod platform;

pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}

pub use core::licoarc_relay;
