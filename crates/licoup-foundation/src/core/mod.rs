//! Bounded work-queue, archive, authorized-record and Agent Client Protocol wire primitives.
//!
//! These are mechanisms and names, not policy: the queue, the archive container
//! formats, the user-present versioned record authority, the ACP v1 framing
//! vocabulary, the secure-mesh protocol identity names, the agent runtime
//! protocol names and the model display-name projection are the same for every
//! caller.

pub mod acp;
// Linux currently exposes the portable contract without a native authorized-record backend.
#[cfg_attr(target_os = "linux", allow(dead_code))]
pub mod authorized_secure_record;
pub mod full_data_root_archive;
pub mod model_naming;
pub mod safe_archive;
pub mod secure_mesh;
pub mod task_queue;
