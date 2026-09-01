#![deny(clippy::wildcard_enum_match_arm)]

use core::fmt;

/// Durable lifecycle of one Membership-scoped turn.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum TurnState {
    Pending,
    Claimed,
    Running,
    WaitingForHuman,
    Succeeded,
    Failed,
    Interrupted,
    Cancelled,
}

impl TurnState {
    /// Applies one domain event. Invalid non-terminal transitions are rejected;
    /// terminal states absorb every later event.
    pub const fn transition(self, event: TurnEvent) -> Result<Self, TransitionError> {
        match self {
            Self::Pending => match event {
                TurnEvent::Claim => Ok(Self::Claimed),
                TurnEvent::Start => Ok(Self::Running),
                TurnEvent::WaitForHuman | TurnEvent::Resume | TurnEvent::Succeed => {
                    Err(TransitionError::Turn { state: self, event })
                }
                TurnEvent::Fail => Ok(Self::Failed),
                TurnEvent::Interrupt => Ok(Self::Interrupted),
                TurnEvent::Cancel => Ok(Self::Cancelled),
            },
            Self::Claimed => match event {
                TurnEvent::Claim
                | TurnEvent::WaitForHuman
                | TurnEvent::Resume
                | TurnEvent::Succeed => Err(TransitionError::Turn { state: self, event }),
                TurnEvent::Start => Ok(Self::Running),
                TurnEvent::Fail => Ok(Self::Failed),
                TurnEvent::Interrupt => Ok(Self::Interrupted),
                TurnEvent::Cancel => Ok(Self::Cancelled),
            },
            Self::Running => match event {
                TurnEvent::Claim | TurnEvent::Start | TurnEvent::Resume => {
                    Err(TransitionError::Turn { state: self, event })
                }
                TurnEvent::WaitForHuman => Ok(Self::WaitingForHuman),
                TurnEvent::Succeed => Ok(Self::Succeeded),
                TurnEvent::Fail => Ok(Self::Failed),
                TurnEvent::Interrupt => Ok(Self::Interrupted),
                TurnEvent::Cancel => Ok(Self::Cancelled),
            },
            Self::WaitingForHuman => match event {
                TurnEvent::Claim
                | TurnEvent::Start
                | TurnEvent::WaitForHuman
                | TurnEvent::Succeed => Err(TransitionError::Turn { state: self, event }),
                TurnEvent::Resume => Ok(Self::Running),
                TurnEvent::Fail => Ok(Self::Failed),
                TurnEvent::Interrupt => Ok(Self::Interrupted),
                TurnEvent::Cancel => Ok(Self::Cancelled),
            },
            Self::Succeeded => match event {
                TurnEvent::Claim
                | TurnEvent::Start
                | TurnEvent::WaitForHuman
                | TurnEvent::Resume
                | TurnEvent::Succeed
                | TurnEvent::Fail
                | TurnEvent::Interrupt
                | TurnEvent::Cancel => Ok(Self::Succeeded),
            },
            Self::Failed => match event {
                TurnEvent::Claim
                | TurnEvent::Start
                | TurnEvent::WaitForHuman
                | TurnEvent::Resume
                | TurnEvent::Succeed
                | TurnEvent::Fail
                | TurnEvent::Interrupt
                | TurnEvent::Cancel => Ok(Self::Failed),
            },
            Self::Interrupted => match event {
                TurnEvent::Claim
                | TurnEvent::Start
                | TurnEvent::WaitForHuman
                | TurnEvent::Resume
                | TurnEvent::Succeed
                | TurnEvent::Fail
                | TurnEvent::Interrupt
                | TurnEvent::Cancel => Ok(Self::Interrupted),
            },
            Self::Cancelled => match event {
                TurnEvent::Claim
                | TurnEvent::Start
                | TurnEvent::WaitForHuman
                | TurnEvent::Resume
                | TurnEvent::Succeed
                | TurnEvent::Fail
                | TurnEvent::Interrupt
                | TurnEvent::Cancel => Ok(Self::Cancelled),
            },
        }
    }

