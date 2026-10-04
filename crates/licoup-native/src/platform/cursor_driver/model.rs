//! Cursor's launch and wire vocabulary, owned by the Cursor adapter package.
//!
//! The fixed launch arguments, the process poll interval, the session-identity
//! bounds, the effective settings one turn reports, the result shape and the
//! capability surface the installed CLI proves belong to Cursor and live in
//! `licoup-agent-cursor` now. They are re-exported here at their former path so
//! the process half below keeps reading one copy of the vocabulary rather than
//! two.
//!
//! What is still composed by the client is that *process* half: spawning the
//! CLI, driving its PTY, supervising the turn and watching its updates. It moves
//! to the package next, through the agent-execution port the package declares;
//! until it does, the client reads the vocabulary from the package and owns only
//! the process.

pub(in crate::platform) use licoup_agent_cursor::model::{
    CREATE_CHAT_ARGS, CapabilityProbe, DRIVER_ID, EffectiveSettings, PROCESS_POLL_INTERVAL,
    RUNTIME_PROTOCOL, RunResult, TURN_ARGS,
};
