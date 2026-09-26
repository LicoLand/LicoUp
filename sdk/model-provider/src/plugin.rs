//! The JSON-RPC bridge to a provider extension process.
//!
//! A provider package is a separate program ([`ProviderPlugin`]) speaking one
//! line-delimited JSON-RPC 2.0 frame per line, exactly like every other
//! extension profile: the handshake is `extension.initialize` / `extension.ready`
//! / `extension.shutdown`, the profile is `model-provider`, and the frames are
//! bounded by the published default.
//!
//! Stream notifications ride the `modelProvider.stream` method with
//! `{invocationRef, sequence, kind, …}` params — the same field style as the
//! Agent profile's events, because the published model-provider catalog has no
//! separate event method. A provider that is not a compatible dialect supplies
//! its own adapter this way instead of pretending to be a compatible API.
//!
//! Nothing on this bridge invents a fact: a missing token count stays `None`, a
//! cost amount must be exact decimal text, and a plugin that never answered a
//! cancel is reported as `unknown` rather than as cancelled.

use licoup_application::{ApplicationFailure, ContractRange, RecoveryAction};
use licoup_extension_contracts::profile::{
    DeclaredMethods, ExtensionProfile, METHOD_INITIALIZE, METHOD_PROVIDER_CANCEL,
    METHOD_PROVIDER_DESCRIBE, METHOD_PROVIDER_MODELS, METHOD_PROVIDER_RECONCILE,
    METHOD_PROVIDER_STREAM, METHOD_READY, PROFILE_MAJOR, ProfileDeclaration, ProfileStatus,
};
use licoup_extension_contracts::provider::ProviderModel;
use licoup_extension_contracts::transport::{DEFAULT_MAX_FRAME_BYTES, Framing, JSONRPC_VERSION};
use licoup_extension_contracts::usage::{CostObservation, Quality};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::refusal;
use crate::stream::{
    CancelOutcome, CancelSupport, StartAck, StreamAdapter, StreamBinding, StreamEvent,
    StreamTerminal, StreamUsage, TerminalState,
};

const STAGE: &str = "model-provider/plugin";

/// How long a bridge waits for a request response or a stream frame.
pub const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

enum Frame {
    Value(Value),
    Io(String),
}

/// What a provider declared at the handshake.
#[derive(Clone, Debug)]
pub struct PluginDescription {
    pub protocol_major: u32,
    pub declared_profiles: Vec<ProfileDeclaration>,
    pub methods: DeclaredMethods,
}

impl PluginDescription {
    pub fn implements(&self, method: &str) -> bool {
        self.methods.implements(method)
    }

    /// Whether this process declared the `model-provider` profile in a version
    /// this host serves and with its required methods.
    pub fn model_provider_available(&self) -> bool {
        self.declared_profiles
            .iter()
            .find(|declaration| declaration.profile() == Some(ExtensionProfile::ModelProvider))
            .map(|declaration| {
                declaration
                    .status(
                        ContractRange {
                            major: PROFILE_MAJOR,
                            minimum_minor: 0,
                        },
                        &self.methods,
                    )
                    .is_available()
            })
            .unwrap_or(false)
    }
}

/// A running provider extension process.
pub struct ProviderPlugin {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    frames: Receiver<Frame>,
    pending: VecDeque<Value>,
    reader: Option<JoinHandle<()>>,
    stderr_drain: Option<JoinHandle<u64>>,
    next_id: u64,
    timeout: Duration,
    description: Option<PluginDescription>,
    shutdown_sent: bool,
}

