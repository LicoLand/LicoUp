mod allow_list;
mod command_handlers;
mod context;
mod delivery;
mod envelope;
mod mailbox;
mod registration;
mod status;

pub use command_handlers::{
    command_complete, command_create, command_create_secure, command_result,
    command_result_replay_proof, command_result_secure, commands_poll, pc_check_in,
};
pub use status::e2ee_status;

pub(super) use allow_list::allowed_agent_ids;
pub(super) use command_handlers::{
    command_complete_with_config, commands_poll_with_config, pc_check_in_with_context,
};
pub(super) use delivery::local_command_from_relay_delivery;
pub(super) use envelope::{secure_envelope_param, validate_secure_envelope};
pub(super) use mailbox::{canonical_mailbox_token, current_mailbox_rotation_epoch};
pub(super) use registration::register_local_relay_endpoint;

#[cfg(test)]
mod tests;
