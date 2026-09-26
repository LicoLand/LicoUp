//! Streams: one bound request, its events, its cancellation and its single
//! terminal state.
//!
//! A stream is created from a [`StreamBinding`] — a request plus the provider
//! instance that was current when the request was admitted — and nothing about
//! that binding changes afterwards. Events arrive in a strictly increasing
//! sequence; text bodies are carried verbatim; the first terminal event closes
//! the stream, and a later frame from the same adapter is never read as a second
//! settlement.
//!
//! Usage is [`Option`] per field. A provider that does not know its token counts
//! reports `None`, and nothing here substitutes a zero: a zero is a claim that
//! nothing happened, and this runtime does not make claims on a provider's
//! behalf.

use licoup_application::ApplicationFailure;
use licoup_extension_contracts::provider::ModelCatalogKey;
use licoup_extension_contracts::usage::CostObservation;
use serde_json::Value;
use std::time::Duration;

use crate::instance::ProviderInstance;
use crate::refusal;

const STAGE: &str = "model-provider/stream";

/// How long a stream read waits before reporting "no event yet".
pub const DEFAULT_STREAM_TIMEOUT: Duration = Duration::from_secs(10);

/// How a stream ended. A terminal state is final.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalState {
    Completed,
    Cancelled,
    Failed { code: String, message: String },
}

/// What a stream reported about usage. Every field is unknown unless reported.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StreamUsage {
    /// Input tokens as reported, or `None` when the provider did not report them.
    pub input_tokens: Option<u64>,
    /// Output tokens as reported, or `None` when not reported.
    pub output_tokens: Option<u64>,
    /// A cost estimate or report. Never a claim about the user's budget, and
    /// never a zero in place of an unknown amount.
    pub cost: Option<CostObservation>,
}

impl StreamUsage {
    /// A usage report where nothing is known.
    pub fn unknown() -> Self {
        Self::default()
    }

    /// Whether every fact in this report is unknown.
    pub fn is_unknown(&self) -> bool {
        self.input_tokens.is_none() && self.output_tokens.is_none() && self.cost.is_none()
    }

    /// Fill fields a later report left unknown from an earlier one.
    ///
    /// This never overwrites a known value with an unknown one and never invents
    /// a value; it only keeps an earlier known fact from being lost when the
    /// terminal frame carries a partial report.
    pub fn merge_missing(&mut self, earlier: &StreamUsage) {
        if self.input_tokens.is_none() {
            self.input_tokens = earlier.input_tokens;
        }
        if self.output_tokens.is_none() {
            self.output_tokens = earlier.output_tokens;
        }
        if self.cost.is_none() {
            self.cost = earlier.cost.clone();
        }
    }

    /// Take every fact a later reading from the same stream knows.
    ///
    /// A provider that updates its token counts while streaming means the later
    /// reading, so it supersedes an earlier one. An unknown field in the later
    /// reading does not erase a known earlier value: it only means this reading
    /// did not restate it.
    pub fn merge_latest(&mut self, later: &StreamUsage) {
        if later.input_tokens.is_some() {
            self.input_tokens = later.input_tokens;
        }
        if later.output_tokens.is_some() {
            self.output_tokens = later.output_tokens;
        }
        if later.cost.is_some() {
            self.cost = later.cost.clone();
        }
    }
}

/// One terminal frame.
#[derive(Clone, Debug, PartialEq)]
pub struct StreamTerminal {
    pub state: TerminalState,
    pub usage: StreamUsage,
}

/// One event on a provider stream.
#[derive(Clone, Debug, PartialEq)]
pub enum StreamEvent {
    /// Verbatim text. The runtime never interprets the body.
    Text { sequence: u64, body: String },
    /// A usage reading. Fields the provider did not report stay `None`.
    Usage { sequence: u64, usage: StreamUsage },
    /// A non-content notice.
    Notice { sequence: u64, body: String },
    /// The stream's one terminal state.
    Terminal(StreamTerminal),
}

impl StreamEvent {
    pub fn sequence(&self) -> Option<u64> {
        match self {
            Self::Text { sequence, .. }
            | Self::Usage { sequence, .. }
            | Self::Notice { sequence, .. } => Some(*sequence),
            Self::Terminal(_) => None,
        }
    }
}

