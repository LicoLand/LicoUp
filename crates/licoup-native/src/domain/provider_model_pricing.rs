//! Provider-owned model billing snapshots with bounded official-source refresh.
//!
//! Artificial Analysis remains the capability and benchmark-cost owner. This
//! module owns what a local harness actually meters: USD token prices, ChatGPT
//! credits, and included/subscription routes. Refresh failure never removes the
//! embedded offline snapshot.

use regex::Regex;
use serde::Deserialize;
use std::io::Read;
use std::sync::{OnceLock, RwLock};
use std::time::Duration;

const SNAPSHOT_JSON: &str = include_str!("provider_model_pricing/pricing_snapshot.json");
const MAX_PRICE_PAGE_BYTES: u64 = 2 * 1024 * 1024;
const REFRESH_TIMEOUT: Duration = Duration::from_secs(8);
const PROBE_INPUT_TOKENS: f64 = 1_024.0;
const PROBE_OUTPUT_TOKENS: f64 = 32.0;

#[derive(Clone, Debug, Deserialize)]
struct Snapshot {
    schema_version: u64,
    snapshot_date: String,
    providers: Vec<ProviderPriceTable>,
}

#[derive(Clone, Debug, Deserialize)]
struct ProviderPriceTable {
    id: String,
    source_urls: Vec<String>,
    unit: String,
    models: Vec<ModelPrice>,
}

#[derive(Clone, Debug, Deserialize)]
struct ModelPrice {
    model_id: String,
    input: f64,
    cached_input: Option<f64>,
    output: f64,
    included_by_harness: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProbePriceQuote {
    pub amount: f64,
    pub unit: String,
    pub included: bool,
    pub provider: String,
    pub snapshot_date: String,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RefreshSummary {
    pub providers_attempted: usize,
    pub providers_refreshed: usize,
}

static PRICING: OnceLock<Option<RwLock<Snapshot>>> = OnceLock::new();

fn pricing() -> Option<&'static RwLock<Snapshot>> {
    PRICING
        .get_or_init(|| {
            let snapshot = serde_json::from_str::<Snapshot>(SNAPSHOT_JSON).ok()?;
            (snapshot.schema_version == 1
                && !snapshot.snapshot_date.is_empty()
                && !snapshot.providers.is_empty())
            .then_some(RwLock::new(snapshot))
        })
        .as_ref()
}

/// Quote one minimal diagnostic probe. The quote is used only to order models
/// within the same local harness, so provider-specific units remain intact.
pub fn quote_probe(agent_id: &str, model_keys: &[String]) -> Option<ProbePriceQuote> {
    let provider_id = provider_for_agent(agent_id)?;
    let guard = pricing()?.read().ok()?;
    let provider = guard.providers.iter().find(|row| row.id == provider_id)?;
    let model = model_keys
        .iter()
        .find_map(|key| provider.models.iter().find(|row| row.model_id == *key))?;
    let amount = if model.included_by_harness {
        0.0
    } else {
        (model.input * PROBE_INPUT_TOKENS + model.output * PROBE_OUTPUT_TOKENS) / 1_000_000.0
    };
    Some(ProbePriceQuote {
        amount,
        unit: provider.unit.clone(),
        included: model.included_by_harness,
        provider: provider.id.clone(),
        snapshot_date: guard.snapshot_date.clone(),
    })
}

/// Refresh every provider concurrently from its official public price page.
/// Each provider is merged independently; malformed or unavailable pages keep
/// the last embedded/in-memory values.
pub fn refresh_official_sources() -> RefreshSummary {
    let Some(lock) = pricing() else {
        return RefreshSummary::default();
    };
    let providers = lock
        .read()
        .ok()
        .map(|snapshot| snapshot.providers.clone())
        .unwrap_or_default();
    let attempted = providers.len();
    let handles = providers
        .into_iter()
        .map(|provider| std::thread::spawn(move || refresh_provider(provider)))
        .collect::<Vec<_>>();
    let refreshed = handles
        .into_iter()
        .filter_map(|handle| handle.join().ok().flatten())
        .collect::<Vec<_>>();
    let refreshed_count = refreshed.len();
    if !refreshed.is_empty()
        && let Ok(mut snapshot) = lock.write()
    {
        for provider in refreshed {
            if let Some(current) = snapshot
                .providers
                .iter_mut()
                .find(|row| row.id == provider.id)
            {
                *current = provider;
            }
        }
    }
    RefreshSummary {
        providers_attempted: attempted,
        providers_refreshed: refreshed_count,
    }
}

fn provider_for_agent(agent_id: &str) -> Option<&'static str> {
    match agent_id {
        "claude-code" => Some("deepseek"),
        "kimi-code" => Some("kimi"),
        "antigravity" => Some("google"),
        "cursor" => Some("cursor"),
        "codex" => Some("openai-chatgpt"),
        "kilo-code" => Some("kilo"),
        _ => None,
    }
}

