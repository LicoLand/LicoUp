use super::binaries::find_binary;
use super::parameters::{param_bool, param_paths, param_string, param_u64};
use super::platform_paths::default_app_data_dir;
use directories::UserDirs;
use rusqlite::{Connection, OpenFlags};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

mod antigravity;
mod builtin;
mod config;
mod cursor;
mod history;
mod kilo;
mod merge;
mod normalization;
mod pi;
mod provider;
mod reasoning;

use antigravity::{
    collect_antigravity_available_models_param, collect_antigravity_cli_model_catalog,
    remove_unsupported_antigravity_reasoning_efforts,
};
use builtin::apply_builtin_model_catalog_overlay;
use config::{
    collect_model_catalog_from_config_path, collect_model_catalog_from_model_collection_path,
    extra_model_collection_paths, extra_model_config_paths, home_dir_for_model_catalog,
};
use cursor::collect_cursor_cli_model_catalog;
use history::collect_model_catalog_from_history;
use kilo::collect_kilo_code_model_catalog;
use merge::{
    add_model_catalog_entry, add_model_catalog_entry_with_provider, build_model_catalog,
    collapse_kimi_code_qualified_duplicates, merge_model_catalog_value_into,
    model_catalog_fixture_for_target,
};
use normalization::{
    canonical_model_display_name, collect_model_catalog_entries_from_collection_value,
    collect_model_catalog_from_value, default_model_name_from_config_document,
    is_reasoning_option_key, model_display_name_from_object, model_display_name_from_value,
    model_name_from_value, normalize_model_catalog_key, prefer_model_display_name,
    sanitize_model_name, sanitize_option_name,
};
use pi::collect_pi_cli_model_catalog;
use provider::{
    provider_id_from_model_object, provider_id_from_model_value, provider_label_from_provider_id,
    provider_name_from_model_object, provider_name_from_model_value,
};
use reasoning::{option_names_from_value, reasoning_efforts_from_value};

#[derive(Clone, Debug)]
pub(super) struct ModelCatalogEntry {
    pub(super) name: String,
    pub(super) display_name: String,
    pub(super) provider: Option<String>,
    pub(super) provider_id: Option<String>,
    pub(super) provider_inferred: bool,
    pub(super) sources: BTreeSet<String>,
    /// Insertion-ordered and deduplicated so the built-in table controls the
    /// picker order for known models.
    pub(super) reasoning_efforts: Vec<String>,
}

impl ModelCatalogEntry {
    pub(super) fn extend_reasoning_efforts(&mut self, efforts: impl IntoIterator<Item = String>) {
        for effort in efforts {
            if !effort.trim().is_empty() && !self.reasoning_efforts.contains(&effort) {
                self.reasoning_efforts.push(effort);
            }
        }
    }
}

pub(super) fn model_catalog_for_target(
    target: &str,
    config_path: Option<&Path>,
    params: &Value,
) -> Value {
    if target == "codex"
        && model_catalog_fixture_for_target(target, params).is_none()
        && (!cfg!(test) || param_bool(params, "enableAgentCliModelLookup").unwrap_or(false))
        && let Some(binary) = find_binary(&["codex"])
        && let Ok(catalog) = crate::platform::codex_app_server_model_catalog(&binary)
    {
        return catalog;
    }
    let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
    let mut global_efforts = BTreeSet::<String>::new();
    let mut sources = BTreeSet::<String>::new();
    let mut diagnostics = Vec::<Value>::new();
    let mut default_model = None::<String>;
    let mut authoritative_native_catalog = false;
    if let Some(fixture) = model_catalog_fixture_for_target(target, params) {
        default_model = fixture
            .get("defaultModel")
            .map(model_name_from_value)
            .filter(|name| !name.trim().is_empty());
        merge_model_catalog_value_into(
            &fixture,
            "fixture",
            &mut entries,
            &mut sources,
            &mut diagnostics,
        );
    }

    if let Some(path) = config_path {
        sources.insert("config".to_string());
        let configured_default = collect_model_catalog_from_config_path(
            path,
            "config",
            &mut entries,
            &mut global_efforts,
            &mut diagnostics,
        );
        if default_model.is_none() {
            default_model = configured_default;
        }
    }
    for path in extra_model_config_paths(target, params) {
        sources.insert("local-settings".to_string());
        let configured_default = collect_model_catalog_from_config_path(
            &path,
            "local-settings",
            &mut entries,
            &mut global_efforts,
            &mut diagnostics,
        );
        if default_model.is_none() {
            default_model = configured_default;
        }
    }
    for path in extra_model_collection_paths(target, params) {
        sources.insert("model-cache".to_string());
        collect_model_catalog_from_model_collection_path(
            &path,
            "model-cache",
            &mut entries,
            &mut diagnostics,
        );
    }
    if target == "kilo-code" {
        sources.insert("kilo-state".to_string());
        collect_kilo_code_model_catalog(params, &mut entries, &mut diagnostics);
    }

    if target == "antigravity" {
        collect_antigravity_available_models_param(params, &mut entries, &mut diagnostics);
        authoritative_native_catalog =
            collect_antigravity_cli_model_catalog(params, &mut entries, &mut diagnostics);
        if authoritative_native_catalog {
            sources.clear();
            sources.insert("antigravity-cli".to_string());
        }
    }

    if target == "cursor" {
        let result = collect_cursor_cli_model_catalog(params, &mut entries, &mut diagnostics);
        authoritative_native_catalog = result.authoritative;
        if authoritative_native_catalog {
            default_model = result.default_model;
            sources.clear();
            sources.insert("cursor-cli".to_string());
        }
    }

    if target == "pi" {
        sources.insert("pi-cli:list-models".to_string());
        collect_pi_cli_model_catalog(params, &mut entries, &mut diagnostics);
    }

    if !authoritative_native_catalog
        && param_bool(params, "includeHistoryModelCatalog") == Some(true)
    {
        sources.insert("history".to_string());
        collect_model_catalog_from_history(target, params, &mut entries, &mut diagnostics);
    }

    if !global_efforts.is_empty() {
        for entry in entries.values_mut() {
            entry.extend_reasoning_efforts(global_efforts.iter().cloned());
        }
    }

    if authoritative_native_catalog
        && default_model.as_ref().is_some_and(|configured| {
            !entries
                .values()
                .any(|entry| entry.name.eq_ignore_ascii_case(configured))
        })
    {
        default_model = None;
    }

    apply_builtin_model_catalog_overlay(target, &mut entries, &mut sources);
    if target == "kimi-code" {
        collapse_kimi_code_qualified_duplicates(&mut entries);
        if let Some(configured_default) = default_model.as_mut()
            && let Some((provider, model)) = configured_default.split_once('/')
            && provider.eq_ignore_ascii_case("kimi-code")
            && entries
                .values()
                .any(|entry| entry.name.eq_ignore_ascii_case(model))
        {
            *configured_default = model.to_string();
        }
    }
    if target == "antigravity" {
        remove_unsupported_antigravity_reasoning_efforts(&mut entries);
    }

    build_model_catalog(entries, sources, diagnostics, default_model)
}

pub(super) fn empty_model_catalog(status: &str, source: &str) -> Value {
    json!({
        "schemaVersion": 1,
        "status": status,
        "sources": [source],
        "models": [],
        "diagnostics": [],
    })
}

#[cfg(test)]
mod tests;
