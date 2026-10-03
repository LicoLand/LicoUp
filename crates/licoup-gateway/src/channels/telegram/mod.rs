//! Telegram channel runtime: Bot API transport, update loop and lane bridge.
//!
//! Channel state (bindings, bot credentials, control commands) lives in
//! `licoup_gateway_core::channels::telegram` and is shared with the managing
//! client.

pub mod bridge;
pub mod inbound;
pub mod runtime;
pub mod transport;

pub use runtime::{RuntimeConfig, run_channel_loop};
pub use transport::{
    BotIdentity, BotTransport, LiveBotTransport, MockBotTransport, TelegramApiError, Update,
    bot_commands,
};
