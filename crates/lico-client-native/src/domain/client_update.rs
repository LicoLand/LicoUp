//! Fail-closed signed client update workflow with public metadata only.

mod apply;
mod canonical;
mod check;
mod constants;
mod dispatch;
mod download;
mod keys;
mod macos_runner;
mod metadata;
mod model;
mod params;
mod release;
mod revocation;
mod selection;
mod signature;
mod staging;
mod status;
mod verify;

pub use apply::{apply, rollback};
pub use check::check;
pub use constants::{CLIENT_UPDATE_MANIFEST_SCHEMA, CLIENT_UPDATE_MODE};
pub use dispatch::dispatch;
pub use download::download;
pub use status::status;
pub use verify::verify;

#[cfg(test)]
mod tests;
