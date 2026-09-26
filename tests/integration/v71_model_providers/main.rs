//! v7.1 model provider integration tests (V7-U4).
//!
//! These tests exercise the C10 runtime against the published contract crate
//! and against a real synthetic provider process:
//!
//! - `config_path` — the compatible-API path: configuration only, hot updates,
//!   aliases, unknown facts.
//! - `generation_binding` — A30: in-flight binding, failed switches, atomic
//!   catalogs, removal, revocation.
//! - `custom_stream` — the non-compatible path: a provider with its own stream
//!   adapter, cancel and terminal behaviour, verbatim bodies.
//! - `auth_flow` — device-code interaction that ends in a scoped handle, never
//!   key material.

mod auth_flow;
mod config_path;
mod custom_stream;
mod generation_binding;
mod support;