    pub const fn is_terminal(self) -> bool {
        match self {
            Self::Pending | Self::Claimed | Self::Running | Self::WaitingForHuman => false,
            Self::Succeeded | Self::Failed | Self::Interrupted | Self::Cancelled => true,
        }
    }
}

/// Domain events which may advance a turn.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum TurnEvent {
    Claim,
    Start,
    WaitForHuman,
    Resume,
    Succeed,
    Fail,
    Interrupt,
    Cancel,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TurnTransition {
    pub from: TurnState,
    pub event: TurnEvent,
    pub to: TurnState,
}

/// The complete accepted turn transition relation, including terminal
/// self-loops. Any non-terminal pair absent from this table is invalid.
pub const TURN_TRANSITIONS: &[TurnTransition] = &[
    turn(TurnState::Pending, TurnEvent::Claim, TurnState::Claimed),
    turn(TurnState::Pending, TurnEvent::Start, TurnState::Running),
    turn(TurnState::Pending, TurnEvent::Fail, TurnState::Failed),
    turn(
        TurnState::Pending,
        TurnEvent::Interrupt,
        TurnState::Interrupted,
    ),
    turn(TurnState::Pending, TurnEvent::Cancel, TurnState::Cancelled),
    turn(TurnState::Claimed, TurnEvent::Start, TurnState::Running),
    turn(TurnState::Claimed, TurnEvent::Fail, TurnState::Failed),
    turn(
        TurnState::Claimed,
        TurnEvent::Interrupt,
        TurnState::Interrupted,
    ),
    turn(TurnState::Claimed, TurnEvent::Cancel, TurnState::Cancelled),
    turn(
        TurnState::Running,
        TurnEvent::WaitForHuman,
        TurnState::WaitingForHuman,
    ),
    turn(TurnState::Running, TurnEvent::Succeed, TurnState::Succeeded),
    turn(TurnState::Running, TurnEvent::Fail, TurnState::Failed),
    turn(
        TurnState::Running,
        TurnEvent::Interrupt,
        TurnState::Interrupted,
    ),
    turn(TurnState::Running, TurnEvent::Cancel, TurnState::Cancelled),
    turn(
        TurnState::WaitingForHuman,
        TurnEvent::Resume,
        TurnState::Running,
    ),
    turn(
        TurnState::WaitingForHuman,
        TurnEvent::Fail,
        TurnState::Failed,
    ),
    turn(
        TurnState::WaitingForHuman,
        TurnEvent::Interrupt,
        TurnState::Interrupted,
    ),
    turn(
        TurnState::WaitingForHuman,
        TurnEvent::Cancel,
        TurnState::Cancelled,
    ),
    terminal_turns(TurnState::Succeeded)[0],
    terminal_turns(TurnState::Succeeded)[1],
    terminal_turns(TurnState::Succeeded)[2],
    terminal_turns(TurnState::Succeeded)[3],
    terminal_turns(TurnState::Succeeded)[4],
    terminal_turns(TurnState::Succeeded)[5],
    terminal_turns(TurnState::Succeeded)[6],
    terminal_turns(TurnState::Succeeded)[7],
    terminal_turns(TurnState::Failed)[0],
    terminal_turns(TurnState::Failed)[1],
    terminal_turns(TurnState::Failed)[2],
    terminal_turns(TurnState::Failed)[3],
    terminal_turns(TurnState::Failed)[4],
    terminal_turns(TurnState::Failed)[5],
    terminal_turns(TurnState::Failed)[6],
    terminal_turns(TurnState::Failed)[7],
    terminal_turns(TurnState::Interrupted)[0],
    terminal_turns(TurnState::Interrupted)[1],
    terminal_turns(TurnState::Interrupted)[2],
    terminal_turns(TurnState::Interrupted)[3],
    terminal_turns(TurnState::Interrupted)[4],
    terminal_turns(TurnState::Interrupted)[5],
    terminal_turns(TurnState::Interrupted)[6],
    terminal_turns(TurnState::Interrupted)[7],
    terminal_turns(TurnState::Cancelled)[0],
    terminal_turns(TurnState::Cancelled)[1],
    terminal_turns(TurnState::Cancelled)[2],
    terminal_turns(TurnState::Cancelled)[3],
    terminal_turns(TurnState::Cancelled)[4],
    terminal_turns(TurnState::Cancelled)[5],
    terminal_turns(TurnState::Cancelled)[6],
    terminal_turns(TurnState::Cancelled)[7],
];

