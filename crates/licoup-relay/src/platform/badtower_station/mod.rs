//! HTTP adapter for an untrusted BadTower transport station.
//!
//! The adapter is carriage only: every value it returns is a station-reported
//! hint, and a hint never becomes delivery, admission, read or acceptance
//! evidence.

mod contract;
mod http_io;
mod transport;
mod wire;

pub use contract::{
    BadTowerDeletionTransportHint, BadTowerDeliveryTransportHint, BadTowerLeaseTransportHint,
    BadTowerStationError, BadTowerStationErrorCategory, BadTowerStationOperation,
};
pub use transport::BadTowerStationTransport;

#[cfg(test)]
mod tests;
