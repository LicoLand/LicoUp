pub(in crate::platform) mod active_control;
pub(in crate::platform) mod config;
mod contract;
mod error;
mod io;
mod launch;
pub(in crate::platform) mod limits;
pub(in crate::platform) mod model;
mod model_catalog;
mod supervision;
mod transport;

pub(super) use contract::RUNTIME_PROTOCOL;
#[cfg(test)]
pub(super) use model::EffectiveSettings;
pub(super) use model::RunResult;
pub(crate) use model_catalog::list_models;
pub(super) use transport::execute;

#[cfg(test)]
mod tests;
