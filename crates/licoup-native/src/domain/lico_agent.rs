// The Lico-owned Agent core — its loop, tools, profiles, events and Gateway
// transport — moved to `licoup-agent-targets` with the Agent declarations it
// runs against. The former path stays reachable through this re-export for the
// `lico-agent` binary and the Lico Agent driver, which still live here.
pub use licoup_agent_targets::domain::lico_agent::*;
