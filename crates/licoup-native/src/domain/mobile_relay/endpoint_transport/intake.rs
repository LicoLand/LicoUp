//! Bounded duplicate suppression for one ingress lifecycle.
//!
//! Two identities are tracked separately because they answer two different
//! questions: the SDK's replay identity says "this exact protected unit was
//! already consumed", while the peer's logical message id says "this logical
//! message was already admitted, possibly inside a different protected unit".
//! Both windows are bounded and oldest-first, so an ingress cannot grow without
//! limit over a long session.

use std::collections::VecDeque;

use licoup_protocol_bindings::ReplayIdentity;

/// Default number of units and messages remembered per window.
pub const DEFAULT_INTAKE_WINDOW: usize = 1024;

/// Whether one unit or message was seen before.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DedupeOutcome {
    /// Not seen in the current window: the caller may admit it.
    Fresh,
    /// Already seen: merge, do not create a second fact.
    Duplicate,
}

/// The bounded windows one ingress keeps for dedupe.
///
/// Classification and recording are separate on purpose: the ingress records a
/// unit only after the conversation write succeeded, so a failed write does not
/// poison the window against a retry.
#[derive(Debug)]
pub struct IntakeLedger {
    window: usize,
    units: VecDeque<ReplayIdentity>,
    messages: VecDeque<[u8; 16]>,
}

impl IntakeLedger {
    #[must_use]
    pub fn new() -> Self {
        Self::with_window(DEFAULT_INTAKE_WINDOW)
    }

    #[must_use]
    pub fn with_window(window: usize) -> Self {
        Self {
            window: window.max(1),
            units: VecDeque::new(),
            messages: VecDeque::new(),
        }
    }

    /// Classifies one unit and its logical message id against both windows.
    #[must_use]
    pub fn classify(&self, identity: &ReplayIdentity, logical_id: [u8; 16]) -> DedupeOutcome {
        if self.units.iter().any(|seen| seen == identity) {
            return DedupeOutcome::Duplicate;
        }
        if self.messages.iter().any(|seen| *seen == logical_id) {
            return DedupeOutcome::Duplicate;
        }
        DedupeOutcome::Fresh
    }

    /// Remembers one unit that was successfully admitted.
    pub fn record(&mut self, identity: ReplayIdentity, logical_id: [u8; 16]) {
        push_bounded(&mut self.units, identity, self.window);
        push_bounded(&mut self.messages, logical_id, self.window);
    }

    /// The configured window bound.
    #[must_use]
    pub const fn window(&self) -> usize {
        self.window
    }

    /// Number of remembered units.
    #[must_use]
    pub fn units(&self) -> usize {
        self.units.len()
    }

    /// Number of remembered logical messages.
    #[must_use]
    pub fn messages(&self) -> usize {
        self.messages.len()
    }
}

impl Default for IntakeLedger {
    fn default() -> Self {
        Self::new()
    }
}

fn push_bounded<T>(window: &mut VecDeque<T>, value: T, bound: usize) {
    if window.len() == bound {
        window.pop_front();
    }
    window.push_back(value);
}
