//! Usage identity is separate from a provider's selectable model variant.
//! Raw cache keys stay lossless; only the native report projection groups them.

use super::contract::{ModelTokenUsageSummary, UNATTRIBUTED_MODEL};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Debug, Eq, PartialEq)]
struct UsageModelIdentity {
    model: String,
    variant: String,
}

fn identity(raw: &str) -> UsageModelIdentity {
    let raw = raw.trim().trim_start_matches('~');
    let candidate = raw.rsplit('/').next().unwrap_or(raw);
    let family = candidate
        .split([' ', '-', '_'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let candidate = if known_family(&family) {
        candidate
    } else {
        raw
    };
    let mut words = candidate
        .to_ascii_lowercase()
        .replace(['_', '-', '/'], " ")
        .split_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    while words.first().is_some_and(|word| {
        matches!(
            word.as_str(),
            "cursor" | "openai" | "anthropic" | "google" | "moonshot" | "moonshotai" | "xai"
        )
    }) && words.len() > 1
        && words.get(1).is_some_and(|word| word != "auto")
    {
        words.remove(0);
    }
    if words.is_empty()
        || (words.len() == 1
            && matches!(
                words[0].as_str(),
                "cursor" | "openai" | "anthropic" | "google" | "moonshot" | "others"
            ))
    {
        return UsageModelIdentity {
            model: UNATTRIBUTED_MODEL.to_owned(),
            variant: "Unspecified".to_owned(),
        };
    }
    // Unknown identities are never shortened or matched by substring: a
    // custom model named `research-high` must not turn into `research`.
    if !known_family(&words[0]) {
        return UsageModelIdentity {
            model: raw.to_owned(),
            variant: "Unspecified".to_owned(),
        };
    }
    let supports_variant = matches!(words[0].as_str(), "o1" | "o3" | "o4")
        || words.get(1).is_some_and(|word| {
            word.starts_with(|c: char| c.is_ascii_digit())
                || word
                    .strip_prefix(['v', 'k'])
                    .is_some_and(|version| version.starts_with(|c: char| c.is_ascii_digit()))
                || (words[0] == "claude"
                    && matches!(word.as_str(), "fable" | "opus" | "sonnet" | "haiku"))
        });
    let mut fast = false;
    let mut effort = None;
    if supports_variant {
        loop {
            if words.last().is_some_and(|word| word == "fast") {
                words.pop();
                fast = true;
            } else if words.len() >= 2 && words[words.len() - 2..] == ["extra", "high"] {
                words.truncate(words.len() - 2);
                effort = Some("Extra High");
            } else {
                let label = match words.last().map(String::as_str) {
                    Some("low") => Some("Low"),
                    Some("medium") => Some("Medium"),
                    Some("high") => Some("High"),
                    Some("xhigh") => Some("Extra High"),
                    Some("max") => Some("Max"),
                    _ => None,
                };
                if let Some(label) = label {
                    words.pop();
                    effort = Some(label);
                } else {
                    break;
                }
            }
        }
    }
    let mut version_words: Vec<String> = Vec::new();
    for word in words {
        if word.chars().all(|c| c.is_ascii_digit())
            && version_words
                .last()
                .is_some_and(|last| last.chars().all(|c| c.is_ascii_digit() || c == '.'))
            && word.len() <= 2
        {
            version_words
                .last_mut()
                .unwrap()
                .push_str(&format!(".{word}"));
        } else {
            version_words.push(word);
        }
    }
    UsageModelIdentity {
        model: version_words.join("-"),
        variant: match (effort, fast) {
            (Some(effort), true) => format!("{effort} Fast"),
            (Some(effort), false) => effort.to_owned(),
            (None, true) => "Fast".to_owned(),
            (None, false) => "Unspecified".to_owned(),
        },
    }
}

fn known_family(family: &str) -> bool {
    matches!(
        family,
        "gpt"
            | "claude"
            | "gemini"
            | "grok"
            | "kimi"
            | "deepseek"
            | "glm"
            | "qwen"
            | "composer"
            | "o1"
            | "o3"
            | "o4"
    )
}

#[derive(Default)]
struct ModelProjection {
    total: ModelTokenUsageSummary,
    variants: BTreeMap<String, ModelTokenUsageSummary>,
}

pub(super) fn project_model_usage(
    raw: &BTreeMap<String, ModelTokenUsageSummary>,
) -> BTreeMap<String, Value> {
    let mut models = BTreeMap::<String, ModelProjection>::new();
    for (raw_model, usage) in raw {
        let identity = identity(raw_model);
        let model = models.entry(identity.model).or_default();
        model.total.merge(*usage);
        model
            .variants
            .entry(identity.variant)
            .or_default()
            .merge(*usage);
    }
    models
        .into_iter()
        .map(|(name, model)| {
            let mut value = model.total.to_json();
            value["variants"] = json!(
                model
                    .variants
                    .into_iter()
                    .map(|(variant, totals)| (variant, totals.to_json()))
                    .collect::<BTreeMap<_, _>>()
            );
            (name, value)
        })
        .collect()
}

pub(super) fn raw_model_usage(source: &Value) -> BTreeMap<String, ModelTokenUsageSummary> {
    let mut raw = BTreeMap::<String, ModelTokenUsageSummary>::new();
    if let Some(models) = source.get("modelTokenUsage").and_then(Value::as_object) {
        for (model, value) in models {
            if let Some(variants) = value.get("variants").and_then(Value::as_object) {
                for (variant, totals) in variants {
                    let key = if variant == "Unspecified" {
                        model.clone()
                    } else {
                        format!("{model}-{variant}")
                    };
                    raw.entry(key)
                        .or_default()
                        .merge(ModelTokenUsageSummary::from_json(totals));
                }
            } else {
                raw.entry(model.clone())
                    .or_default()
                    .merge(ModelTokenUsageSummary::from_json(value));
            }
        }
    } else if let Some(models) = source.get("modelUsage").and_then(Value::as_object) {
        for (model, total) in models {
            raw.entry(model.clone())
                .or_default()
                .merge(ModelTokenUsageSummary {
                    total_tokens: total.as_u64().unwrap_or(0),
                    ..Default::default()
                });
        }
    }
    raw
}

pub(super) fn normalize_retained_report(report: &mut Value) {
    if let Some(agents) = report.get_mut("agents").and_then(Value::as_array_mut) {
        for agent in agents {
            if let Some(history) = agent.get_mut("history") {
                normalize_bucket(history);
                if let Some(days) = history.get_mut("dailyUsage").and_then(Value::as_array_mut) {
                    for day in days {
                        normalize_bucket(day);
                    }
                }
            }
        }
    }
}

fn normalize_bucket(bucket: &mut Value) {
    let models = project_model_usage(&raw_model_usage(bucket));
    if models.is_empty() {
        return;
    }
    bucket["modelUsage"] = json!(
        models
            .iter()
            .map(|(name, usage)| (name.clone(), usage["totalTokens"].clone()))
            .collect::<BTreeMap<_, _>>()
    );
    bucket["modelTokenUsage"] = json!(models);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_identity_merges_only_recognized_model_variants() {
        for raw in [
            "Cursor Grok 4.6 Extra High Fast",
            "xai/grok-4-6-fast-xhigh",
            "grok-4.6-xhigh-fast",
        ] {
            assert_eq!(
                identity(raw),
                UsageModelIdentity {
                    model: "grok-4.6".to_owned(),
                    variant: "Extra High Fast".to_owned()
                }
            );
        }
        assert_eq!(identity("moonshot/kimi-k3-high").model, "kimi-k3");
        assert_eq!(identity("custom/kimi-k3").model, "kimi-k3");
        assert_eq!(identity("Cursor").model, UNATTRIBUTED_MODEL);
        assert_eq!(
            identity("custom/research-high").model,
            "custom/research-high"
        );
        assert_ne!(identity("Grok bot automation").model, "grok");
        assert_eq!(identity("grok-research-high").model, "grok-research-high");
    }

    #[test]
    fn native_projection_conserves_tokens_and_request_only_variants() {
        let mut report = json!({"agents": [{"history": {"dailyUsage": [{"totalTokens": 600, "modelTokenUsage": {
            "Cursor Grok 4.6 High": {"promptTokens": 80, "completionTokens": 20, "totalTokens": 100, "requestCount": 1},
            "grok-4.6-extra-high": {"totalTokens": 200, "requestCount": 2},
            "grok-4.6-fast-xhigh": {"totalTokens": 300, "requestCount": 3},
            "grok-4.6-low": {"requestCount": 4, "tokenUnavailableRequests": 4},
            "Cursor": {"totalTokens": 50},
            "custom/research-high": {"totalTokens": 25}
        }}]}}]});
        normalize_retained_report(&mut report);
        let day = &report["agents"][0]["history"]["dailyUsage"][0];
        assert_eq!(day["modelUsage"]["grok-4.6"], 600);
        assert_eq!(day["modelUsage"][UNATTRIBUTED_MODEL], 50);
        assert_eq!(day["modelUsage"]["custom/research-high"], 25);
        assert!(day["modelUsage"].get("Cursor").is_none());
        assert_eq!(day["modelTokenUsage"]["grok-4.6"]["requestCount"], 10);
        assert_eq!(
            day["modelTokenUsage"]["grok-4.6"]["variants"]["Extra High Fast"]["totalTokens"],
            300
        );
        let once = report.clone();
        normalize_retained_report(&mut report);
        assert_eq!(report, once);
    }
}