impl ProviderPlugin {
    /// Start a provider program over pipes.
    pub fn spawn(program: &str, args: &[String]) -> Result<Self, ApplicationFailure> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| {
                refusal::actionable(
                    "provider_plugin_spawn_failed",
                    STAGE,
                    "program",
                    RecoveryAction::InstallOrRetryRuntime,
                )
                .with_presentation_arg("program", program)
            })?;
        let Some(stdin) = child.stdin.take() else {
            return Err(refusal::new("provider_plugin_spawn_failed", STAGE).with_field("stdin"));
        };
        let Some(stdout) = child.stdout.take() else {
            return Err(refusal::new("provider_plugin_spawn_failed", STAGE).with_field("stdout"));
        };
        let Some(stderr) = child.stderr.take() else {
            return Err(refusal::new("provider_plugin_spawn_failed", STAGE).with_field("stderr"));
        };
        let (sender, frames) = channel();
        let reader = thread::spawn(move || read_frames(stdout, sender));
        let stderr_drain = thread::spawn(move || drain_diagnostics(stderr));
        Ok(Self {
            child,
            stdin: Arc::new(Mutex::new(stdin)),
            frames,
            pending: VecDeque::new(),
            reader: Some(reader),
            stderr_drain: Some(stderr_drain),
            next_id: 1,
            timeout: DEFAULT_REQUEST_TIMEOUT,
            description: None,
            shutdown_sent: false,
        })
    }

    pub fn set_timeout(&mut self, timeout: Duration) {
        self.timeout = timeout;
    }

    /// Perform the three-method handshake and decide whether the package may
    /// serve model-provider work.
    pub fn initialize(&mut self) -> Result<&PluginDescription, ApplicationFailure> {
        let result = self.request(
            METHOD_INITIALIZE,
            json!({
                "protocol": {"major": PROFILE_MAJOR, "minimumMinor": 0},
                "maxFrameBytes": DEFAULT_MAX_FRAME_BYTES,
                "profiles": [ExtensionProfile::ModelProvider.id()],
            }),
        )?;
        let ready = self.next_notification(METHOD_READY)?;
        let payload = if ready.get("methods").is_some() || ready.get("profiles").is_some() {
            ready
        } else {
            result
        };
        let declared_profiles: Vec<ProfileDeclaration> =
            serde_json::from_value(payload.get("profiles").cloned().unwrap_or(json!([]))).map_err(
                |_| refusal::new("provider_plugin_handshake_invalid", STAGE).with_field("profiles"),
            )?;
        let method_names: Vec<String> =
            serde_json::from_value(payload.get("methods").cloned().unwrap_or(json!([]))).map_err(
                |_| refusal::new("provider_plugin_handshake_invalid", STAGE).with_field("methods"),
            )?;
        let description = PluginDescription {
            protocol_major: payload
                .get("protocol")
                .and_then(|protocol| protocol.get("major"))
                .and_then(Value::as_u64)
                .unwrap_or(u64::from(PROFILE_MAJOR)) as u32,
            declared_profiles,
            methods: DeclaredMethods::new(method_names),
        };
        if !description.model_provider_available() {
            let field = description
                .declared_profiles
                .iter()
                .find(|declaration| declaration.profile() == Some(ExtensionProfile::ModelProvider))
                .map(|declaration| {
                    match declaration.status(
                        ContractRange {
                            major: PROFILE_MAJOR,
                            minimum_minor: 0,
                        },
                        &description.methods,
                    ) {
                        ProfileStatus::MissingMethods { missing } => missing.join(","),
                        ProfileStatus::MissingAlternative { groups } => groups
                            .iter()
                            .filter_map(|group| group.first().copied())
                            .collect::<Vec<_>>()
                            .join(","),
                        _ => "profiles".to_owned(),
                    }
                })
                .unwrap_or_else(|| "profiles".to_owned());
            return Err(refusal::actionable(
                "provider_plugin_profile_unavailable",
                STAGE,
                &field,
                RecoveryAction::InstallOrRetryRuntime,
            ));
        }
        self.description = Some(description);
        Ok(self.description.as_ref().expect("just stored"))
    }

    pub fn description(&self) -> Option<&PluginDescription> {
        self.description.as_ref()
    }

    /// Whether the package declared a method at the handshake.
    pub fn implements(&self, method: &str) -> bool {
        self.description
            .as_ref()
            .is_some_and(|description| description.implements(method))
    }

    pub fn describe(&mut self) -> Result<Value, ApplicationFailure> {
        self.request(METHOD_PROVIDER_DESCRIBE, json!({}))
    }

    /// Ask the provider for its model catalog. Models are validated, so a
    /// malformed entry is refused rather than carried.
    pub fn models(&mut self) -> Result<Vec<ProviderModel>, ApplicationFailure> {
        let result = self.request(METHOD_PROVIDER_MODELS, json!({}))?;
        let models: Vec<ProviderModel> =
            serde_json::from_value(result.get("models").cloned().unwrap_or(json!([])))
                .map_err(|_| refusal::new("provider_models_invalid", STAGE).with_field("models"))?;
        for model in &models {
            model.validate()?;
        }
        Ok(models)
    }

    /// Ask the provider what it knows about an invocation.
    ///
    /// A provider that keeps no invocation state answers `unknown`, and unknown
    /// is preserved: the host reconciles against its own durable record rather
    /// than reading a missing answer as success.
    pub fn reconcile(&mut self, invocation_ref: &str) -> Result<Value, ApplicationFailure> {
        self.request(
            METHOD_PROVIDER_RECONCILE,
            json!({"invocationRef": invocation_ref}),
        )
    }

    /// Send one request and wait for its response, queueing notifications that
    /// arrive in between.
    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, ApplicationFailure> {
        let id = self.next_id;
        self.next_id += 1;
        self.send_frame(json!({
            "jsonrpc": JSONRPC_VERSION,
            "id": id,
            "method": method,
            "params": params,
        }))?;
        loop {
            let Some(frame) = self.next_frame(self.timeout)? else {
                return Err(refusal::new("provider_plugin_timeout", STAGE).with_field(method));
            };
            let Some(object) = frame.as_object() else {
                self.pending.push_back(frame);
                continue;
            };
            if object.get("id").and_then(Value::as_u64) == Some(id) {
                if let Some(error) = object.get("error") {
                    return Err(plugin_error(method, error));
                }
                return Ok(object.get("result").cloned().unwrap_or(Value::Null));
            }
            self.pending.push_back(Value::Object(object.clone()));
        }
    }

    /// Wait for one notification on `method` and return its params.
    pub fn next_notification(&mut self, method: &str) -> Result<Value, ApplicationFailure> {
        loop {
            let Some(frame) = self.next_frame(self.timeout)? else {
                return Err(refusal::new("provider_plugin_timeout", STAGE).with_field(method));
            };
            if let Some(params) = notification_params(&frame, method) {
                return Ok(params);
            }
            self.pending.push_back(frame);
        }
    }

    /// Ordered shutdown: ask for exit, wait, then make sure the process is gone.
    pub fn shutdown(&mut self) {
        if !self.shutdown_sent {
            self.shutdown_sent = true;
            // A shutdown is not worth the full request timeout: a provider that
            // does not answer is killed below either way.
            self.timeout = self.timeout.min(Duration::from_millis(500));
            let _ = self.request("extension.shutdown", json!({}));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        if let Some(drain) = self.stderr_drain.take() {
            let _ = drain.join();
        }
    }

    fn send_frame(&mut self, frame: Value) -> Result<(), ApplicationFailure> {
        let mut line = serde_json::to_vec(&frame).map_err(|_| {
            refusal::new("provider_plugin_frame_invalid", STAGE).with_field("frame")
        })?;
        Framing::default().check_frame(line.len())?;
        line.push(b'\n');
        let mut stdin = self.stdin.lock().map_err(|_| {
            refusal::new("provider_plugin_transport_failed", STAGE).with_field("stdin")
        })?;
        stdin.write_all(&line).map_err(|_| {
            refusal::new("provider_plugin_transport_failed", STAGE).with_field("stdin")
        })?;
        stdin.flush().map_err(|_| {
            refusal::new("provider_plugin_transport_failed", STAGE).with_field("stdout")
        })
    }

    fn next_frame(&mut self, timeout: Duration) -> Result<Option<Value>, ApplicationFailure> {
        if let Some(queued) = self.pending.pop_front() {
            return Ok(Some(queued));
        }
        match self.frames.recv_timeout(timeout) {
            Ok(Frame::Value(value)) => Ok(Some(value)),
            Ok(Frame::Io(message)) => {
                Err(refusal::new("provider_plugin_transport_failed", STAGE).with_field(&message))
            }
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => {
                Err(refusal::new("provider_plugin_terminated", STAGE).with_field("stdout"))
            }
        }
    }
}

