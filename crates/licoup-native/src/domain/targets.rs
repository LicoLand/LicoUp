// The Agent inventory moved to `licoup-agent-targets`, which is the single
// authority for which Agents exist on this machine and where they live: the
// target catalog and its discovery, the per-Agent model catalog, the packaged
// scan-path manifest and the scan-path rules. Every former path stays reachable
// through this re-export for the FFI command layer, the driver engines, the
// model facts, the conversation history readers and the Agent binaries, which
// are the consumers that still live in `licoup-native`. Every call into it
// takes the port `domain::target_port` composes.
pub use licoup_agent_targets::domain::targets::*;
