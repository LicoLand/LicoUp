//! Cursor's closed failure vocabulary, owned by the Cursor adapter package.
//!
//! One static code, one static message and one recovery hint per classified
//! Cursor failure belong to Cursor and live in `licoup-agent-cursor` now. They
//! are re-exported here at their former path so the driver leaves below keep
//! reporting the same vocabulary the package's parser classifies on the wire,
//! rather than a second copy that can drift from it.

pub(in crate::platform) use licoup_agent_cursor::errors::{CursorFailureKind, ProtocolFailure};
