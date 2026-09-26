//! Configuration-backed lifecycle validation for durable continuity effects.

use super::ContinuityEffectStatus;

pub(super) fn permits(
    current: Option<ContinuityEffectStatus>,
    next: ContinuityEffectStatus,
) -> bool {
    use crate::state_machine::conversation_continuity_effect as machine;
    let current = current.unwrap_or(machine::INITIAL);
    current == next || machine::permits(current, next)
}