/// One admitted stream request.
#[derive(Clone, Debug, PartialEq)]
pub struct StreamRequest {
    /// The invocation this stream belongs to; the identity a cancel or a
    /// settlement refers to.
    pub invocation_ref: String,
    /// The effect this stream is part of. It is bound with the user principal so
    /// a settlement can be traced to the effect that caused it.
    pub effect_ref: String,
    /// The user principal the request was admitted under.
    pub principal: String,
    /// The catalog key, including the provider generation the request bound to.
    pub key: ModelCatalogKey,
    /// The provider's own input payload, carried verbatim.
    pub input: Value,
}

/// A request plus the immutable provider instance it was admitted against.
#[derive(Clone, Debug)]
pub struct StreamBinding {
    request: StreamRequest,
    instance: ProviderInstance,
}

impl StreamBinding {
    pub(crate) fn new(request: StreamRequest, instance: ProviderInstance) -> Self {
        Self { request, instance }
    }

    pub fn request(&self) -> &StreamRequest {
        &self.request
    }

    pub fn instance(&self) -> &ProviderInstance {
        &self.instance
    }
}

/// Whether a provider declared that it can cancel.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancelSupport {
    Supported,
    Unsupported,
    Unknown,
}

impl CancelSupport {
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Unsupported => "unsupported",
            Self::Unknown => "unknown",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "supported" => Some(Self::Supported),
            "unsupported" => Some(Self::Unsupported),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }
}

/// What a cancel attempt reported. The four outcomes are the contract's own
/// vocabulary: a request made, an acknowledgement, an honest "this stream cannot
/// be cancelled", or "the provider did not say".
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancelOutcome {
    Requested,
    Acknowledged,
    Unsupported,
    Unknown,
}

impl CancelOutcome {
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::Acknowledged => "acknowledged",
            Self::Unsupported => "unsupported",
            Self::Unknown => "unknown",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "requested" => Some(Self::Requested),
            "acknowledged" => Some(Self::Acknowledged),
            "unsupported" => Some(Self::Unsupported),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }
}

/// The result of one cancel call.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CancelReport {
    /// `None` when no cancel was issued because the stream had already reached a
    /// terminal state; the terminal state is not rewritten by a late cancel.
    pub outcome: Option<CancelOutcome>,
    pub after_terminal: bool,
}

/// What an adapter reported when a stream started.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StartAck {
    pub cancel_support: CancelSupport,
}

/// The transport of one stream.
///
/// Implemented by the JSON-RPC provider plugin bridge and by a host transport
/// for a compatible dialect. An adapter reports its own cancellation ability;
/// it is never assumed to support it.
pub trait StreamAdapter: Send {
    /// Submit the bound request and return the provider's acknowledgement. The
    /// acknowledgement is a start fact, not a completion pretence.
    fn start(&mut self, binding: &StreamBinding) -> Result<StartAck, ApplicationFailure>;

    /// The next event, `None` when nothing arrived within the timeout yet.
    fn next_event(&mut self, timeout: Duration) -> Result<Option<StreamEvent>, ApplicationFailure>;

    /// Ask for cancellation and report what the provider said.
    fn cancel(&mut self, invocation_ref: &str) -> CancelOutcome;
}

/// One running stream.
pub struct StreamSession {
    binding: StreamBinding,
    adapter: Box<dyn StreamAdapter>,
    timeout: Duration,
    ack: StartAck,
    state: crate::state_machine::provider_stream_session::State,
    last_sequence: u64,
    cancel: Option<CancelOutcome>,
    usage: StreamUsage,
    terminal: Option<StreamTerminal>,
}

impl std::fmt::Debug for StreamSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("StreamSession")
            .field("binding", &self.binding)
            .field("cancel_support", &self.ack.cancel_support)
            .field("terminal", &self.terminal)
            .finish_non_exhaustive()
    }
}

impl StreamSession {
    pub(crate) fn start(
        binding: StreamBinding,
        mut adapter: Box<dyn StreamAdapter>,
        timeout: Duration,
    ) -> Result<Self, ApplicationFailure> {
        let ack = adapter.start(&binding)?;
        Ok(Self {
            binding,
            adapter,
            timeout,
            ack,
            state: crate::state_machine::provider_stream_session::INITIAL,
            last_sequence: 0,
            cancel: None,
            usage: StreamUsage::unknown(),
            terminal: None,
        })
    }