const fn turn(from: TurnState, event: TurnEvent, to: TurnState) -> TurnTransition {
    TurnTransition { from, event, to }
}

const fn terminal_turns(state: TurnState) -> [TurnTransition; 8] {
    [
        turn(state, TurnEvent::Claim, state),
        turn(state, TurnEvent::Start, state),
        turn(state, TurnEvent::WaitForHuman, state),
        turn(state, TurnEvent::Resume, state),
        turn(state, TurnEvent::Succeed, state),
        turn(state, TurnEvent::Fail, state),
        turn(state, TurnEvent::Interrupt, state),
        turn(state, TurnEvent::Cancel, state),
    ]
}

/// Delivery lifecycle of an accepted outbound send.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum SendState {
    Sending,
    Delivered,
    Failed,
}

impl SendState {
    pub const fn transition(self, event: SendEvent) -> Result<Self, TransitionError> {
        match self {
            Self::Sending => match event {
                SendEvent::Deliver => Ok(Self::Delivered),
                SendEvent::Fail => Ok(Self::Failed),
            },
            Self::Delivered => match event {
                SendEvent::Deliver | SendEvent::Fail => Ok(Self::Delivered),
            },
            Self::Failed => match event {
                SendEvent::Deliver | SendEvent::Fail => Ok(Self::Failed),
            },
        }
    }

    pub const fn is_terminal(self) -> bool {
        match self {
            Self::Sending => false,
            Self::Delivered | Self::Failed => true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum SendEvent {
    Deliver,
    Fail,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SendTransition {
    pub from: SendState,
    pub event: SendEvent,
    pub to: SendState,
}

pub const SEND_TRANSITIONS: &[SendTransition] = &[
    send(SendState::Sending, SendEvent::Deliver, SendState::Delivered),
    send(SendState::Sending, SendEvent::Fail, SendState::Failed),
    send(
        SendState::Delivered,
        SendEvent::Deliver,
        SendState::Delivered,
    ),
    send(SendState::Delivered, SendEvent::Fail, SendState::Delivered),
    send(SendState::Failed, SendEvent::Deliver, SendState::Failed),
    send(SendState::Failed, SendEvent::Fail, SendState::Failed),
];

const fn send(from: SendState, event: SendEvent, to: SendState) -> SendTransition {
    SendTransition { from, event, to }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum TransitionError {
    Turn { state: TurnState, event: TurnEvent },
    Send { state: SendState, event: SendEvent },
}

impl fmt::Display for TransitionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Turn { state, event } => {
                write!(formatter, "invalid turn transition: {state:?} + {event:?}")
            }
            Self::Send { state, event } => {
                write!(formatter, "invalid send transition: {state:?} + {event:?}")
            }
        }
    }
}

impl std::error::Error for TransitionError {}

pub const ALL_TURN_STATES: &[TurnState] = &[
    TurnState::Pending,
    TurnState::Claimed,
    TurnState::Running,
    TurnState::WaitingForHuman,
    TurnState::Succeeded,
    TurnState::Failed,
    TurnState::Interrupted,
    TurnState::Cancelled,
];

pub const ALL_TURN_EVENTS: &[TurnEvent] = &[
    TurnEvent::Claim,
    TurnEvent::Start,
    TurnEvent::WaitForHuman,
    TurnEvent::Resume,
    TurnEvent::Succeed,
    TurnEvent::Fail,
    TurnEvent::Interrupt,
    TurnEvent::Cancel,
];

pub const ALL_SEND_STATES: &[SendState] =
    &[SendState::Sending, SendState::Delivered, SendState::Failed];

pub const ALL_SEND_EVENTS: &[SendEvent] = &[SendEvent::Deliver, SendEvent::Fail];