impl Drop for ProviderPlugin {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn read_frames(stdout: ChildStdout, sender: Sender<Frame>) {
    let reader = BufReader::new(stdout);
    let bound = Framing::default().negotiated_max_frame_bytes();
    for line in reader.lines() {
        let Ok(line) = line else {
            let _ = sender.send(Frame::Io("stdout".to_owned()));
            return;
        };
        if line.len() > bound {
            let _ = sender.send(Frame::Io("max_frame_bytes".to_owned()));
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(&line) {
            Ok(value) => {
                if sender.send(Frame::Value(value)).is_err() {
                    return;
                }
            }
            Err(_) => {
                let _ = sender.send(Frame::Io("invalid_frame".to_owned()));
                continue;
            }
        }
    }
}

/// Drain a provider's diagnostic stream, counting lines.
///
/// The count is the only thing retained: a provider's diagnostics may carry
/// anything it printed, so the bridge bounds the pipe instead of storing it.
fn drain_diagnostics(mut stderr: impl Read) -> u64 {
    let mut reader = BufReader::new(&mut stderr);
    let mut buffer = Vec::new();
    let mut lines = 0u64;
    loop {
        buffer.clear();
        match reader.read_until(b'\n', &mut buffer) {
            Ok(0) => break,
            Ok(_) => lines = lines.saturating_add(1),
            Err(_) => break,
        }
    }
    lines
}

fn plugin_error(method: &str, error: &Value) -> ApplicationFailure {
    let code = error
        .get("code")
        .map(|code| match code {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        })
        .unwrap_or_else(|| "unknown".to_owned());
    refusal::new("provider_plugin_refused", STAGE)
        .with_field("method")
        .with_presentation_arg("method", method)
        .with_presentation_arg("pluginCode", &code)
}

/// `Some(params)` when `frame` is a notification on `method`.
pub(crate) fn notification_params(frame: &Value, method: &str) -> Option<Value> {
    let object = frame.as_object()?;
    if object.contains_key("id") {
        return None;
    }
    if object.get("method").and_then(Value::as_str) != Some(method) {
        return None;
    }
    Some(object.get("params").cloned().unwrap_or(Value::Null))
}

/// A provider stream carried by a JSON-RPC plugin process.
pub struct ProviderPluginAdapter {
    plugin: ProviderPlugin,
    invocation_ref: Option<String>,
    cancel_support: CancelSupport,
}

impl ProviderPluginAdapter {
    /// Initialize a freshly spawned plugin and wrap it as a stream adapter.
    pub fn connect(mut plugin: ProviderPlugin) -> Result<Self, ApplicationFailure> {
        plugin.initialize()?;
        Ok(Self {
            plugin,
            invocation_ref: None,
            cancel_support: CancelSupport::Unknown,
        })
    }