    pub fn binding(&self) -> &StreamBinding {
        &self.binding
    }

    /// What the provider declared about cancellation when the stream started.
    pub fn cancel_support(&self) -> CancelSupport {
        self.ack.cancel_support
    }

    /// The terminal state, once reached.
    pub fn terminal(&self) -> Option<&StreamTerminal> {
        self.terminal.as_ref()
    }

    pub fn is_terminal(&self) -> bool {
        crate::state_machine::provider_stream_session::terminal(self.state)
    }

    /// Usage accumulated across usage events before the terminal frame.
    pub fn usage(&self) -> &StreamUsage {
        &self.usage
    }

    pub fn next_event(&mut self) -> Result<Option<StreamEvent>, ApplicationFailure> {
        self.next_event_within(self.timeout)
    }

    /// Read the next event, waiting at most `timeout`.
    pub fn next_event_within(
        &mut self,
        timeout: Duration,
    ) -> Result<Option<StreamEvent>, ApplicationFailure> {
        if self.is_terminal() {
            return Ok(None);
        }
        let Some(event) = self.adapter.next_event(timeout)? else {
            return Ok(None);
        };
        match event {
            StreamEvent::Terminal(mut terminal) => {
                terminal.usage.merge_missing(&self.usage);
                self.usage.merge_latest(&terminal.usage);
                self.state = crate::state_machine::provider_stream_session::transition(
                    self.state,
                    crate::state_machine::provider_stream_session::Event::ObserveTerminal,
                )
                .expect("an active stream can observe its terminal frame");
                self.terminal = Some(terminal.clone());
                Ok(Some(StreamEvent::Terminal(terminal)))
            }
            event => {
                let Some(sequence) = event.sequence() else {
                    return Err(
                        refusal::new("provider_stream_event_invalid", STAGE).with_field("sequence")
                    );
                };
                if sequence <= self.last_sequence {
                    return Err(refusal::new("provider_stream_sequence_regressed", STAGE)
                        .with_field("sequence")
                        .with_presentation_arg("lastSequence", &self.last_sequence.to_string())
                        .with_presentation_arg("sequence", &sequence.to_string()));
                }
                self.last_sequence = sequence;
                if let StreamEvent::Usage { usage, .. } = &event {
                    self.usage.merge_latest(usage);
                }
                Ok(Some(event))
            }
        }
    }

