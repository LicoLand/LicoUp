//! Typed in-process client runtime: generation-safe handles, wake-only
//! callbacks, monotonic stream cursors, and closed Agent private IPC.
//!
//! Hosts bind this surface through `licoup-platform-bridges`, which owns the
//! ABI identity and the generation-index handle arena these types stand on;
//! this module is the composed contract. GUI callers never supply origin, risk,
//! confirmation, or authentication fields.

mod abi;
mod agent_ipc;
mod arena;
mod runtime;
mod spool;
mod stream;

pub use abi::{
    RuntimeCommand, RuntimeError, RuntimeEvent, RuntimeEventClass, SharedBufferId,
    StreamReplayClass,
};
pub use agent_ipc::{AgentIpcError, AgentIpcMessage, AgentPrivateIpc};
pub use arena::{Handle, HandleArena, HandleKind};
pub use runtime::{ClientRuntime, FutureState, SubscriptionState, WakeCallback};
pub use spool::{OutputSpool, SpoolError};
pub use stream::{LatestStateMerge, StreamCursor, StreamItem, StreamQueue};