fn refresh_provider(mut provider: ProviderPriceTable) -> Option<ProviderPriceTable> {
    let pages = provider
        .source_urls
        .iter()
        .filter_map(|url| fetch_official_page(url).map(|page| plain_text(&page)))
        .collect::<Vec<_>>();
    if pages.is_empty() {
        return None;
    }
    let changed = match provider.id.as_str() {
        "deepseek" => refresh_deepseek(&mut provider, &pages.concat()),
        "kimi" => refresh_kimi(&mut provider, &pages.concat()),
        "google" => refresh_google(&mut provider, &pages.concat()),
        "cursor" => refresh_cursor(&mut provider, &pages.concat()),
        "openai-chatgpt" => refresh_codex(&mut provider, &pages.concat()),
        "kilo" => refresh_kilo(&mut provider, &pages.concat()),
        _ => false,
    };
    changed.then_some(provider)
}

fn refresh_kilo(provider: &mut ProviderPriceTable, text: &str) -> bool {
    // Kilo's official catalog is dynamic, but its billing contract keeps both
    // Auto Free and `:free` routes at zero cost. A single sentinel price row
    // therefore covers the current runtime catalog without freezing model ids.
    if !text.to_ascii_lowercase().contains("kilo-auto/free")
        && !text.to_ascii_lowercase().contains(":free")
    {
        return false;
    }
    set_prices(provider, "free", None, 0.0, 0.0)
}

fn fetch_official_page(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    if parsed.scheme() != "https" {
        return None;
    }
    let response = ureq::AgentBuilder::new()
        .timeout_connect(REFRESH_TIMEOUT)
        .timeout_read(REFRESH_TIMEOUT)
        .timeout_write(REFRESH_TIMEOUT)
        .redirects(3)
        .build()
        .get(url)
        .call()
        .ok()?;
    let mut reader = response.into_reader().take(MAX_PRICE_PAGE_BYTES + 1);
    let mut body = String::new();
    reader.read_to_string(&mut body).ok()?;
    (body.len() as u64 <= MAX_PRICE_PAGE_BYTES).then_some(body)
}

fn plain_text(html: &str) -> String {
    let without_tags = Regex::new(r"(?s)<[^>]*>")
        .expect("static html regex")
        .replace_all(html, " ");
    Regex::new(r"\s+")
        .expect("static whitespace regex")
        .replace_all(&without_tags, " ")
        .replace("&amp;", "&")
        .replace("&#36;", "$")
}

fn set_prices(
    provider: &mut ProviderPriceTable,
    model_id: &str,
    cached: Option<f64>,
    input: f64,
    output: f64,
) -> bool {
    let Some(model) = provider
        .models
        .iter_mut()
        .find(|row| row.model_id == model_id)
    else {
        return false;
    };
    model.cached_input = cached;
    model.input = input;
    model.output = output;
    true
}

fn captures(text: &str, pattern: &str) -> Option<Vec<f64>> {
    let regex = Regex::new(pattern).ok()?;
    let capture = regex.captures(text)?;
    (1..capture.len())
        .map(|index| capture.get(index)?.as_str().parse::<f64>().ok())
        .collect()
}

fn refresh_deepseek(provider: &mut ProviderPriceTable, text: &str) -> bool {
    let Some(values) = captures(
        text,
        r"(?i)CACHE HIT\D+\$([0-9.]+)\s+\$([0-9.]+).*?CACHE MISS\D+\$([0-9.]+)\s+\$([0-9.]+).*?OUTPUT TOKENS\D+\$([0-9.]+)\s+\$([0-9.]+)",
    ) else {
        return false;
    };
    set_prices(
        provider,
        "deepseek-v4-flash",
        Some(values[0]),
        values[2],
        values[4],
    ) & set_prices(
        provider,
        "deepseek-v4-pro",
        Some(values[1]),
        values[3],
        values[5],
    )
}