    pub fn describe(&mut self) -> Result<Value, ApplicationFailure> {
        self.plugin.describe()
    }

    pub fn models(&mut self) -> Result<Vec<ProviderModel>, ApplicationFailure> {
        self.plugin.models()
    }

    pub fn plugin_description(&self) -> Option<&PluginDescription> {
        self.plugin.description()
    }
}

impl StreamAdapter for ProviderPluginAdapter {
    fn start(&mut self, binding: &StreamBinding) -> Result<StartAck, ApplicationFailure> {
        let request = binding.request();
        let instance = binding.instance();
        let credential_state = match instance.credential() {
            crate::credentials::CredentialResolution::Resolved { .. } => "resolved",
            crate::credentials::CredentialResolution::NotConfigured => "not-configured",
            crate::credentials::CredentialResolution::ScopeMismatch { .. } => "scope-mismatch",
        };
        let result = self.plugin.request(
            METHOD_PROVIDER_STREAM,
            json!({
                "invocationRef": request.invocation_ref,
                "effectRef": request.effect_ref,
                "principal": request.principal,
                "model": {
                    "providerId": request.key.provider_id,
                    "providerGeneration": request.key.provider_generation,
                    "vendorModelId": request.key.vendor_model_id,
                },
                "credentialRef": instance.credential_handle().map(|handle| handle.as_str()),
                "credentialState": credential_state,
                "input": request.input,
            }),
        )?;
        if result.get("started").and_then(Value::as_bool) != Some(true) {
            return Err(refusal::new("provider_stream_not_started", STAGE).with_field("started"));
        }
        let cancel_support = result
            .get("cancel")
            .and_then(Value::as_str)
            .and_then(CancelSupport::from_wire)
            .unwrap_or(CancelSupport::Unknown);
        self.cancel_support = cancel_support;
        self.invocation_ref = Some(request.invocation_ref.clone());
        Ok(StartAck { cancel_support })
    }

