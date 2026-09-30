use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use crate::state_machines::security_mlkem_braid;
pub(super) use crate::state_machines::security_mlkem_braid::{Event, State};

use super::{
    authenticator::RatchetedAuthenticator, erasure_decoder::ErasureDecoder,
    erasure_encoder::ErasureEncoder, secret::SecretBytes,
};

#[cfg(test)]
pub(crate) use crate::state_machines::security_mlkem_braid::State as MlKemBraidStateName;

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase", deny_unknown_fields)]
pub(super) enum ProtocolState {
    KeysUnsampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
    },
    KeysSampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ek_vector: Vec<u8>,
        header_encoder: ErasureEncoder,
    },
    HeaderSent {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1_decoder: ErasureDecoder,
        ek_encoder: ErasureEncoder,
    },
    Ct1Received {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1: Vec<u8>,
        ek_encoder: ErasureEncoder,
    },
    EkSentCt1Received {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1: Vec<u8>,
        ct2_decoder: ErasureDecoder,
    },
    NoHeaderReceived {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header_decoder: ErasureDecoder,
    },
    HeaderReceived {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        ek_decoder: ErasureDecoder,
    },
    Ct1Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ct1_encoder: ErasureEncoder,
        ek_decoder: ErasureDecoder,
    },
    EkReceivedCt1Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ek_vector: Vec<u8>,
        ct1_encoder: ErasureEncoder,
    },
    Ct1Acknowledged {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ek_decoder: ErasureDecoder,
    },
    Ct2Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        ct2_encoder: ErasureEncoder,
    },
    Poisoned {
        epoch: u64,
    },
}

impl ProtocolState {
    pub(super) fn epoch(&self) -> u64 {
        match self {
            Self::KeysUnsampled { epoch, .. }
            | Self::KeysSampled { epoch, .. }
            | Self::HeaderSent { epoch, .. }
            | Self::Ct1Received { epoch, .. }
            | Self::EkSentCt1Received { epoch, .. }
            | Self::NoHeaderReceived { epoch, .. }
            | Self::HeaderReceived { epoch, .. }
            | Self::Ct1Sampled { epoch, .. }
            | Self::EkReceivedCt1Sampled { epoch, .. }
            | Self::Ct1Acknowledged { epoch, .. }
            | Self::Ct2Sampled { epoch, .. }
            | Self::Poisoned { epoch } => *epoch,
        }
    }

    pub(super) fn machine_state(&self) -> State {
        match self {
            Self::KeysUnsampled { .. } => State::KeysUnsampled,
            Self::KeysSampled { .. } => State::KeysSampled,
            Self::HeaderSent { .. } => State::HeaderSent,
            Self::Ct1Received { .. } => State::Ct1Received,
            Self::EkSentCt1Received { .. } => State::EkSentCt1Received,
            Self::NoHeaderReceived { .. } => State::NoHeaderReceived,
            Self::HeaderReceived { .. } => State::HeaderReceived,
            Self::Ct1Sampled { .. } => State::Ct1Sampled,
            Self::EkReceivedCt1Sampled { .. } => State::EkReceivedCt1Sampled,
            Self::Ct1Acknowledged { .. } => State::Ct1Acknowledged,
            Self::Ct2Sampled { .. } => State::Ct2Sampled,
            Self::Poisoned { .. } => State::Poisoned,
        }
    }

    #[cfg(test)]
    pub(super) fn name(&self) -> MlKemBraidStateName {
        self.machine_state()
    }
}

pub(super) fn transition_target(from: State, event: Event) -> Result<State> {
    security_mlkem_braid::transition(from, event).with_context(|| {
        format!(
            "ML-KEM Braid transition is not configured: {} + {}",
            from.as_str(),
            event.as_str()
        )
    })
}

pub(super) fn transition_state(
    from: State,
    event: Event,
    build: impl FnOnce(State) -> Result<ProtocolState>,
) -> Result<ProtocolState> {
    let target = transition_target(from, event)?;
    let state = build(target)?;
    ensure!(
        state.machine_state() == target,
        "ML-KEM Braid payload state does not match configured target {}",
        target.as_str()
    );
    Ok(state)
}