    /// Ask the provider to cancel.
    ///
    /// Idempotent: a second cancel reports the first outcome instead of sending
    /// another request. After a terminal state no cancel is issued — the terminal
    /// state stands.
    pub fn cancel(&mut self) -> CancelReport {
        if crate::state_machine::provider_stream_session::terminal(self.state) {
            return CancelReport {
                outcome: None,
                after_terminal: true,
            };
        }
        if let Some(outcome) = self.cancel {
            return CancelReport {
                outcome: Some(outcome),
                after_terminal: false,
            };
        }
        let outcome = self.adapter.cancel(&self.binding.request.invocation_ref);
        self.cancel = Some(outcome);
        CancelReport {
            outcome: Some(outcome),
            after_terminal: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct ScriptedAdapter {
        events: Vec<StreamEvent>,
        position: usize,
    }

    impl StreamAdapter for ScriptedAdapter {
        fn start(&mut self, _binding: &StreamBinding) -> Result<StartAck, ApplicationFailure> {
            Ok(StartAck {
                cancel_support: CancelSupport::Unsupported,
            })
        }

        fn next_event(
            &mut self,
            _timeout: Duration,
        ) -> Result<Option<StreamEvent>, ApplicationFailure> {
            let event = self.events.get(self.position).cloned();
            self.position += 1;
            Ok(event)
        }

        fn cancel(&mut self, _invocation_ref: &str) -> CancelOutcome {
            CancelOutcome::Unsupported
        }
    }

    #[test]
    fn usage_merging_never_turns_an_unknown_into_a_zero() {
        let mut terminal = StreamUsage {
            input_tokens: None,
            output_tokens: Some(4),
            cost: None,
        };
        terminal.merge_missing(&StreamUsage {
            input_tokens: Some(12),
            output_tokens: None,
            cost: None,
        });
        assert_eq!(terminal.input_tokens, Some(12));
        assert_eq!(
            terminal.output_tokens,
            Some(4),
            "a known value is not erased"
        );
        assert_eq!(terminal.cost, None, "an unknown cost stays unknown");
    }

    #[test]
    fn a_later_usage_reading_supersedes_an_earlier_one_without_erasing_known_fields() {
        let mut accumulated = StreamUsage {
            input_tokens: Some(5),
            output_tokens: Some(1),
            cost: None,
        };
        accumulated.merge_latest(&StreamUsage {
            input_tokens: Some(12),
            output_tokens: None,
            cost: None,
        });
        assert_eq!(accumulated.input_tokens, Some(12), "the later count wins");
        assert_eq!(
            accumulated.output_tokens,
            Some(1),
            "a field the later reading omitted is not erased"
        );
    }

    #[test]
    fn a_regressed_sequence_is_a_protocol_failure() {
        let instance = test_instance();
        let binding = StreamBinding::new(
            StreamRequest {
                invocation_ref: "stream-1".to_owned(),
                effect_ref: "effect-1".to_owned(),
                principal: "user:synthetic".to_owned(),
                key: ModelCatalogKey {
                    provider_id: "synthetic.example.a".to_owned(),
                    provider_generation: 1,
                    vendor_model_id: "mini".to_owned(),
                },
                input: Value::Null,
            },
            instance,
        );
        let adapter = ScriptedAdapter {
            events: vec![
                StreamEvent::Text {
                    sequence: 2,
                    body: "second".to_owned(),
                },
                StreamEvent::Text {
                    sequence: 1,
                    body: "first".to_owned(),
                },
            ],
            position: 0,
        };
        let mut session =
            StreamSession::start(binding, Box::new(adapter), DEFAULT_STREAM_TIMEOUT).unwrap();
        assert!(session.next_event().unwrap().is_some());
        assert_eq!(
            session.next_event().unwrap_err().code,
            "provider_stream_sequence_regressed"
        );
    }

    #[test]
    fn a_late_cancel_does_not_rewrite_a_terminal_state() {
        let instance = test_instance();
        let binding = StreamBinding::new(
            StreamRequest {
                invocation_ref: "stream-2".to_owned(),
                effect_ref: "effect-2".to_owned(),
                principal: "user:synthetic".to_owned(),
                key: ModelCatalogKey {
                    provider_id: "synthetic.example.a".to_owned(),
                    provider_generation: 1,
                    vendor_model_id: "mini".to_owned(),
                },
                input: Value::Null,
            },
            instance,
        );
        let adapter = ScriptedAdapter {
            events: vec![StreamEvent::Terminal(StreamTerminal {
                state: TerminalState::Completed,
                usage: StreamUsage::unknown(),
            })],
            position: 0,
        };
        let mut session =
            StreamSession::start(binding, Box::new(adapter), DEFAULT_STREAM_TIMEOUT).unwrap();
        assert!(matches!(
            session.next_event().unwrap(),
            Some(StreamEvent::Terminal(_))
        ));
        let report = session.cancel();
        assert!(report.after_terminal);
        assert_eq!(report.outcome, None);
        assert_eq!(
            session.terminal().unwrap().state,
            TerminalState::Completed,
            "the terminal state stands"
        );
        assert!(session.next_event().unwrap().is_none());
    }

    fn test_instance() -> ProviderInstance {
        let config = licoup_extension_contracts::provider::ProviderConfig {
            schema: licoup_extension_contracts::wire::PROVIDER.to_owned(),
            id: "synthetic.example.a".to_owned(),
            display_name: "Synthetic".to_owned(),
            base_url: "http://127.0.0.1:8098/v1".to_owned(),
            api_dialect: "openai-chat-compatible".to_owned(),
            credential_ref: None,
            config_revision: 1,
            catalog_source: licoup_extension_contracts::provider::CatalogSource::Static,
            models: Vec::new(),
            compat: std::collections::BTreeMap::new(),
            stream_adapter: None,
        };
        ProviderInstance::new(
            std::sync::Arc::new(crate::registry::RegisteredProvider::for_tests(
                config,
                1,
                crate::registry::ProviderOrigin::UserConfigured,
            )),
            crate::credentials::CredentialResolution::NotConfigured,
        )
    }
}
