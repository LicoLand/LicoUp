pub(in crate::platform) mod active_control;
mod config;
mod contract;
mod error;
mod io;
mod launch;
mod limits;
mod model;
mod protocol;
mod supervision;
mod transport;

pub(super) use contract::RUNTIME_PROTOCOL;
#[cfg(test)]
pub(super) use model::EffectiveSettings;
pub(super) use model::RunResult;
pub(super) use transport::execute;

#[cfg(test)]
mod tests;
