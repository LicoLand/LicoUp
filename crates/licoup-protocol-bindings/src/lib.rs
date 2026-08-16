//! Exact Lico Arc Protocol Line input admission.
//!
//! This crate never invents a Protocol Line. Missing artifact version, digest,
//! schema set, hostile corpus, or authority boundary fails closed with
//! `authorization_required` before any persistent write, network I/O, or
//! production cutover.

mod admission;

pub use admission::{
    AUTHORIZATION_REQUIRED, AdmissionDetail, AdmissionInput, AdmissionOutcome,
    ProtocolInputAdmission, ProtocolInputCandidate, admit,
};

#[cfg(test)]
mod tests;