fn refresh_kimi(provider: &mut ProviderPriceTable, text: &str) -> bool {
    let k3 = captures(
        text,
        r"(?i)kimi-k3\s+1M tokens\s+\$([0-9.]+)\s+\$([0-9.]+)\s+\$([0-9.]+)",
    )
    .is_some_and(|v| set_prices(provider, "kimi-k3", Some(v[0]), v[1], v[2]));
    let code = captures(
        text,
        r"(?i)kimi-k2\.7-code\s+1M tokens\s+\$([0-9.]+)\s+\$([0-9.]+)\s+\$([0-9.]+)",
    )
    .is_some_and(|v| set_prices(provider, "kimi-k2-7-code", Some(v[0]), v[1], v[2]));
    k3 || code
}

fn refresh_google(provider: &mut ProviderPriceTable, text: &str) -> bool {
    [
        ("gemini-3-6-flash", "gemini-3.6-flash"),
        ("gemini-3-1-pro-preview", "gemini-3.1-pro-preview"),
    ]
    .into_iter()
    .filter_map(|(id, marker)| {
        let start = text.find(marker)?;
        let window = text.get(start..start.saturating_add(1_200).min(text.len()))?;
        let values = captures(
            window,
            r"(?i)Input price.*?\$([0-9.]+).*?Output price.*?\$([0-9.]+).*?Context caching price.*?\$([0-9.]+)",
        )?;
        Some(set_prices(provider, id, Some(values[2]), values[0], values[1]))
    })
    .any(|changed| changed)
}

fn refresh_cursor(provider: &mut ProviderPriceTable, text: &str) -> bool {
    let Some(values) = captures(
        text,
        r"(?i)Standard:\s*\$([0-9.]+)/M input,\s*\$([0-9.]+)/M output.*?Fast \(default\):\s*\$([0-9.]+)/M input,\s*\$([0-9.]+)/M output",
    ) else {
        return false;
    };
    set_prices(provider, "composer-2-5", None, values[0], values[1])
        & set_prices(provider, "composer-2-5-fast", None, values[2], values[3])
}

fn refresh_codex(provider: &mut ProviderPriceTable, text: &str) -> bool {
    [
        ("gpt-5-6-sol", "GPT-5.6 Sol"),
        ("gpt-5-6-terra", "GPT-5.6 Terra"),
        ("gpt-5-6-luna", "GPT-5.6 Luna"),
    ]
    .into_iter()
    .filter_map(|(id, marker)| {
        let start = text.find(marker)?;
        let window = text.get(start..start.saturating_add(240).min(text.len()))?;
        let values = captures(
            window,
            r"(?i)([0-9.]+) credits\s+([0-9.]+) credits\s+([0-9,.]+) credits",
        )?;
        Some(set_prices(
            provider,
            id,
            Some(values[1]),
            values[0],
            values[2],
        ))
    })
    .any(|changed| changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_harness_routes_preserve_zero_cost_probe_billing() {
        let quote = quote_probe("cursor", &["composer-2-5".into()]).unwrap();
        assert_eq!(quote.amount, 0.0);
        assert!(quote.included);
        assert_eq!(quote.unit, "usd_per_million_tokens");

        let kilo = quote_probe("kilo-code", &["free".into()]).unwrap();
        assert_eq!(kilo.amount, 0.0);
        assert!(kilo.included);
        assert_eq!(kilo.provider, "kilo");
    }

    #[test]
    fn provider_parsers_update_synthetic_official_tables() {
        let mut snapshot = serde_json::from_str::<Snapshot>(SNAPSHOT_JSON).unwrap();
        let deepseek = snapshot
            .providers
            .iter_mut()
            .find(|p| p.id == "deepseek")
            .unwrap();
        assert!(refresh_deepseek(
            deepseek,
            "CACHE HIT $0.1 $0.2 CACHE MISS $1 $2 OUTPUT TOKENS $3 $4"
        ));
        assert_eq!(deepseek.models[0].output, 3.0);

        let cursor = snapshot
            .providers
            .iter_mut()
            .find(|p| p.id == "cursor")
            .unwrap();
        assert!(refresh_cursor(
            cursor,
            "Standard: $0.5/M input, $2.5/M output tokens Fast (default): $3/M input, $15/M output tokens"
        ));
        assert_eq!(cursor.models[1].output, 15.0);

        let kilo = snapshot
            .providers
            .iter_mut()
            .find(|provider| provider.id == "kilo")
            .unwrap();
        assert!(refresh_kilo(
            kilo,
            "Auto Free (`kilo-auto/free`) requires no credits; tagged models use `:free`."
        ));
        assert_eq!(kilo.models[0].input, 0.0);
        assert_eq!(kilo.models[0].output, 0.0);
    }
}