    fn next_event(&mut self, timeout: Duration) -> Result<Option<StreamEvent>, ApplicationFailure> {
        let Some(invocation_ref) = self.invocation_ref.clone() else {
            return Err(
                refusal::new("provider_stream_not_started", STAGE).with_field("invocationRef")
            );
        };
        loop {
            let Some(frame) = self.plugin.next_frame(timeout)? else {
                return Ok(None);
            };
            let Some(params) = notification_params(&frame, METHOD_PROVIDER_STREAM) else {
                continue;
            };
            if params.get("invocationRef").and_then(Value::as_str) != Some(invocation_ref.as_str())
            {
                continue;
            }
            if let Some(event) = parse_stream_event(&params)? {
                return Ok(Some(event));
            }
        }
    }

    fn cancel(&mut self, invocation_ref: &str) -> CancelOutcome {
        if self.cancel_support == CancelSupport::Unsupported {
            return CancelOutcome::Unsupported;
        }
        if !self.plugin.implements(METHOD_PROVIDER_CANCEL) {
            return CancelOutcome::Unsupported;
        }
        match self.plugin.request(
            METHOD_PROVIDER_CANCEL,
            json!({"invocationRef": invocation_ref}),
        ) {
            Ok(result) => result
                .get("outcome")
                .and_then(Value::as_str)
                .and_then(CancelOutcome::from_wire)
                .unwrap_or(CancelOutcome::Unknown),
            Err(_) => CancelOutcome::Unknown,
        }
    }
}

/// Parse one stream notification into an event. Unknown kinds are ignored so a
/// newer provider can add one without breaking this host.
pub(crate) fn parse_stream_event(
    params: &Value,
) -> Result<Option<StreamEvent>, ApplicationFailure> {
    match params.get("kind").and_then(Value::as_str) {
        Some("text") => {
            let sequence = require_sequence(params)?;
            let body = params.get("body").and_then(Value::as_str).ok_or_else(|| {
                refusal::new("provider_stream_event_invalid", STAGE).with_field("body")
            })?;
            Ok(Some(StreamEvent::Text {
                sequence,
                body: body.to_owned(),
            }))
        }
        Some("notice") => {
            let sequence = require_sequence(params)?;
            let body = params.get("body").and_then(Value::as_str).ok_or_else(|| {
                refusal::new("provider_stream_event_invalid", STAGE).with_field("body")
            })?;
            Ok(Some(StreamEvent::Notice {
                sequence,
                body: body.to_owned(),
            }))
        }
        Some("usage") => {
            let sequence = require_sequence(params)?;
            let usage = parse_usage(params.get("usage").unwrap_or(&Value::Null))?;
            Ok(Some(StreamEvent::Usage { sequence, usage }))
        }
        Some("terminal") => {
            let state = match params.get("outcome").and_then(Value::as_str) {
                Some("completed") | None => TerminalState::Completed,
                Some("cancelled") => TerminalState::Cancelled,
                Some("failed") => {
                    let code = params
                        .get("error")
                        .and_then(|error| error.get("code"))
                        .map(|code| match code {
                            Value::String(text) => text.clone(),
                            other => other.to_string(),
                        })
                        .unwrap_or_else(|| "provider_stream_failed".to_owned());
                    let message = params
                        .get("error")
                        .and_then(|error| error.get("message"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .chars()
                        .take(160)
                        .collect();
                    TerminalState::Failed { code, message }
                }
                Some(_) => {
                    return Err(refusal::new("provider_stream_terminal_invalid", STAGE)
                        .with_field("outcome"));
                }
            };
            let usage = parse_usage(params.get("usage").unwrap_or(&Value::Null))?;
            Ok(Some(StreamEvent::Terminal(StreamTerminal { state, usage })))
        }
        _ => Ok(None),
    }
}

fn require_sequence(params: &Value) -> Result<u64, ApplicationFailure> {
    params
        .get("sequence")
        .and_then(Value::as_u64)
        .ok_or_else(|| refusal::new("provider_stream_event_invalid", STAGE).with_field("sequence"))
}

/// Parse a usage object. A missing field is unknown; a malformed one is refused
/// rather than rounded.
pub(crate) fn parse_usage(value: &Value) -> Result<StreamUsage, ApplicationFailure> {
    if value.is_null() {
        return Ok(StreamUsage::unknown());
    }
    let Some(map) = value.as_object() else {
        return Err(refusal::new("provider_stream_usage_invalid", STAGE).with_field("usage"));
    };
    let input_tokens = optional_tokens(map, "inputTokens")?;
    let output_tokens = optional_tokens(map, "outputTokens")?;
    let cost = match map.get("cost") {
        None | Some(Value::Null) => None,
        Some(Value::Object(cost)) => Some(parse_cost(cost)?),
        Some(_) => {
            return Err(
                refusal::new("provider_stream_usage_invalid", STAGE).with_field("usage.cost")
            );
        }
    };
    Ok(StreamUsage {
        input_tokens,
        output_tokens,
        cost,
    })
}

fn optional_tokens(
    map: &Map<String, Value>,
    field: &str,
) -> Result<Option<u64>, ApplicationFailure> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| {
            refusal::new("provider_stream_usage_invalid", STAGE)
                .with_field(format!("usage.{field}"))
        }),
    }
}

fn parse_cost(cost: &Map<String, Value>) -> Result<CostObservation, ApplicationFailure> {
    let currency = cost
        .get("currency")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            refusal::new("provider_stream_usage_invalid", STAGE).with_field("usage.cost.currency")
        })?
        .to_owned();
    let quality = match cost.get("quality").and_then(Value::as_str) {
        Some("reported") => Quality::Reported,
        Some("estimated") => Quality::Estimated,
        Some("unknown") | None => Quality::Unknown,
        Some(_) => {
            return Err(refusal::new("provider_stream_usage_invalid", STAGE)
                .with_field("usage.cost.quality"));
        }
    };
    let amount = match cost.get("amount") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(text.clone()),
        Some(_) => {
            // Exact decimal text only: binary floating point does not enter a
            // cost observation.
            return Err(refusal::new("provider_stream_usage_invalid", STAGE)
                .with_field("usage.cost.amount"));
        }
    };
    let observation = CostObservation {
        amount,
        currency,
        quality,
    };
    observation.validate()?;
    Ok(observation)
}

