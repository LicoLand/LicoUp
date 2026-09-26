//! Shared fixtures for the v7.1 model-provider integration tests.
//!
//! Everything here is synthetic: configurations and manifests are read from
//! `extensions/providers/`, the compatible transport replays a fixture file, and
//! the custom provider is a local Python process. No test reaches the network,
//! an account or key material.

use licoup_extension_contracts::manifest::PackageManifest;
use licoup_extension_contracts::provider::{
    CatalogSource, CredentialScope, ProviderConfig, ProviderModel,
};
use licoup_extension_contracts::usage::{CostObservation, Quality};
use licoup_model_provider::plugin::{
    AdapterFactory, ProviderPlugin, ProviderPluginAdapter, json_rpc_factory,
};
use licoup_model_provider::{
    CancelOutcome, CancelSupport, CredentialHandle, ProviderRuntime, StartAck, StreamAdapter,
    StreamBinding, StreamEvent, StreamTerminal, StreamUsage, TerminalState,
};
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub type CredentialRecord = Arc<Mutex<Option<String>>>;

pub fn repo_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(relative)
}

pub fn fixture_value(relative: &str) -> Value {
    let text = std::fs::read_to_string(repo_path(relative))
        .unwrap_or_else(|error| panic!("read {relative}: {error}"));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("parse {relative}: {error}"))
}

pub fn fixture_config(relative: &str) -> ProviderConfig {
    ProviderConfig::from_value(fixture_value(relative))
        .unwrap_or_else(|failure| panic!("{relative}: {}", failure.code))
}

pub fn fixture_manifest(relative: &str) -> PackageManifest {
    PackageManifest::from_value(fixture_value(relative))
        .unwrap_or_else(|failure| panic!("{relative}: {}", failure.code))
}

/// A clearly synthetic compatible configuration, for tests that need several
/// providers without reading a file.
pub fn synthetic_compatible_config(id: &str, revision: u32, model: &str) -> ProviderConfig {
    ProviderConfig {
        schema: licoup_extension_contracts::wire::PROVIDER.to_owned(),
        id: id.to_owned(),
        display_name: format!("Synthetic {id}"),
        base_url: "http://127.0.0.1:8098/v1".to_owned(),
        api_dialect: "openai-chat-compatible".to_owned(),
        credential_ref: None,
        config_revision: revision,
        catalog_source: CatalogSource::Static,
        models: vec![ProviderModel {
            id: model.to_owned(),
            display_name: model.to_owned(),
            input_modalities: vec!["text".to_owned()],
            output_modalities: vec!["text".to_owned()],
            tools: None,
            reasoning: None,
            context_tokens: None,
            pricing_source: None,
        }],
        compat: BTreeMap::new(),
        stream_adapter: None,
    }
}

/// Record a host-issued handle for the provider's configured reference and
/// origin, as an authorized flow would.
pub fn authorize(runtime: &mut ProviderRuntime, config: &ProviderConfig) {
    let reference = config
        .credential_ref
        .clone()
        .expect("fixture configuration carries a credential handle");
    let origin = config
        .origin()
        .expect("fixture configuration has an origin");
    runtime.credentials_mut().insert(
        CredentialScope {
            reference: reference.clone(),
            provider_id: config.id.clone(),
            origin,
        },
        CredentialHandle::new(reference),
    );
}

// -- the compatible transport's synthetic stream ---------------------------

#[derive(Clone)]
struct FixtureStep {
    delay: Duration,
    event: StreamEvent,
}

struct FixtureAdapter {
    steps: VecDeque<FixtureStep>,
    credential: CredentialRecord,
}

impl StreamAdapter for FixtureAdapter {
    fn start(
        &mut self,
        binding: &StreamBinding,
    ) -> Result<StartAck, licoup_application::ApplicationFailure> {
        *self.credential.lock().expect("record lock") = binding
            .instance()
            .credential_handle()
            .map(|handle| handle.as_str().to_owned());
        Ok(StartAck {
            cancel_support: CancelSupport::Unsupported,
        })
    }

    fn next_event(
        &mut self,
        _timeout: Duration,
    ) -> Result<Option<StreamEvent>, licoup_application::ApplicationFailure> {
        match self.steps.pop_front() {
            Some(step) => {
                if step.delay > Duration::ZERO {
                    std::thread::sleep(step.delay);
                }
                Ok(Some(step.event))
            }
            None => Ok(None),
        }
    }

    fn cancel(&mut self, _invocation_ref: &str) -> CancelOutcome {
        CancelOutcome::Unsupported
    }
}

