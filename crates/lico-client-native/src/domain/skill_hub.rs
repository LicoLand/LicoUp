//! Local-first skill management facade.
//!
//! Pairing, catalog, discovery, installation, lifecycle, snapshots,
//! transactions, source resolution, and usage accounting live in focused
//! modules. This facade preserves the native command API.

use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{
    ensure_private_dir, read_private_text_bounded, remove_private_state_marker,
    validate_no_symlink_ancestors,
};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

mod auto_update;
mod catalog;
mod delete;
mod discovery;
mod install;
mod package;
mod pairing;
mod snapshot;
mod source;
mod state;
mod transaction;
mod update;
mod usage;

use catalog::{
    get as skill_get_in, list as skill_list_in, pin as skill_pin_in,
    visibility as skill_visibility_in,
};
use install::{skill_install_apply_in, skill_install_plan_in, skill_install_rollback_in};
use package::{
    digest_directory, inspect_skill_dir, preview_skill_package, sanitize_skill_id,
    skill_id_for_install,
};
use pairing::{
    approve as pair_approve_in, list as pair_list_in, request as pair_request_in,
    revoke as pair_revoke_in,
};
use snapshot::{
    capture_skill_install_snapshot, restore_skill_install_snapshot,
    validate_skill_install_boundary, validate_snapshot_id,
};
use source::{resolve_skill_package, skill_source};
use state::*;
#[cfg(test)]
use transaction::{SkillInstallJournal, skill_install_journal_path, write_skill_install_journal};
use transaction::{install_skill_dir, recover_skill_install_journal};

const STATUS_REQUESTED: &str = "requested";
const STATUS_APPROVED: &str = "approved";
const STATUS_REVOKED: &str = "revoked";
const SKILL_INSTALLER_PROTOCOL: &str = "github-skill-installer";
const SKILL_SNAPSHOT_MAX_BYTES: usize = 64 * 1024 * 1024;
const SKILL_INSTALL_JOURNAL_MAX_BYTES: usize = 16 * 1024;
const SKILL_INSTALL_JOURNAL_SCHEMA: &str = "lico.skill-install-journal.v1";

pub fn pair_request(params: &Value) -> Result<Value> {
    pair_request_in(&ClientStateStore::portable()?, params)
}

pub fn pair_approve(params: &Value) -> Result<Value> {
    pair_approve_in(&ClientStateStore::portable()?, params)
}

pub fn pair_revoke(params: &Value) -> Result<Value> {
    pair_revoke_in(&ClientStateStore::portable()?, params)
}

pub fn pair_list(params: &Value) -> Result<Value> {
    pair_list_in(&ClientStateStore::portable()?, params)
}

pub fn skill_list(params: &Value) -> Result<Value> {
    skill_list_in(&ClientStateStore::portable()?, params)
}

pub fn skill_get(params: &Value) -> Result<Value> {
    skill_get_in(&ClientStateStore::portable()?, params)
}

pub fn skill_visibility(params: &Value) -> Result<Value> {
    skill_visibility_in(&ClientStateStore::portable()?, params)
}

pub fn skill_pin(params: &Value) -> Result<Value> {
    skill_pin_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_plan(params: &Value) -> Result<Value> {
    skill_install_plan_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_apply(params: &Value) -> Result<Value> {
    skill_install_apply_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_rollback(params: &Value) -> Result<Value> {
    skill_install_rollback_in(&ClientStateStore::portable()?, params)
}

pub fn observe_agent_skill_invocations(agent_id: &str, result: &Value) -> Result<Value> {
    usage::observe_conversation_result(&ClientStateStore::portable()?, agent_id, result)
}

pub fn skill_usage_report(params: &Value) -> Result<Value> {
    usage::report(&ClientStateStore::portable()?, params)
}

pub fn skill_update_plan(params: &Value) -> Result<Value> {
    update::plan(&ClientStateStore::portable()?, params)
}

pub fn skill_update_apply(params: &Value) -> Result<Value> {
    update::apply(&ClientStateStore::portable()?, params)
}

pub fn skill_delete_plan(params: &Value) -> Result<Value> {
    delete::plan(&ClientStateStore::portable()?, params)
}

pub fn skill_delete_apply(params: &Value) -> Result<Value> {
    delete::apply(&ClientStateStore::portable()?, params)
}

pub fn skill_auto_update_set(params: &Value) -> Result<Value> {
    auto_update::configure(&ClientStateStore::portable()?, params)
}

pub fn skill_auto_update_run(params: &Value) -> Result<Value> {
    auto_update::run_now(&ClientStateStore::portable()?, params)
}

pub fn skill_auto_update_tick() -> Result<Value> {
    auto_update::tick(&ClientStateStore::portable()?)
}

#[cfg(test)]
mod tests;