/// How an adapter is created for one stream.
pub type AdapterFactory =
    Arc<dyn Fn() -> Result<Box<dyn StreamAdapter>, ApplicationFailure> + Send + Sync>;

/// The adapters a host has available, kept in two separate maps.
///
/// Separation is the point: a compatible dialect is served by a host transport
/// registered for that dialect, and a custom dialect is served only by an adapter
/// registered under the `streamAdapter` id its configuration named. A custom
/// provider cannot be routed to a compatible transport, and a compatible
/// configuration cannot be routed to a custom adapter.
#[derive(Default)]
pub struct AdapterRegistry {
    compatible: BTreeMap<String, AdapterFactory>,
    custom: BTreeMap<String, AdapterFactory>,
}

impl AdapterRegistry {
    pub fn register_compatible(
        &mut self,
        dialect: impl Into<String>,
        factory: AdapterFactory,
    ) -> Option<AdapterFactory> {
        self.compatible.insert(dialect.into(), factory)
    }

    pub fn register_custom(
        &mut self,
        adapter: impl Into<String>,
        factory: AdapterFactory,
    ) -> Option<AdapterFactory> {
        self.custom.insert(adapter.into(), factory)
    }

    pub fn compatible(&self, dialect: &str) -> Option<&AdapterFactory> {
        self.compatible.get(dialect)
    }