/// A transport for the compatible dialect that replays a fixture file.
pub fn fixture_adapter_factory(relative: &str, credential: CredentialRecord) -> AdapterFactory {
    let steps = load_fixture_steps(relative);
    Arc::new(move || {
        Ok(Box::new(FixtureAdapter {
            steps: steps.clone(),
            credential: Arc::clone(&credential),
        }) as Box<dyn StreamAdapter>)
    })
}

fn load_fixture_steps(relative: &str) -> VecDeque<FixtureStep> {
    let text = std::fs::read_to_string(repo_path(relative))
        .unwrap_or_else(|error| panic!("read {relative}: {error}"));
    let mut steps = VecDeque::new();
    let mut sequence = 0u64;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value =
            serde_json::from_str(line).unwrap_or_else(|error| panic!("{line}: {error}"));
        let delay =
            Duration::from_millis(value.get("delayMs").and_then(Value::as_u64).unwrap_or(0));
        let event = match value.get("kind").and_then(Value::as_str) {
            Some("text") => {
                sequence += 1;
                StreamEvent::Text {
                    sequence,
                    body: value
                        .get("body")
                        .and_then(Value::as_str)
                        .expect("fixture text body")
                        .to_owned(),
                }
            }
            Some("usage") => {
                sequence += 1;
                StreamEvent::Usage {
                    sequence,
                    usage: usage_from(value.get("usage").unwrap_or(&Value::Null)),
                }
            }
            Some("terminal") => StreamEvent::Terminal(StreamTerminal {
                state: TerminalState::Completed,
                usage: usage_from(value.get("usage").unwrap_or(&Value::Null)),
            }),
            other => panic!("unknown fixture kind: {other:?}"),
        };
        steps.push_back(FixtureStep { delay, event });
    }
    steps
}

fn usage_from(value: &Value) -> StreamUsage {
    if value.is_null() {
        return StreamUsage::unknown();
    }
    let cost = value.get("cost").map(|cost| CostObservation {
        amount: cost
            .get("amount")
            .and_then(Value::as_str)
            .map(str::to_owned),
        currency: cost
            .get("currency")
            .and_then(Value::as_str)
            .unwrap_or("USD")
            .to_owned(),
        quality: match cost.get("quality").and_then(Value::as_str) {
            Some("reported") => Quality::Reported,
            Some("estimated") => Quality::Estimated,
            _ => Quality::Unknown,
        },
    });
    StreamUsage {
        input_tokens: value.get("inputTokens").and_then(Value::as_u64),
        output_tokens: value.get("outputTokens").and_then(Value::as_u64),
        cost,
    }
}

// -- the custom provider process -------------------------------------------

fn plugin_args(extra: &[&str]) -> Vec<String> {
    let mut args = vec![
        repo_path("extensions/providers/synthetic-custom/provider.py")
            .to_string_lossy()
            .into_owned(),
    ];
    args.extend(extra.iter().map(|flag| (*flag).to_owned()));
    args
}

pub fn plugin_handle(extra: &[&str]) -> ProviderPlugin {
    ProviderPlugin::spawn("python3", &plugin_args(extra)).expect("spawn synthetic provider")
}

pub fn plugin_adapter(extra: &[&str]) -> ProviderPluginAdapter {
    ProviderPluginAdapter::connect(plugin_handle(extra)).expect("initialize synthetic provider")
}

pub fn plugin_models(extra: &[&str]) -> Vec<ProviderModel> {
    plugin_adapter(extra).models().expect("discovered models")
}

/// A custom-dialect adapter factory that starts the synthetic provider per
/// stream.
pub fn plugin_factory(extra: &[&str]) -> AdapterFactory {
    json_rpc_factory("python3", plugin_args(extra))
}

// -- draining a stream ------------------------------------------------------

#[derive(Debug, Default)]
pub struct DrainReport {
    pub text: String,
    pub notices: Vec<String>,
    pub terminal: Option<StreamTerminal>,
    pub events: usize,
}

impl DrainReport {
    pub fn credential_notice(&self) -> Option<&str> {
        self.notices
            .iter()
            .find(|notice| notice.starts_with("credential="))
            .map(String::as_str)
    }
}

/// Read until the terminal frame (or silence) and collect what arrived.
pub fn drain(session: &mut licoup_model_provider::StreamSession) -> DrainReport {
    let mut report = DrainReport::default();
    loop {
        match session.next_event().expect("stream event") {
            Some(StreamEvent::Text { body, .. }) => report.text.push_str(&body),
            Some(StreamEvent::Notice { body, .. }) => report.notices.push(body),
            Some(StreamEvent::Usage { .. }) => {}
            Some(StreamEvent::Terminal(terminal)) => {
                report.terminal = Some(terminal);
                break;
            }
            None => break,
        }
        report.events += 1;
    }
    report
}
