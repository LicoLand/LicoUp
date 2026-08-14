//! Desktop Agent Hub: warehouse-static recipes, argv-only install, one confirmation.

pub(crate) mod argv;
pub(crate) mod capabilities;
pub(crate) mod catalog;
pub(crate) mod confirmation;
pub(crate) mod contract;
pub(crate) mod engine;
pub(crate) mod ownership;
pub(crate) mod recipes;
pub(crate) mod selector;

use anyhow::Result;
use serde_json::Value;

pub use contract::{
    contract_surface, AgentRecipe, InstallChannel, PlatformInstallCapabilities,
    RecipeRegistryDocument, SCHEMA_VERSION,
};
pub use engine::{apply, apply_with, plan, plan_with, HubContext};
pub use recipes::registry;

pub fn catalog(params: &Value) -> Result<Value> {
    catalog::catalog(params)
}

pub fn install_plan(params: &Value) -> Result<Value> {
    engine::plan(params)
}

pub fn install_apply(params: &Value) -> Result<Value> {
    engine::apply(params)
}

pub fn update_plan(params: &Value) -> Result<Value> {
    let mut next = params.clone();
    next["operation"] = Value::from("update");
    engine::plan(&next)
}

pub fn update_apply(params: &Value) -> Result<Value> {
    let mut next = params.clone();
    next["operation"] = Value::from("update");
    engine::apply(&next)
}

pub fn uninstall_plan(params: &Value) -> Result<Value> {
    let mut next = params.clone();
    next["operation"] = Value::from("uninstall");
    engine::plan(&next)
}

pub fn uninstall_apply(params: &Value) -> Result<Value> {
    let mut next = params.clone();
    next["operation"] = Value::from("uninstall");
    engine::apply(&next)
}

#[cfg(test)]
mod tests;