    pub fn custom(&self, adapter: &str) -> Option<&AdapterFactory> {
        self.custom.get(adapter)
    }

    pub fn compatible_dialects(&self) -> impl Iterator<Item = &str> {
        self.compatible.keys().map(String::as_str)
    }

    pub fn custom_adapters(&self) -> impl Iterator<Item = &str> {
        self.custom.keys().map(String::as_str)
    }
}

/// A factory that starts one provider program per stream.
pub fn json_rpc_factory(program: impl Into<String>, args: Vec<String>) -> AdapterFactory {
    let program = program.into();
    Arc::new(move || {
        let plugin = ProviderPlugin::spawn(&program, &args)?;
        Ok(Box::new(ProviderPluginAdapter::connect(plugin)?) as Box<dyn StreamAdapter>)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_missing_fields_stay_none_and_malformed_ones_are_refused() {
        let usage = parse_usage(&json!({})).unwrap();
        assert!(usage.is_unknown());
        assert_eq!(usage.input_tokens, None);
        assert_eq!(usage.cost, None);

        let reported = parse_usage(&json!({
            "inputTokens": 12,
            "outputTokens": null,
            "cost": {"amount": "0.0004", "currency": "USD", "quality": "estimated"},
        }))
        .unwrap();
        assert_eq!(reported.input_tokens, Some(12));
        assert_eq!(reported.output_tokens, None);
        assert_eq!(reported.cost.unwrap().amount.as_deref(), Some("0.0004"));

        // A float amount is not exact decimal evidence.
        assert_eq!(
            parse_usage(
                &json!({"cost": {"amount": 0.5, "currency": "USD", "quality": "reported"}})
            )
            .unwrap_err()
            .code,
            "provider_stream_usage_invalid"
        );
        // A negative or non-integer token count is not a count.
        assert_eq!(
            parse_usage(&json!({"inputTokens": -1})).unwrap_err().code,
            "provider_stream_usage_invalid"
        );
        assert_eq!(
            parse_usage(&json!({"inputTokens": 1.5})).unwrap_err().code,
            "provider_stream_usage_invalid"
        );
    }

    #[test]
    fn a_terminal_without_a_known_usage_reports_unknown_not_zero() {
        let event = parse_stream_event(&json!({"kind": "terminal", "outcome": "completed"}))
            .unwrap()
            .expect("terminal");
        let StreamEvent::Terminal(terminal) = event else {
            panic!("expected terminal");
        };
        assert_eq!(terminal.state, TerminalState::Completed);
        assert!(terminal.usage.is_unknown());
        assert_eq!(terminal.usage.input_tokens, None);
    }

    #[test]
    fn cancel_wire_values_round_trip() {
        for outcome in [
            CancelOutcome::Requested,
            CancelOutcome::Acknowledged,
            CancelOutcome::Unsupported,
            CancelOutcome::Unknown,
        ] {
            assert_eq!(CancelOutcome::from_wire(outcome.as_wire()), Some(outcome));
        }
        for support in [
            CancelSupport::Supported,
            CancelSupport::Unsupported,
            CancelSupport::Unknown,
        ] {
            assert_eq!(CancelSupport::from_wire(support.as_wire()), Some(support));
        }
    }
}
