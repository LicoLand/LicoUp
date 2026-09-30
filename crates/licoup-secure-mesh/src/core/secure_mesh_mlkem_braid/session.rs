use std::mem;

use anyhow::{Result, bail, ensure};
use rand_core::{CryptoRng, OsRng, RngCore};

#[cfg(test)]
use super::protocol_state::MlKemBraidStateName;
use super::{
    MlKemBraidReceive, MlKemBraidSend,
    authenticator::RatchetedAuthenticator,
    constants::{INITIAL_EPOCH, ML_KEM_BRAID_HEADER_BYTES, ML_KEM_BRAID_MAC_BYTES},
    erasure_decoder::ErasureDecoder,
    protocol_state::{Event, ProtocolState, State, transition_state},
    receive_transition::receive_state,
    send_transition::send_state,
    wire::MlKemBraidMessage,
};
use crate::state_machines::security_mlkem_braid;

/// Persistable client-only ML-KEM Braid session. The persisted bytes contain
/// plaintext secret state and belong exclusively in the platform secret store.
pub(crate) struct MlKemBraidSession {
    pub(super) state: ProtocolState,
}

impl MlKemBraidSession {
    pub fn new_initiator(shared_secret: &[u8; 32]) -> Result<Self> {
        let state = match security_mlkem_braid::INITIAL {
            State::KeysUnsampled => ProtocolState::KeysUnsampled {
                epoch: INITIAL_EPOCH,
                auth: RatchetedAuthenticator::initialize(INITIAL_EPOCH, shared_secret)?,
            },
            target => bail!(
                "ML-KEM Braid initiator cannot construct configured initial state {}",
                target.as_str()
            ),
        };
        Ok(Self { state })
    }

    pub fn new_responder(shared_secret: &[u8; 32]) -> Result<Self> {
        let state = transition_state(
            security_mlkem_braid::INITIAL,
            Event::InitializeResponder,
            |target| match target {
                State::NoHeaderReceived => Ok(ProtocolState::NoHeaderReceived {
                    epoch: INITIAL_EPOCH,
                    auth: RatchetedAuthenticator::initialize(INITIAL_EPOCH, shared_secret)?,
                    header_decoder: ErasureDecoder::new(
                        ML_KEM_BRAID_HEADER_BYTES + ML_KEM_BRAID_MAC_BYTES,
                    )?,
                }),
                target => bail!(
                    "ML-KEM Braid responder cannot construct configured initial target {}",
                    target.as_str()
                ),
            },
        )?;
        Ok(Self { state })
    }

    #[cfg(test)]
    pub fn state_name(&self) -> MlKemBraidStateName {
        self.state.name()
    }

    pub fn epoch(&self) -> u64 {
        self.state.epoch()
    }

    pub fn is_poisoned(&self) -> bool {
        matches!(self.state, ProtocolState::Poisoned { .. })
    }

    pub fn destroy(&mut self) {
        let epoch = self.state.epoch();
        if self.state.machine_state() != State::Poisoned {
            self.state = poisoned_state(self.state.machine_state(), epoch)
                .expect("every live ML-KEM Braid state can be destroyed");
        }
    }

    pub fn try_clone(&self) -> Self {
        Self {
            state: self.state.clone(),
        }
    }

    pub fn send(&mut self) -> Result<MlKemBraidSend> {
        self.send_with_rng(&mut OsRng)
    }

    pub fn send_with_rng<R>(&mut self, rng: &mut R) -> Result<MlKemBraidSend>
    where
        R: RngCore + CryptoRng,
    {
        let epoch = self.state.epoch();
        ensure!(
            !matches!(self.state, ProtocolState::Poisoned { .. }),
            "ML-KEM Braid session is poisoned"
        );
        let poisoned = poisoned_state(self.state.machine_state(), epoch)?;
        let state = mem::replace(&mut self.state, poisoned);
        match send_state(state, rng) {
            Ok((state, output)) => {
                self.state = state;
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }

    pub fn receive(&mut self, message: &MlKemBraidMessage) -> Result<MlKemBraidReceive> {
        let epoch = self.state.epoch();
        if let Err(error) = message.validate() {
            if self.state.machine_state() != State::Poisoned {
                self.state = poisoned_state(self.state.machine_state(), epoch)
                    .expect("every live ML-KEM Braid state can reject invalid input");
            }
            return Err(error);
        }
        ensure!(
            !matches!(self.state, ProtocolState::Poisoned { .. }),
            "ML-KEM Braid session is poisoned"
        );
        let poisoned = poisoned_state(self.state.machine_state(), epoch)?;
        let state = mem::replace(&mut self.state, poisoned);
        match receive_state(state, message) {
            Ok((state, output)) => {
                self.state = state;
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }
}

fn poisoned_state(from: State, epoch: u64) -> Result<ProtocolState> {
    transition_state(from, Event::Fail, |target| match target {
        State::Poisoned => Ok(ProtocolState::Poisoned { epoch }),
        target => bail!(
            "ML-KEM Braid failure payload cannot construct configured target {}",
            target.as_str()
        ),
    })
}
