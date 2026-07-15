use crate::platform::file_security::atomic_write_private_text;
use crate::platform::paths::portable_data_dir;
use crate::platform::secure_mesh_secret_store::SecretStoreHandle;
#[cfg(not(test))]
use crate::platform::secure_mesh_secret_store::{
    PlatformSecretStore, SecretStoreAuthorizationRequest, SecureMeshSecretStore,
};
use crate::platform::url_security::is_https_or_loopback_http_url;
use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const PROFILE_SCHEMA_VERSION: u32 = 1;
const FORWARDING_DIR: &str = "model-forwarding";
const PROFILES_FILE: &str = "profiles.json";
const DEFAULT_CHATGPT_RESPONSES_URL: &str = "https://api.openai.com/v1/responses";
const DEFAULT_CHATGPT_MODEL: &str = "gpt-5.4-mini";
const DEFAULT_GEMINI_INTERACTIONS_URL: &str =
    "https://generativelanguage.googleapis.com/v1beta/interactions";
const DEFAULT_GEMINI_MODEL: &str = "gemini-3.5-flash";
const DEFAULT_KIMI_CHAT_URL: &str = "https://api.moonshot.cn/v1/chat/completions";
const DEFAULT_KIMI_MODEL: &str = "kimi-k2.6";
const DEFAULT_DEEPSEEK_CHAT_URL: &str = "https://api.deepseek.com/chat/completions";
const DEFAULT_DEEPSEEK_MODEL: &str = "deepseek-v4-flash";
const PROVIDER_CREDENTIAL_SECRET_SERVICE: &str = "app.licolite.licoarc.model-forwarding.v1";
const PROVIDER_CREDENTIAL_ACCOUNT_PREFIX: &str = "modelForwardingProviderCredential";
const PROVIDER_CREDENTIAL_HANDLE_NAMESPACE: &str = "providerApiKey";
const PROVIDER_CREDENTIAL_REF_SCHEMA_VERSION: &str =
    "licolite.model-forwarding.provider-credential-ref.v1";

#[cfg(test)]
thread_local! {
    static TEST_CONFIGURED_API_KEYS: std::cell::RefCell<std::collections::HashMap<String, String>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
    static TEST_CONFIGURED_OAUTH_CREDENTIALS: std::cell::RefCell<std::collections::HashMap<String, Value>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
    static TEST_PROVIDER_CREDENTIAL_SECRETS: std::cell::RefCell<std::collections::HashMap<String, String>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
}

pub fn list_model_profiles() -> Result<Value> {
    list_model_profiles_in(&portable_data_dir()?)
}

pub fn save_model_profile(params: &Value) -> Result<Value> {
    save_model_profile_in(&portable_data_dir()?, params)
}

pub fn delete_model_profile_credential(params: &Value) -> Result<Value> {
    delete_model_profile_credential_in(&portable_data_dir()?, params)
}

pub fn forward(params: &Value) -> Result<Value> {
    forward_in(&portable_data_dir()?, params)
}

pub fn provider_chat(params: &Value) -> Result<Value> {
    provider_chat_in(&portable_data_dir()?, params)
}

pub fn export_provider_credential(params: &Value) -> Result<Value> {
    export_provider_credential_in(&portable_data_dir()?, params)
}

fn list_model_profiles_in(data_dir: &Path) -> Result<Value> {
    let profiles = configured_model_profiles(data_dir)?
        .into_iter()
        .map(annotate_profile_credential_state)
        .map(mask_profile_secrets)
        .collect::<Vec<_>>();
    Ok(json!({
        "ok": true,
        "schemaVersion": PROFILE_SCHEMA_VERSION,
        "profiles": profiles
    }))
}

fn mask_profile_secrets(mut profile: Value) -> Value {
    if let Some(headers) = profile.get_mut("headers").and_then(|h| h.as_object_mut()) {
        for key in [
            "x-licolite-api-key",
            "X-LicoLite-Api-Key",
            "authorization",
            "Authorization",
            "api-key",
            "Api-Key",
            "apiKey",
            "x-goog-api-key",
            "X-Goog-Api-Key",
            "accessToken",
            "access_token",
            "refreshToken",
            "refresh_token",
            "idToken",
            "id_token",
        ] {
            if headers.contains_key(key) {
                headers.insert(key.to_string(), json!("***"));
            }
        }
    }
    profile
}

fn annotate_profile_credential_state(mut profile: Value) -> Value {
    let provider_id = provider_profile_ids(&profile).into_iter().next();
    let credential_present = provider_id.as_deref().map(|provider_id| {
        if provider_profile_credential_kind(&profile).starts_with("oauth") {
            configured_provider_oauth_credential(provider_id, &json!({})).is_some()
                || profile
                    .get("credentialPresent")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        } else {
            provider_credential_from_profile(provider_id, &profile)
                .ok()
                .flatten()
                .is_some()
        }
    });
    if let (Some(credential_present), Some(object)) = (credential_present, profile.as_object_mut())
    {
        object.insert("credentialPresent".to_string(), json!(credential_present));
    }
    profile
}

fn save_model_profile_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let id = profile_id(params)?;
    let requested_provider = params
        .get("provider")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            params
                .get("command")
                .and_then(Value::as_str)
                .map(|_| "command".to_string())
        })
        .or_else(|| {
            params
                .get("url")
                .and_then(Value::as_str)
                .map(|_| "http".to_string())
        });
    let provider_profile = requested_provider
        .as_deref()
        .and_then(normalize_provider_id)
        .or_else(|| normalize_provider_id(&id));
    let provider = requested_provider
        .or_else(|| {
            if secret_param(params).is_some() {
                provider_profile.clone()
            } else {
                None
            }
        })
        .ok_or_else(|| {
            anyhow!("model profile requires --command, --url, or a supported provider --api-key")
        })?;

    let normalized_provider = normalize_provider_id(&provider);
    if provider != "command" && provider != "http" && normalized_provider.is_none() {
        return Err(anyhow!("unsupported forwarding provider: {}", provider));
    }
    let stored_provider = normalized_provider.unwrap_or(provider.clone());

    let mut profile = Map::new();
    profile.insert("id".to_string(), json!(id));
    profile.insert("provider".to_string(), json!(stored_provider.clone()));
    let label = params
        .get("label")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| {
            if is_supported_provider(&stored_provider) {
                provider_label(&stored_provider).to_string()
            } else {
                id.clone()
            }
        });
    profile.insert("label".to_string(), json!(label));
    if let Some(command) = params.get("command").and_then(Value::as_str) {
        profile.insert("command".to_string(), json!(command));
    }
    if let Some(args) = profile_args(params) {
        profile.insert("args".to_string(), args);
    }
    if let Some(url) = params.get("url").and_then(Value::as_str) {
        profile.insert("url".to_string(), json!(url));
    } else if let Some(default_url) = default_provider_url(&stored_provider) {
        profile.insert("url".to_string(), json!(default_url));
    }
    if let Some(model) = params.get("model").and_then(Value::as_str) {
        profile.insert("model".to_string(), json!(model));
    } else if let Some(model) = params.get("modelId").and_then(Value::as_str) {
        profile.insert("model".to_string(), json!(model));
    } else if let Some(default_model) = default_provider_model(&stored_provider) {
        profile.insert("model".to_string(), json!(default_model));
    }
    let mut headers = headers_param(params);
    remove_provider_credential_headers(&mut headers);
    if !headers.is_empty() {
        profile.insert("headers".to_string(), Value::Object(headers));
    }
    if let Some(api_key) = secret_param(params) {
        let credential_ref = store_provider_credential_secret(&id, &stored_provider, &api_key)?;
        profile.insert("providerCredentialRef".to_string(), credential_ref);
        profile.insert("credentialKind".to_string(), json!("api-key"));
        profile.insert(
            "credentialStorage".to_string(),
            json!("platform-secret-store"),
        );
        profile.insert("credentialPresent".to_string(), json!(true));
        profile.insert(
            "credentialHint".to_string(),
            json!(credential_hint(&api_key)),
        );
    }

    // Safety guardrails - stored in profile, enforced at forward time
    let timeout_ms = params
        .get("timeoutMs")
        .and_then(Value::as_u64)
        .unwrap_or(30_000);
    let max_stdout_bytes = params
        .get("maxStdoutBytes")
        .and_then(Value::as_u64)
        .unwrap_or(1_048_576);
    let max_stderr_bytes = params
        .get("maxStderrBytes")
        .and_then(Value::as_u64)
        .unwrap_or(262_144);
    let explicit_user_approved = params
        .get("explicitUserApproved")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    profile.insert("timeoutMs".to_string(), json!(timeout_ms));
    profile.insert("maxStdoutBytes".to_string(), json!(max_stdout_bytes));
    profile.insert("maxStderrBytes".to_string(), json!(max_stderr_bytes));
    profile.insert(
        "explicitUserApproved".to_string(),
        json!(explicit_user_approved),
    );
    profile.insert("createdAt".to_string(), json!(timestamp()));
    profile.insert("updatedAt".to_string(), json!(timestamp()));

    let mut document = read_profiles_document(data_dir)?;
    let profiles = document
        .get_mut("profiles")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| anyhow!("profiles document is malformed"))?;
    profiles.retain(|item| item.get("id").and_then(Value::as_str) != Some(&id));
    profiles.push(Value::Object(profile));
    profiles.sort_by(|left, right| {
        left.get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(right.get("id").and_then(Value::as_str).unwrap_or_default())
    });
    write_profiles_document(data_dir, &document)?;

    Ok(json!({
        "ok": true,
        "status": "saved",
        "profile": id,
        "path": display_path(profiles_path(data_dir))
    }))
}

fn delete_model_profile_credential_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let id = profile_id(params)?;
    let mut document = read_profiles_document(data_dir)?;
    let profiles = document
        .get_mut("profiles")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| anyhow!("profiles document is malformed"))?;
    let profile = profiles
        .iter()
        .find(|profile| profile.get("id").and_then(Value::as_str) == Some(id.as_str()))
        .cloned()
        .ok_or_else(|| anyhow!("model profile credential not found"))?;
    let stored_provider = profile
        .get("provider")
        .and_then(Value::as_str)
        .and_then(normalize_provider_id)
        .ok_or_else(|| anyhow!("model profile is not a supported provider credential"))?;
    if let Some(requested_provider) = text_param(params, &["provider", "providerId"])
        .and_then(|provider| normalize_provider_id(&provider))
    {
        if requested_provider != stored_provider {
            return Err(anyhow!(
                "model profile credential provider does not match account scope"
            ));
        }
    }
    ensure_provider_credential_secret_deleted(&profile)?;
    profiles.retain(|profile| profile.get("id").and_then(Value::as_str) != Some(id.as_str()));
    write_profiles_document(data_dir, &document)?;
    Ok(json!({
        "ok": true,
        "status": "deleted",
        "profile": id,
        "providerId": stored_provider,
        "credentialDeleted": true,
        "deleted": true,
        "bodyRedacted": true
    }))
}

fn forward_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let profile_id = params
        .get("profile")
        .or_else(|| params.get("modelProfile"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("forward requires --profile <profile-id>"))?
        .to_string();
    let input = forward_input(params)?;
    let profile = find_profile(data_dir, &profile_id)?;
    let provider = profile
        .get("provider")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match provider {
        "command" => forward_command(&profile_id, &profile, &input),
        "http" => forward_http(&profile_id, &profile, &input),
        _ => Err(anyhow!("unsupported forwarding provider: {}", provider)),
    }
}

fn forward_command(profile_id: &str, profile: &Value, input: &str) -> Result<Value> {
    let command = profile
        .get("command")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("command profile is missing command"))?;
    let args = profile_args(profile)
        .unwrap_or_else(|| json!([]))
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| value.as_str().map(str::to_string))
        .collect::<Vec<_>>();
    let timeout_ms = profile
        .get("timeoutMs")
        .and_then(Value::as_u64)
        .unwrap_or(30_000);
    let max_stdout = profile
        .get("maxStdoutBytes")
        .and_then(Value::as_u64)
        .unwrap_or(1_048_576) as usize;
    let max_stderr = profile
        .get("maxStderrBytes")
        .and_then(Value::as_u64)
        .unwrap_or(262_144) as usize;

    let mut child = Command::new(command)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(input.as_bytes())?;
    }

    let pid = child.id();
    let start = SystemTime::now();
    // Poll-based timeout
    let deadline = start + Duration::from_millis(timeout_ms);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = child.wait_with_output()?;
                let stdout_bytes = output.stdout.len().min(max_stdout);
                let stderr_bytes = output.stderr.len().min(max_stderr);
                let stdout_truncated = output.stdout.len() > max_stdout;
                let stderr_truncated = output.stderr.len() > max_stderr;
                return Ok(json!({
                    "ok": status.success(),
                    "profile": profile_id,
                    "mode": "thin-forward",
                    "provider": "command",
                    "statusCode": status.code(),
                    "output": String::from_utf8_lossy(&output.stdout[..stdout_bytes]).to_string(),
                    "stderr": String::from_utf8_lossy(&output.stderr[..stderr_bytes]).to_string(),
                    "stdoutTruncated": stdout_truncated,
                    "stderrTruncated": stderr_truncated,
                    "pid": pid,
                    "planner": false,
                    "toolLoop": false,
                    "sessionHarness": false
                }));
            }
            Ok(None) => {
                if SystemTime::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Ok(json!({
                        "ok": false,
                        "profile": profile_id,
                        "mode": "thin-forward",
                        "provider": "command",
                        "status": "timeout",
                        "timeoutMs": timeout_ms,
                        "pid": pid,
                        "message": format!("Command timed out after {}ms", timeout_ms)
                    }));
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(anyhow!("failed to wait on child process: {}", e)),
        }
    }
}

fn forward_http(profile_id: &str, profile: &Value, input: &str) -> Result<Value> {
    let url = profile
        .get("url")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("http profile is missing url"))?;

    if !is_https_or_loopback_http_url(url) {
        return Ok(json!({
            "ok": false,
            "status": "invalid_profile",
            "profile": profile_id,
            "url": url,
            "message": "URL scheme must be https://, http://127.0.0.1, or http://localhost for thin forwarding"
        }));
    }

    let mut request = ureq::post(url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    for (key, value) in profile_headers_from_profile(profile)? {
        request = request.set(&key, &value);
    }
    let response = request.send_json(json!({
        "input": input,
        "profile": profile_id
    }))?;
    Ok(json!({
        "ok": true,
        "profile": profile_id,
        "mode": "thin-forward",
        "provider": "http",
        "statusCode": response.status(),
        "response": response.into_json::<Value>().unwrap_or_else(|_| json!({})),
        "planner": false,
        "toolLoop": false,
        "sessionHarness": false
    }))
}

fn provider_chat_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let provider_id = text_param(params, &["providerId", "provider", "id"])
        .or_else(|| text_param(params, &["profile", "profileId", "modelProfile"]))
        .and_then(|value| normalize_provider_id(&value))
        .ok_or_else(|| anyhow!("provider chat requires a supported provider"))?;
    let profile = find_provider_profile(data_dir, &provider_id, params)?;
    match provider_id.as_str() {
        "chatgpt" => provider_chat_openai_responses(&provider_id, &profile, params),
        "gemini" => provider_chat_gemini_interactions(&provider_id, &profile, params),
        "kimi" | "deepseek" => provider_chat_openai_compatible(&provider_id, &profile, params),
        _ => Ok(json!({
            "ok": false,
            "status": "unsupported_provider",
            "providerId": provider_id,
            "message": "Unsupported provider chat."
        })),
    }
}

fn provider_chat_openai_compatible(
    provider_id: &str,
    profile: &Value,
    params: &Value,
) -> Result<Value> {
    let url = profile
        .get("url")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| default_provider_url(provider_id))
        .ok_or_else(|| anyhow!("provider chat profile is missing url"))?;
    if !is_https_or_loopback_http_url(url) {
        return Ok(json!({
            "ok": false,
            "status": "invalid_profile",
            "providerId": provider_id,
            "message": "Provider URL must be https://, http://127.0.0.1, or http://localhost"
        }));
    }
    let headers = profile_headers_from_profile(profile)?;
    if !provider_has_credential_header(provider_id, &headers) {
        return Ok(json!({
            "ok": false,
            "status": "credential_missing",
            "providerId": provider_id,
            "message": format!("{} API Key is not configured on this computer.", provider_label(provider_id))
        }));
    }
    let messages = provider_chat_messages(params)?;
    let model = text_param(params, &["model", "modelId"])
        .or_else(|| text_param(profile, &["model", "modelId"]))
        .or_else(|| default_provider_model(provider_id).map(ToString::to_string))
        .ok_or_else(|| anyhow!("provider chat requires model"))?;
    let mut request = ureq::post(url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    for (key, value) in headers {
        request = request.set(&key, &value);
    }
    let mut body = json!({
        "model": model,
        "messages": messages,
        "stream": false
    });
    if provider_id == "kimi" {
        if let Some(thinking_type) = provider_chat_kimi_thinking_type(params) {
            body["thinking"] = json!({ "type": thinking_type });
        }
    } else if let Some(effort) = provider_chat_reasoning_effort(params) {
        body["reasoning_effort"] = json!(effort);
    }
    match request.send_json(body) {
        Ok(response) => {
            let status = response.status();
            let response_json = response.into_json::<Value>().unwrap_or_else(|_| json!({}));
            let output = provider_chat_response_text(&response_json);
            Ok(json!({
                "ok": !output.trim().is_empty(),
                "providerId": provider_id,
                "mode": "provider-chat",
                "statusCode": status,
                "model": model,
                "output": output,
                "content": output,
                "usage": response_json.get("usage").cloned().unwrap_or_else(|| json!({})),
                "response": response_json,
                "bodyRedacted": true
            }))
        }
        Err(ureq::Error::Status(status, response)) => Ok(json!({
            "ok": false,
            "providerId": provider_id,
            "mode": "provider-chat",
            "statusCode": status,
            "response": response.into_json::<Value>().unwrap_or_else(|_| json!({})),
            "bodyRedacted": true
        })),
        Err(error) => Ok(json!({
            "ok": false,
            "providerId": provider_id,
            "mode": "provider-chat",
            "status": "request_failed",
            "message": error.to_string(),
            "bodyRedacted": true
        })),
    }
}

fn provider_chat_openai_responses(
    provider_id: &str,
    profile: &Value,
    params: &Value,
) -> Result<Value> {
    let url = profile
        .get("url")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| default_provider_url(provider_id))
        .ok_or_else(|| anyhow!("provider chat profile is missing url"))?;
    if !is_https_or_loopback_http_url(url) {
        return Ok(json!({
            "ok": false,
            "status": "invalid_profile",
            "providerId": provider_id,
            "message": "Provider URL must be https://, http://127.0.0.1, or http://localhost"
        }));
    }
    let headers = profile_headers_from_profile(profile)?;
    if !provider_has_credential_header(provider_id, &headers) {
        return Ok(json!({
            "ok": false,
            "status": "credential_missing",
            "providerId": provider_id,
            "message": format!("{} API Key is not configured on this computer.", provider_label(provider_id))
        }));
    }
    let model = text_param(params, &["model", "modelId"])
        .or_else(|| text_param(profile, &["model", "modelId"]))
        .or_else(|| default_provider_model(provider_id).map(ToString::to_string))
        .ok_or_else(|| anyhow!("provider chat requires model"))?;
    let input = provider_chat_input_text(params)?;
    let mut request = ureq::post(url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    for (key, value) in headers {
        request = request.set(&key, &value);
    }
    let mut body = json!({
        "model": model,
        "input": input
    });
    if let Some(effort) = provider_chat_reasoning_effort(params) {
        body["reasoning"] = json!({ "effort": effort });
    }
    provider_chat_send_json(
        provider_id,
        "provider-chat",
        &model,
        request,
        body,
        |response| provider_openai_response_text(response),
    )
}

fn provider_chat_gemini_interactions(
    provider_id: &str,
    profile: &Value,
    params: &Value,
) -> Result<Value> {
    let url = profile
        .get("url")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| default_provider_url(provider_id))
        .ok_or_else(|| anyhow!("provider chat profile is missing url"))?;
    if !is_https_or_loopback_http_url(url) {
        return Ok(json!({
            "ok": false,
            "status": "invalid_profile",
            "providerId": provider_id,
            "message": "Provider URL must be https://, http://127.0.0.1, or http://localhost"
        }));
    }
    let headers = profile_headers_from_profile(profile)?;
    if !provider_has_credential_header(provider_id, &headers) {
        return Ok(json!({
            "ok": false,
            "status": "credential_missing",
            "providerId": provider_id,
            "message": format!("{} API Key is not configured on this computer.", provider_label(provider_id))
        }));
    }
    let model = text_param(params, &["model", "modelId"])
        .or_else(|| text_param(profile, &["model", "modelId"]))
        .or_else(|| default_provider_model(provider_id).map(ToString::to_string))
        .ok_or_else(|| anyhow!("provider chat requires model"))?;
    let input = provider_chat_input_text(params)?;
    let mut request = ureq::post(url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    for (key, value) in headers {
        request = request.set(&key, &value);
    }
    let mut body = json!({
        "model": model,
        "input": input
    });
    if let Some(thinking_level) = provider_chat_gemini_thinking_level(params) {
        body["generation_config"] = json!({ "thinking_level": thinking_level });
    }
    provider_chat_send_json(
        provider_id,
        "provider-chat",
        &model,
        request,
        body,
        |response| provider_gemini_response_text(response),
    )
}

fn find_provider_profile(data_dir: &Path, provider_id: &str, params: &Value) -> Result<Value> {
    let profiles = configured_model_profiles(data_dir)?;
    if let Some(explicit) = text_param(params, &["profile", "profileId", "modelProfile"]) {
        if let Some(profile) = profiles
            .iter()
            .find(|profile| profile.get("id").and_then(Value::as_str) == Some(explicit.as_str()))
        {
            return Ok(provider_profile_with_runtime_secret(
                profile.clone(),
                provider_id,
                params,
            ));
        }
    }
    if let Some(profile) = profiles.into_iter().find(|profile| {
        provider_profile_ids(profile)
            .iter()
            .any(|candidate| candidate == provider_id)
    }) {
        return Ok(provider_profile_with_runtime_secret(
            profile,
            provider_id,
            params,
        ));
    }
    if secret_param(params).is_some() {
        return Ok(transient_provider_profile(provider_id, params));
    }
    Err(anyhow!("provider profile not found: {}", provider_id))
}

fn provider_profile_ids(profile: &Value) -> Vec<String> {
    ["providerId", "provider", "id", "target"]
        .iter()
        .filter_map(|key| profile.get(*key).and_then(Value::as_str))
        .filter_map(normalize_provider_id)
        .collect()
}

fn provider_profile_with_runtime_secret(
    mut profile: Value,
    provider_id: &str,
    params: &Value,
) -> Value {
    let Some(api_key) = secret_param(params) else {
        return profile;
    };
    if let Some(object) = profile.as_object_mut() {
        let headers = object
            .entry("headers".to_string())
            .or_insert_with(|| json!({}));
        if !headers.is_object() {
            *headers = json!({});
        }
        if let Some(headers) = headers.as_object_mut() {
            let (key, value) = provider_auth_header(provider_id, &api_key);
            headers.insert(key.to_string(), json!(value));
        }
        object.insert("runtimeCredentialOverride".to_string(), json!(true));
    }
    profile
}

fn transient_provider_profile(provider_id: &str, params: &Value) -> Value {
    let mut profile = Map::new();
    profile.insert("id".to_string(), json!(provider_id));
    profile.insert("provider".to_string(), json!(provider_id));
    profile.insert("label".to_string(), json!(provider_label(provider_id)));
    profile.insert("source".to_string(), json!("runtime-params"));
    profile.insert("runtimeCredentialOverride".to_string(), json!(true));
    profile.insert(
        "url".to_string(),
        json!(
            text_param(params, &["url", "endpoint", "baseUrl"])
                .or_else(|| default_provider_url(provider_id).map(ToString::to_string))
                .unwrap_or_default()
        ),
    );
    if let Some(model) = text_param(params, &["model", "modelId"])
        .or_else(|| default_provider_model(provider_id).map(ToString::to_string))
    {
        profile.insert("model".to_string(), json!(model));
    }
    let headers = profile_headers(&json!({
        "provider": provider_id,
        "apiKey": secret_param(params).unwrap_or_default()
    }));
    profile.insert("headers".to_string(), Value::Object(headers));
    Value::Object(profile)
}

fn export_provider_credential_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let provider_id = text_param(
        params,
        &[
            "providerId",
            "provider",
            "profile",
            "profileId",
            "modelProfile",
        ],
    )
    .and_then(|value| normalize_provider_id(&value))
    .ok_or_else(|| anyhow!("provider credential export requires a supported provider"))?;
    let profile = find_provider_profile(data_dir, &provider_id, params)?;
    if provider_profile_credential_kind(&profile).starts_with("oauth") {
        let credential =
            configured_provider_oauth_credential(&provider_id, params).ok_or_else(|| {
                anyhow!(
                    "{} OAuth credential is not configured on this computer",
                    provider_label(&provider_id)
                )
            })?;
        let mut exported = credential.as_object().cloned().unwrap_or_default();
        exported.insert("ok".to_string(), json!(true));
        exported.insert("providerId".to_string(), json!(provider_id));
        exported.insert("credentialKind".to_string(), json!("oauth-pkce"));
        exported
            .entry("credentialHint".to_string())
            .or_insert_with(|| json!("OAuth"));
        exported
            .entry("source".to_string())
            .or_insert_with(|| json!("desktop-oauth"));
        exported.insert("bodyRedacted".to_string(), json!(true));
        return Ok(Value::Object(exported));
    }
    let credential =
        provider_credential_from_profile(&provider_id, &profile)?.ok_or_else(|| {
            anyhow!(
                "{} API Key is not configured on this computer",
                provider_label(&provider_id)
            )
        })?;
    Ok(json!({
        "ok": true,
        "providerId": provider_id,
        "credentialKind": "api-key",
        "apiKey": credential,
        "credential": credential,
        "credentialHint": credential_hint(&credential),
        "source": profile
            .get("source")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("desktop-model-profile"),
        "bodyRedacted": true
    }))
}

fn provider_credential_from_profile(provider_id: &str, profile: &Value) -> Result<Option<String>> {
    Ok(profile_headers_from_profile(profile)?
        .into_iter()
        .find_map(|(key, value)| {
            if provider_id == "gemini" && key.eq_ignore_ascii_case("x-goog-api-key") {
                return Some(value.trim().to_string()).filter(|value| !value.is_empty());
            }
            if key.eq_ignore_ascii_case("authorization") {
                return value
                    .trim()
                    .strip_prefix("Bearer ")
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToString::to_string);
            }
            None
        }))
}

fn provider_chat_messages(params: &Value) -> Result<Value> {
    if let Some(messages) = params.get("messages").filter(|value| value.is_array()) {
        let sanitized = messages
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|message| {
                let role = message
                    .get("role")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| matches!(*value, "system" | "user" | "assistant"))
                    .unwrap_or("user");
                let content = message
                    .get("content")
                    .or_else(|| message.get("text"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())?;
                Some(json!({"role": role, "content": content}))
            })
            .collect::<Vec<_>>();
        if !sanitized.is_empty() {
            return Ok(Value::Array(sanitized));
        }
    }
    let text = text_param(params, &["text", "message", "prompt", "input"])
        .ok_or_else(|| anyhow!("provider chat requires message text"))?;
    let mut messages = Vec::new();
    if let Some(system) = text_param(params, &["system", "systemPrompt", "systemInstruction"]) {
        messages.push(json!({ "role": "system", "content": system }));
    }
    messages.push(json!({ "role": "user", "content": text }));
    Ok(Value::Array(messages))
}

fn provider_chat_input_text(params: &Value) -> Result<String> {
    if let Some(text) = text_param(params, &["text", "message", "prompt", "input"]) {
        return Ok(text);
    }
    let messages = provider_chat_messages(params)?;
    let text = messages
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|message| {
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("user")
                .trim();
            let content = message
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            if content.is_empty() {
                None
            } else {
                Some(format!("{}: {}", role, content))
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    if text.trim().is_empty() {
        Err(anyhow!("provider chat requires message text"))
    } else {
        Ok(text)
    }
}

fn provider_chat_reasoning_effort(params: &Value) -> Option<String> {
    match text_param(params, &["reasoningEffort", "reasoning_effort"])?
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "low" => Some("low".to_string()),
        "medium" => Some("medium".to_string()),
        "high" => Some("high".to_string()),
        _ => None,
    }
}

fn provider_chat_gemini_thinking_level(params: &Value) -> Option<String> {
    match text_param(params, &["reasoningEffort", "reasoning_effort"])?
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "low" => Some("low".to_string()),
        "medium" => Some("medium".to_string()),
        "high" => Some("high".to_string()),
        _ => None,
    }
}

fn provider_chat_kimi_thinking_type(params: &Value) -> Option<String> {
    match text_param(params, &["reasoningEffort", "reasoning_effort"])?
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "enabled" => Some("enabled".to_string()),
        "disabled" => Some("disabled".to_string()),
        _ => None,
    }
}

fn provider_chat_send_json<F>(
    provider_id: &str,
    mode: &str,
    model: &str,
    request: ureq::Request,
    body: Value,
    extract_output: F,
) -> Result<Value>
where
    F: Fn(&Value) -> String,
{
    match request.send_json(body) {
        Ok(response) => {
            let status = response.status();
            let response_json = response.into_json::<Value>().unwrap_or_else(|_| json!({}));
            let output = extract_output(&response_json);
            Ok(json!({
                "ok": !output.trim().is_empty(),
                "providerId": provider_id,
                "mode": mode,
                "statusCode": status,
                "model": model,
                "output": output,
                "content": output,
                "usage": response_json.get("usage").cloned().unwrap_or_else(|| json!({})),
                "response": response_json,
                "bodyRedacted": true
            }))
        }
        Err(ureq::Error::Status(status, response)) => Ok(json!({
            "ok": false,
            "providerId": provider_id,
            "mode": mode,
            "statusCode": status,
            "response": response.into_json::<Value>().unwrap_or_else(|_| json!({})),
            "bodyRedacted": true
        })),
        Err(error) => Ok(json!({
            "ok": false,
            "providerId": provider_id,
            "mode": mode,
            "status": "request_failed",
            "message": error.to_string(),
            "bodyRedacted": true
        })),
    }
}

fn provider_chat_response_text(response: &Value) -> String {
    response
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn provider_openai_response_text(response: &Value) -> String {
    text_param(response, &["output_text", "outputText"])
        .or_else(|| provider_output_content_text(response))
        .or_else(|| {
            let choices_text = provider_chat_response_text(response);
            if choices_text.is_empty() {
                None
            } else {
                Some(choices_text)
            }
        })
        .unwrap_or_default()
}

fn provider_gemini_response_text(response: &Value) -> String {
    text_param(response, &["output_text", "outputText", "text"])
        .or_else(|| provider_output_content_text(response))
        .or_else(|| provider_interaction_steps_text(response))
        .or_else(|| provider_gemini_candidate_text(response))
        .unwrap_or_default()
}

fn provider_output_content_text(response: &Value) -> Option<String> {
    response
        .get("output")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find_map(|item| {
                item.get("content")
                    .and_then(Value::as_array)
                    .and_then(|content| {
                        content.iter().find_map(|part| {
                            text_param(part, &["text", "output_text", "outputText"])
                        })
                    })
                    .or_else(|| text_param(item, &["text", "output_text", "outputText"]))
            })
        })
        .filter(|value| !value.trim().is_empty())
}

fn provider_interaction_steps_text(response: &Value) -> Option<String> {
    response
        .get("steps")
        .and_then(Value::as_array)
        .map(|steps| {
            steps
                .iter()
                .filter(|step| {
                    step.get("type")
                        .and_then(Value::as_str)
                        .map(|value| value == "model_output")
                        .unwrap_or(true)
                })
                .flat_map(|step| {
                    step.get("content")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default()
                })
                .filter_map(|part| {
                    part.get("text")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(ToString::to_string)
                })
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|value| !value.trim().is_empty())
}

fn provider_gemini_candidate_text(response: &Value) -> Option<String> {
    response
        .get("candidates")
        .and_then(Value::as_array)
        .and_then(|candidates| candidates.first())
        .and_then(|candidate| candidate.get("content"))
        .and_then(|content| content.get("parts"))
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|value| !value.trim().is_empty())
}

fn find_profile(data_dir: &Path, profile_id: &str) -> Result<Value> {
    let document = read_profiles_document(data_dir)?;
    document
        .get("profiles")
        .and_then(Value::as_array)
        .and_then(|profiles| {
            profiles
                .iter()
                .find(|profile| profile.get("id").and_then(Value::as_str) == Some(profile_id))
                .cloned()
        })
        .ok_or_else(|| anyhow!("model profile not found: {}", profile_id))
}

fn read_profiles_document(data_dir: &Path) -> Result<Value> {
    let path = profiles_path(data_dir);
    if !path.exists() {
        return Ok(empty_profiles_document());
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(empty_profiles_document());
    }
    let mut document: Value = serde_json::from_str(&raw)?;
    if !document.is_object() {
        document = empty_profiles_document();
    }
    if document.get("profiles").and_then(Value::as_array).is_none() {
        document["profiles"] = json!([]);
    }
    Ok(document)
}

fn write_profiles_document(data_dir: &Path, value: &Value) -> Result<()> {
    let path = profiles_path(data_dir);
    atomic_write_private_text(
        &path,
        &format!("{}\n", serde_json::to_string_pretty(value)?),
    )
}

fn empty_profiles_document() -> Value {
    json!({
        "schemaVersion": PROFILE_SCHEMA_VERSION,
        "profiles": []
    })
}

fn profiles_path(data_dir: &Path) -> PathBuf {
    data_dir.join(FORWARDING_DIR).join(PROFILES_FILE)
}

fn profile_id(params: &Value) -> Result<String> {
    params
        .get("profile")
        .or_else(|| params.get("id"))
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("model profile requires --profile <profile-id>"))
}

fn forward_input(params: &Value) -> Result<String> {
    params
        .get("text")
        .or_else(|| params.get("input"))
        .or_else(|| params.get("prompt"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("forward requires --text <input>"))
}

fn profile_args(params: &Value) -> Option<Value> {
    params.get("args").and_then(|value| {
        if value.is_array() {
            Some(value.clone())
        } else {
            value
                .as_str()
                .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
                .filter(Value::is_array)
        }
    })
}

fn default_provider_url(provider_id: &str) -> Option<&'static str> {
    match provider_id {
        "chatgpt" => Some(DEFAULT_CHATGPT_RESPONSES_URL),
        "gemini" => Some(DEFAULT_GEMINI_INTERACTIONS_URL),
        "kimi" => Some(DEFAULT_KIMI_CHAT_URL),
        "deepseek" => Some(DEFAULT_DEEPSEEK_CHAT_URL),
        _ => None,
    }
}

fn default_provider_model(provider_id: &str) -> Option<&'static str> {
    match provider_id {
        "chatgpt" => Some(DEFAULT_CHATGPT_MODEL),
        "gemini" => Some(DEFAULT_GEMINI_MODEL),
        "kimi" => Some(DEFAULT_KIMI_MODEL),
        "deepseek" => Some(DEFAULT_DEEPSEEK_MODEL),
        _ => None,
    }
}

fn provider_label(provider_id: &str) -> &'static str {
    match provider_id {
        "chatgpt" => "ChatGPT",
        "gemini" => "Gemini",
        "kimi" => "Kimi",
        "deepseek" => "DeepSeek",
        _ => "Provider",
    }
}

fn is_supported_provider(provider_id: &str) -> bool {
    default_provider_url(provider_id).is_some()
}

fn provider_auth_header(provider_id: &str, api_key: &str) -> (&'static str, String) {
    if provider_id == "gemini" {
        ("x-goog-api-key", api_key.to_string())
    } else {
        ("Authorization", format!("Bearer {}", api_key))
    }
}

fn provider_auth_header_for_profile(provider_id: &str, api_key: &str) -> (&'static str, String) {
    normalize_provider_id(provider_id)
        .map(|provider_id| provider_auth_header(&provider_id, api_key))
        .unwrap_or(("X-LicoLite-Api-Key", api_key.to_string()))
}

fn is_provider_credential_header(key: &str) -> bool {
    matches!(
        key.trim().to_ascii_lowercase().as_str(),
        "authorization" | "x-goog-api-key" | "x-licolite-api-key" | "api-key" | "apikey"
    )
}

fn remove_provider_credential_headers(headers: &mut Map<String, Value>) {
    let keys = headers
        .keys()
        .filter(|key| is_provider_credential_header(key))
        .cloned()
        .collect::<Vec<_>>();
    for key in keys {
        headers.remove(&key);
    }
}

fn provider_has_credential_header(provider_id: &str, headers: &[(String, String)]) -> bool {
    headers.iter().any(|(key, value)| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return false;
        }
        if provider_id == "gemini" && key.eq_ignore_ascii_case("x-goog-api-key") {
            return true;
        }
        key.eq_ignore_ascii_case("authorization") && trimmed.starts_with("Bearer ")
    })
}

fn profile_headers(params: &Value) -> Map<String, Value> {
    let mut headers = headers_param(params);
    if let Some(api_key) = secret_param(params) {
        let provider = params
            .get("provider")
            .and_then(Value::as_str)
            .or_else(|| params.get("providerId").and_then(Value::as_str))
            .or_else(|| params.get("profile").and_then(Value::as_str))
            .or_else(|| params.get("profileId").and_then(Value::as_str))
            .or_else(|| params.get("id").and_then(Value::as_str))
            .or_else(|| params.get("modelProfile").and_then(Value::as_str))
            .or_else(|| params.get("target").and_then(Value::as_str))
            .or_else(|| {
                params
                    .get("positionals")
                    .and_then(Value::as_array)
                    .and_then(|items| items.first())
                    .and_then(Value::as_str)
            })
            .and_then(normalize_provider_id);
        if let Some(provider_id) = provider {
            let (key, value) = provider_auth_header(&provider_id, &api_key);
            headers.insert(key.to_string(), json!(value));
        } else {
            headers.insert("X-LicoLite-Api-Key".to_string(), json!(api_key));
        }
    }
    headers
}

fn credential_hint(value: &str) -> String {
    let compact = value.split_whitespace().collect::<String>();
    if compact.len() <= 4 {
        "****".to_string()
    } else {
        format!("**** {}", &compact[compact.len() - 4..])
    }
}

fn provider_credential_handle(profile_id: &str, provider_id: &str) -> Result<SecretStoreHandle> {
    let mut hasher = Sha256::new();
    hasher.update(profile_id.as_bytes());
    hasher.update([0]);
    hasher.update(provider_id.as_bytes());
    let digest = hasher.finalize();
    let key = format!("{}-{}", provider_id.trim(), hex_lower(&digest));
    SecretStoreHandle::new(
        format!(
            "{}:{}",
            PROVIDER_CREDENTIAL_ACCOUNT_PREFIX, PROVIDER_CREDENTIAL_HANDLE_NAMESPACE
        ),
        key,
    )
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

fn provider_credential_ref_json(backend: &str, handle: &SecretStoreHandle, hint: &str) -> Value {
    json!({
        "schemaVersion": PROVIDER_CREDENTIAL_REF_SCHEMA_VERSION,
        "kind": "platform-secret-store",
        "backend": backend,
        "service": PROVIDER_CREDENTIAL_SECRET_SERVICE,
        "namespace": handle.namespace(),
        "key": handle.key(),
        "credentialHint": hint,
        "rawSecretMaterialIncluded": false
    })
}

#[cfg(test)]
fn provider_credential_test_store_key(handle: &SecretStoreHandle) -> String {
    format!("{}:{}", handle.namespace(), handle.key())
}

fn provider_credential_ref_handle(profile: &Value) -> Result<Option<SecretStoreHandle>> {
    let Some(reference) = profile.get("providerCredentialRef") else {
        return Ok(None);
    };
    if reference
        .get("schemaVersion")
        .and_then(Value::as_str)
        .unwrap_or_default()
        != PROVIDER_CREDENTIAL_REF_SCHEMA_VERSION
        || reference
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or_default()
            != "platform-secret-store"
    {
        return Err(anyhow!("provider credential reference is malformed"));
    }
    let namespace = text_param(reference, &["namespace"])
        .ok_or_else(|| anyhow!("provider credential reference is missing namespace"))?;
    let key = text_param(reference, &["key"])
        .ok_or_else(|| anyhow!("provider credential reference is missing key"))?;
    Ok(Some(SecretStoreHandle::new(namespace, key)?))
}

#[cfg(not(test))]
fn provider_credential_secret_store() -> PlatformSecretStore {
    PlatformSecretStore::new(
        PROVIDER_CREDENTIAL_SECRET_SERVICE,
        PROVIDER_CREDENTIAL_ACCOUNT_PREFIX,
    )
}

#[cfg(not(test))]
fn store_provider_credential_secret(
    profile_id: &str,
    provider_id: &str,
    secret: &str,
) -> Result<Value> {
    let store = provider_credential_secret_store();
    if !store.supported() {
        return Err(anyhow!(
            "native provider credential secret store is unsupported"
        ));
    }
    let handle = provider_credential_handle(profile_id, provider_id)?;
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Lico Arc provider credential keyring write",
        1,
    ))?;
    store.set_secret_with_session(&session, &handle, secret)?;
    Ok(provider_credential_ref_json(
        store.backend(),
        &handle,
        &credential_hint(secret),
    ))
}

#[cfg(test)]
fn store_provider_credential_secret(
    profile_id: &str,
    provider_id: &str,
    secret: &str,
) -> Result<Value> {
    let handle = provider_credential_handle(profile_id, provider_id)?;
    TEST_PROVIDER_CREDENTIAL_SECRETS.with(|slot| {
        slot.borrow_mut().insert(
            provider_credential_test_store_key(&handle),
            secret.trim().to_string(),
        );
    });
    Ok(provider_credential_ref_json(
        "test-memory-secret-store",
        &handle,
        &credential_hint(secret),
    ))
}

#[cfg(not(test))]
fn read_provider_credential_secret(profile: &Value) -> Result<Option<String>> {
    let Some(handle) = provider_credential_ref_handle(profile)? else {
        return Ok(None);
    };
    let store = provider_credential_secret_store();
    if !store.supported() {
        return Err(anyhow!(
            "native provider credential secret store is unsupported"
        ));
    }
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Lico Arc provider credential keyring read",
        1,
    ))?;
    store.get_secret_with_session(&session, &handle)
}

#[cfg(test)]
fn read_provider_credential_secret(profile: &Value) -> Result<Option<String>> {
    let Some(handle) = provider_credential_ref_handle(profile)? else {
        return Ok(None);
    };
    Ok(TEST_PROVIDER_CREDENTIAL_SECRETS.with(|slot| {
        slot.borrow()
            .get(&provider_credential_test_store_key(&handle))
            .cloned()
    }))
}

#[cfg(not(test))]
fn ensure_provider_credential_secret_deleted(profile: &Value) -> Result<()> {
    let handle = provider_credential_ref_handle(profile)?
        .ok_or_else(|| anyhow!("model profile has no native provider credential reference"))?;
    let store = provider_credential_secret_store();
    if !store.supported() {
        return Err(anyhow!(
            "native provider credential secret store is unsupported"
        ));
    }
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Lico Arc provider credential keyring delete",
        2,
    ))?;
    store.delete_secret_with_session(&session, &handle)?;
    if store.get_secret_with_session(&session, &handle)?.is_some() {
        return Err(anyhow!(
            "native provider credential remained present after deletion"
        ));
    }
    Ok(())
}

#[cfg(test)]
fn ensure_provider_credential_secret_deleted(profile: &Value) -> Result<()> {
    let handle = provider_credential_ref_handle(profile)?
        .ok_or_else(|| anyhow!("model profile has no native provider credential reference"))?;
    let key = provider_credential_test_store_key(&handle);
    let removed = TEST_PROVIDER_CREDENTIAL_SECRETS.with(|slot| slot.borrow_mut().remove(&key));
    if removed.is_none() {
        return Err(anyhow!("native provider credential was not present"));
    }
    let remains = TEST_PROVIDER_CREDENTIAL_SECRETS.with(|slot| slot.borrow().contains_key(&key));
    if remains {
        return Err(anyhow!(
            "native provider credential remained present after deletion"
        ));
    }
    Ok(())
}

fn raw_profile_credential_headers_allowed(profile: &Value) -> bool {
    profile
        .get("runtimeCredentialOverride")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || profile.get("source").and_then(Value::as_str) == Some("desktop-environment")
}

fn profile_headers_from_profile(profile: &Value) -> Result<Vec<(String, String)>> {
    let allow_raw_credentials = raw_profile_credential_headers_allowed(profile);
    let mut headers: Vec<(String, String)> = profile
        .get("headers")
        .and_then(Value::as_object)
        .map(|headers| {
            headers
                .iter()
                .filter_map(|(key, value)| {
                    value
                        .as_str()
                        .filter(|header_value| !header_value.trim().is_empty())
                        .map(|header_value| (key.clone(), header_value.trim().to_string()))
                })
                .filter(|(key, _)| allow_raw_credentials || !is_provider_credential_header(key))
                .collect()
        })
        .unwrap_or_default();
    if let Some(secret) = read_provider_credential_secret(profile)? {
        let provider_id = profile
            .get("provider")
            .and_then(Value::as_str)
            .or_else(|| profile.get("providerId").and_then(Value::as_str))
            .or_else(|| profile.get("id").and_then(Value::as_str))
            .unwrap_or("http");
        let (key, value) = provider_auth_header_for_profile(provider_id, &secret);
        headers.retain(|(existing, _)| !existing.eq_ignore_ascii_case(key));
        headers.push((key.to_string(), value));
    }
    Ok(headers)
}

fn headers_param(params: &Value) -> Map<String, Value> {
    if let Some(headers) = params.get("headers").and_then(Value::as_object) {
        return headers.clone();
    }
    params
        .get("headers")
        .and_then(Value::as_str)
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

fn secret_param(params: &Value) -> Option<String> {
    let explicit = params
        .get("apiKey")
        .or_else(|| params.get("api_key"))
        .or_else(|| params.get("credential"))
        .or_else(|| params.get("licoApiKey"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    explicit.or_else(|| secret_env_param(params))
}

fn secret_env_param(params: &Value) -> Option<String> {
    let name = params
        .get("apiKeyEnv")
        .or_else(|| params.get("api_key_env"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| {
            !value.is_empty()
                && value
                    .chars()
                    .all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_')
        })?;
    env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn configured_model_profiles(data_dir: &Path) -> Result<Vec<Value>> {
    let document = read_profiles_document(data_dir)?;
    let mut profiles = document
        .get("profiles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    append_configured_api_key_profiles(&mut profiles);
    append_configured_oauth_profiles(&mut profiles);
    Ok(profiles)
}

fn append_configured_api_key_profiles(profiles: &mut Vec<Value>) {
    for provider_id in ["deepseek", "gemini", "kimi"] {
        let has_provider_profile = profiles.iter().any(|profile| {
            provider_profile_ids(profile)
                .iter()
                .any(|candidate| candidate == provider_id)
        });
        if has_provider_profile {
            continue;
        }
        let Some(api_key) = configured_provider_api_key(provider_id) else {
            continue;
        };
        let Some(url) = default_provider_url(provider_id) else {
            continue;
        };
        let Some(model) = default_provider_model(provider_id) else {
            continue;
        };
        let (header, value) = provider_auth_header(provider_id, &api_key);
        let mut headers = Map::new();
        headers.insert(header.to_string(), json!(value));
        profiles.push(json!({
            "id": provider_id,
            "provider": provider_id,
            "label": provider_label(provider_id),
            "url": url,
            "model": model,
            "headers": Value::Object(headers),
            "source": "desktop-environment"
        }));
    }
}

fn append_configured_oauth_profiles(profiles: &mut Vec<Value>) {
    for provider_id in ["gemini"] {
        let profile_id = format!("{provider_id}-oauth");
        if profiles
            .iter()
            .any(|profile| profile.get("id").and_then(Value::as_str) == Some(profile_id.as_str()))
        {
            continue;
        }
        if configured_provider_oauth_credential(provider_id, &json!({})).is_none() {
            continue;
        }
        let Some(model) = default_provider_model(provider_id) else {
            continue;
        };
        profiles.push(json!({
            "id": profile_id,
            "provider": provider_id,
            "label": format!("{} OAuth", provider_label(provider_id)),
            "model": model,
            "credentialKind": "oauth-pkce",
            "credentialPresent": true,
            "source": format!("{provider_id}-cli-oauth")
        }));
    }
}

fn configured_provider_api_key(provider_id: &str) -> Option<String> {
    #[cfg(test)]
    {
        return test_configured_provider_api_key(provider_id);
    }

    #[cfg(not(test))]
    {
        for name in configured_provider_api_key_env_names(provider_id) {
            if let Ok(value) = env::var(name) {
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
        configured_provider_api_key_from_launchctl(provider_id)
    }
}

#[cfg(not(test))]
fn configured_provider_api_key_env_names(provider_id: &str) -> &'static [&'static str] {
    match provider_id {
        "deepseek" => &["DEEPSEEK_API_KEY", "CODEX_DEEPSEEK_API_KEY"],
        "gemini" => &[
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "GOOGLE_GEMINI_API_KEY",
            "GOOGLE_GENAI_API_KEY",
        ],
        "kimi" => &["KIMI_API_KEY", "MOONSHOT_API_KEY"],
        _ => &[],
    }
}

#[cfg(all(not(test), target_os = "macos"))]
fn configured_provider_api_key_from_launchctl(provider_id: &str) -> Option<String> {
    for name in configured_provider_api_key_env_names(provider_id) {
        let output = Command::new("launchctl").arg("getenv").arg(name).output();
        let Ok(output) = output else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let value = String::from_utf8_lossy(&output.stdout);
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    None
}

#[cfg(all(not(test), not(target_os = "macos")))]
fn configured_provider_api_key_from_launchctl(_provider_id: &str) -> Option<String> {
    None
}

#[cfg(test)]
fn test_configured_provider_api_key(provider_id: &str) -> Option<String> {
    TEST_CONFIGURED_API_KEYS.with(|value| value.borrow().get(provider_id).cloned())
}

fn provider_profile_credential_kind(profile: &Value) -> String {
    profile
        .get("credentialKind")
        .or_else(|| profile.get("authKind"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("api-key")
        .to_lowercase()
}

fn configured_provider_oauth_credential(provider_id: &str, params: &Value) -> Option<Value> {
    #[cfg(test)]
    {
        if let Some(value) = configured_provider_oauth_credential_from_path(provider_id, params) {
            return Some(value);
        }
        return TEST_CONFIGURED_OAUTH_CREDENTIALS
            .with(|value| value.borrow().get(provider_id).cloned());
    }

    #[cfg(not(test))]
    {
        configured_provider_oauth_credential_from_path(provider_id, params)
            .or_else(|| configured_provider_oauth_credential_from_default_paths(provider_id))
    }
}

fn configured_provider_oauth_credential_from_path(
    provider_id: &str,
    params: &Value,
) -> Option<Value> {
    let path = text_param(
        params,
        &["oauthCredentialPath", "credentialPath", "credentialsPath"],
    )?;
    configured_provider_oauth_credential_from_file(provider_id, &PathBuf::from(path))
}

#[cfg(not(test))]
fn configured_provider_oauth_credential_from_default_paths(provider_id: &str) -> Option<Value> {
    if provider_id != "gemini" {
        return None;
    }
    let home = env::var("HOME")
        .ok()
        .filter(|value| !value.trim().is_empty())?;
    let home = PathBuf::from(home);
    for path in [
        home.join(".gemini").join("oauth_creds.json"),
        home.join(".gemini")
            .join("antigravity-cli")
            .join("antigravity-oauth-token"),
    ] {
        if let Some(credential) = configured_provider_oauth_credential_from_file(provider_id, &path)
        {
            return Some(credential);
        }
    }
    None
}

fn configured_provider_oauth_credential_from_file(provider_id: &str, path: &Path) -> Option<Value> {
    if provider_id != "gemini" {
        return None;
    }
    let raw = fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    let token = value
        .get("token")
        .filter(|nested| nested.is_object())
        .unwrap_or(&value);
    oauth_credential_from_token_json(provider_id, token, "gemini-cli-oauth")
}

fn oauth_credential_from_token_json(
    provider_id: &str,
    token: &Value,
    source: &str,
) -> Option<Value> {
    let access_token = text_param(token, &["accessToken", "access_token"])?;
    let refresh_token = text_param(token, &["refreshToken", "refresh_token"]).unwrap_or_default();
    if access_token.trim().is_empty() || refresh_token.trim().is_empty() {
        return None;
    }
    let id_token = text_param(token, &["idToken", "id_token"]).unwrap_or_default();
    let expires_at = token
        .get("expiresAtEpochMillis")
        .or_else(|| token.get("expiry_date"))
        .and_then(Value::as_i64)
        .unwrap_or_default();
    let mut credential = Map::new();
    credential.insert("providerId".to_string(), json!(provider_id));
    credential.insert("credentialKind".to_string(), json!("oauth-pkce"));
    credential.insert("accessToken".to_string(), json!(access_token));
    credential.insert("refreshToken".to_string(), json!(refresh_token));
    if !id_token.trim().is_empty() {
        credential.insert("idToken".to_string(), json!(id_token));
    }
    if expires_at > 0 {
        credential.insert("expiresAtEpochMillis".to_string(), json!(expires_at));
    }
    credential.insert("credentialHint".to_string(), json!("OAuth"));
    credential.insert("source".to_string(), json!(source));
    Some(Value::Object(credential))
}

#[cfg(test)]
struct TestConfiguredApiKeyGuard {
    provider_id: String,
    previous: Option<String>,
}

#[cfg(test)]
struct TestConfiguredOAuthCredentialGuard {
    provider_id: String,
    previous: Option<Value>,
}

#[cfg(test)]
impl TestConfiguredOAuthCredentialGuard {
    fn set(provider_id: &str, value: Value) -> Self {
        let provider_id = provider_id.to_string();
        let previous = TEST_CONFIGURED_OAUTH_CREDENTIALS
            .with(|slot| slot.borrow_mut().insert(provider_id.clone(), value));
        Self {
            provider_id,
            previous,
        }
    }
}

#[cfg(test)]
impl Drop for TestConfiguredOAuthCredentialGuard {
    fn drop(&mut self) {
        let previous = self.previous.take();
        TEST_CONFIGURED_OAUTH_CREDENTIALS.with(|slot| {
            let mut slot = slot.borrow_mut();
            if let Some(previous) = previous {
                slot.insert(self.provider_id.clone(), previous);
            } else {
                slot.remove(&self.provider_id);
            }
        });
    }
}

#[cfg(test)]
impl TestConfiguredApiKeyGuard {
    fn set(provider_id: &str, value: &str) -> Self {
        let provider_id = provider_id.to_string();
        let previous = TEST_CONFIGURED_API_KEYS.with(|slot| {
            slot.borrow_mut()
                .insert(provider_id.clone(), value.to_string())
        });
        Self {
            provider_id,
            previous,
        }
    }
}

#[cfg(test)]
impl Drop for TestConfiguredApiKeyGuard {
    fn drop(&mut self) {
        let previous = self.previous.take();
        TEST_CONFIGURED_API_KEYS.with(|slot| {
            let mut slot = slot.borrow_mut();
            if let Some(previous) = previous {
                slot.insert(self.provider_id.clone(), previous);
            } else {
                slot.remove(&self.provider_id);
            }
        });
    }
}

fn text_param(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .filter_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn normalize_provider_id(value: &str) -> Option<String> {
    match value.trim().to_lowercase().replace('_', "-").as_str() {
        "chatgpt" | "chat-gpt" | "openai" | "gpt" => Some("chatgpt".to_string()),
        "gemini" | "google" | "google-gemini" => Some("gemini".to_string()),
        "kimi" | "moonshot" | "moonshot-ai" => Some("kimi".to_string()),
        "deepseek" | "deep-seek" => Some("deepseek".to_string()),
        _ => None,
    }
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc::channel;
    use std::time::Duration;

    fn stdin_echo_command() -> (&'static str, Option<Value>) {
        #[cfg(windows)]
        {
            ("cmd.exe", Some(json!(["/C", "more"])))
        }
        #[cfg(not(windows))]
        {
            ("/bin/cat", None)
        }
    }

    fn stdin_echo_profile(profile: &str) -> Value {
        let (command, args) = stdin_echo_command();
        let mut value = json!({
            "profile": profile,
            "label": profile,
            "command": command
        });
        if let Some(args) = args {
            value["args"] = args;
        }
        value
    }

    fn normalized_output(value: &Value) -> String {
        value
            .as_str()
            .unwrap_or_default()
            .trim_end_matches(&['\r', '\n'][..])
            .to_string()
    }

    fn provider_json_server(
        response_body: &'static [u8],
    ) -> (
        String,
        std::thread::JoinHandle<()>,
        std::sync::mpsc::Receiver<(Vec<String>, Value)>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (sender, receiver) = channel::<(Vec<String>, Value)>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut headers = Vec::new();
            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    headers.push(format!(
                        "{}:{}",
                        key.trim().to_ascii_lowercase(),
                        value.trim().to_string()
                    ));
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            let request: Value = serde_json::from_slice(&body).unwrap();
            sender.send((headers, request)).unwrap();
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                response_body.len(),
                String::from_utf8_lossy(response_body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        });
        (url, server_thread, receiver)
    }

    #[test]
    fn thin_forwarding_requires_profile() {
        let dir = temp_test_dir("requires-profile");
        let error = forward_in(&dir, &json!({"text": "hello"})).unwrap_err();
        assert!(error.to_string().contains("--profile"));
    }

    #[test]
    fn thin_forwarding_command_profile_round_trip() {
        let dir = temp_test_dir("command-profile");
        save_model_profile_in(&dir, &stdin_echo_profile("cat")).unwrap();

        let result = forward_in(
            &dir,
            &json!({
                "profile": "cat",
                "text": "thin forwarding only"
            }),
        )
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(normalized_output(&result["output"]), "thin forwarding only");
        assert_eq!(result["planner"], false);
        assert_eq!(result["toolLoop"], false);
        assert_eq!(result["sessionHarness"], false);
    }

    #[test]
    fn thin_forwarding_profile_store_omits_agent_runtime_fields() {
        let dir = temp_test_dir("store");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "remote",
                "url": "http://127.0.0.1:7228/forward",
                "apiKey": concat!("profile-store", "-plaintext-canary")
            }),
        )
        .unwrap();

        let raw = fs::read_to_string(profiles_path(&dir)).unwrap();
        assert!(raw.contains("\"profiles\""));
        assert!(raw.contains("\"providerCredentialRef\""));
        assert!(raw.contains("\"credentialStorage\": \"platform-secret-store\""));
        assert!(!raw.contains("\"X-LicoLite-Api-Key\""));
        assert!(!raw.contains("profile-store-plaintext-canary"));
        assert!(!raw.contains("agent.invoke"));
        assert!(!raw.contains("customHttpAdapter"));
        assert!(!raw.contains("knowledge.agent.answer"));
    }

    #[test]
    fn thin_forwarding_rejects_missing_or_unknown_provider() {
        let dir = temp_test_dir("bad-provider");
        let missing_provider =
            save_model_profile_in(&dir, &json!({"profile": "missing"})).unwrap_err();
        assert!(
            missing_provider
                .to_string()
                .contains("--command, --url, or a supported provider --api-key")
        );

        let invalid_provider = save_model_profile_in(
            &dir,
            &json!({
                "profile": "invalid",
                "provider": "ftp"
            }),
        )
        .unwrap_err();
        assert!(
            invalid_provider
                .to_string()
                .contains("unsupported forwarding provider")
        );
    }

    #[test]
    fn thin_forwarding_inputs_fallback_to_positionals_and_prompt() {
        let mut args = json!({"positionals": ["position", "input"]});
        assert_eq!(forward_input(&args).unwrap(), "position input");
        args = json!({"prompt": "from-prompt"});
        assert_eq!(forward_input(&args).unwrap(), "from-prompt");
        args = json!({"input": "from-input"});
        assert_eq!(forward_input(&args).unwrap(), "from-input");
    }

    #[test]
    fn thin_forwarding_command_profile_requires_command_field() {
        let dir = temp_test_dir("missing-command");
        let profile = json!({
            "profiles": [
                {"id":"bad-command","provider":"command"}
            ]
        });
        fs::create_dir_all(dir.join("model-forwarding")).unwrap();
        fs::write(profiles_path(&dir), format!("{}\n", profile.to_string())).unwrap();
        let error =
            forward_in(&dir, &json!({"profile": "bad-command", "text": "oops"})).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("command profile is missing command")
        );
    }

    #[test]
    fn thin_forwarding_prefers_model_profile_alias() {
        let dir = temp_test_dir("model-profile-alias");
        save_model_profile_in(&dir, &stdin_echo_profile("cat")).unwrap();

        let result = forward_in(
            &dir,
            &json!({
                "modelProfile": "cat",
                "text": "aliased profile",
            }),
        )
        .unwrap();
        assert_eq!(result["profile"], "cat");
        assert_eq!(result["provider"], "command");
        assert_eq!(normalized_output(&result["output"]), "aliased profile");
    }

    #[test]
    fn thin_forwarding_profile_id_from_positionals_and_args_parsing() {
        assert_eq!(
            profile_id(&json!({"positionals": ["from-pos"]})).unwrap(),
            "from-pos"
        );
        assert_eq!(
            profile_args(&json!({"args": "[\"--flag\",\"value\"]"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(profile_args(&json!({"args": "not-json"})).is_none());
    }

    #[test]
    fn thin_forwarding_reads_and_normalizes_profile_documents() {
        let dir = temp_test_dir("normalized-document");
        let path = profiles_path(&dir);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "true").unwrap();

        let document = read_profiles_document(&dir).unwrap();
        assert_eq!(
            document,
            json!({"schemaVersion": PROFILE_SCHEMA_VERSION, "profiles": []})
        );
    }

    #[test]
    fn thin_forwarding_http_profile_forwards_request_and_applies_headers() {
        let dir = temp_test_dir("http-forward");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = listener.local_addr().unwrap();
        let (sender, receiver) = channel::<Vec<String>>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut headers = Vec::new();
            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    headers.push(format!(
                        "{}:{}",
                        key.trim().to_ascii_lowercase(),
                        value.trim().to_ascii_lowercase()
                    ));
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            let body = String::from_utf8(body).unwrap_or_else(|_| String::new());
            let request: Value = serde_json::from_str(&body).unwrap_or_else(|_| json!({}));
            assert_eq!(request["input"], "hello");
            assert_eq!(request["profile"], "remote");

            sender.send(headers).unwrap();
            let body = b"{\"ok\":true,\"mode\":\"thin\"}";
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_millis(100)))
                .unwrap();
        });

        save_model_profile_in(
            &dir,
            &json!({
                "profile": "remote",
                "url": format!("http://{}", server),
                "apiKey": "k-1",
                "headers": {"X-Extra-Header": "enabled", "count": 1},
            }),
        )
        .unwrap();
        let result = forward_in(&dir, &json!({"profile": "remote", "text": "hello"})).unwrap();
        server_thread.join().unwrap();
        let headers = receiver.recv().unwrap_or_default();
        assert_eq!(result["provider"], "http");
        assert_eq!(result["response"]["ok"], true);
        assert!(
            headers
                .iter()
                .any(|header| header == "accept:application/json")
        );
        assert!(
            headers
                .iter()
                .any(|header| header == "content-type:application/json")
        );
        assert!(
            headers
                .iter()
                .any(|header| header == "x-licolite-api-key:k-1")
        );
        assert!(
            headers
                .iter()
                .any(|header| header == "x-extra-header:enabled")
        );
    }

    #[test]
    fn deepseek_profile_defaults_to_bearer_auth_and_masks_secret() {
        let dir = temp_test_dir("deepseek-profile");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "deepseek",
                "apiKey": concat!("deepseek", "-secret"),
            }),
        )
        .unwrap();

        let raw = fs::read_to_string(profiles_path(&dir)).unwrap();
        assert!(raw.contains(DEFAULT_DEEPSEEK_CHAT_URL));
        assert!(raw.contains("\"providerCredentialRef\""));
        assert!(raw.contains("\"credentialStorage\": \"platform-secret-store\""));
        assert!(!raw.contains("\"Authorization\""));
        assert!(!raw.contains("Bearer deepseek-secret"));
        assert!(!raw.contains("deepseek-secret"));

        let listed = list_model_profiles_in(&dir).unwrap();
        assert_eq!(listed["profiles"][0]["credentialPresent"], true);
        assert_eq!(
            listed["profiles"][0]["credentialStorage"].as_str(),
            Some("platform-secret-store")
        );
        assert!(!listed.to_string().contains("deepseek-secret"));
    }

    #[test]
    fn provider_chat_deepseek_posts_chat_completions_and_parses_reply() {
        let dir = temp_test_dir("deepseek-chat");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = listener.local_addr().unwrap();
        let (sender, receiver) = channel::<(Vec<String>, Value)>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut headers = Vec::new();
            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    headers.push(format!(
                        "{}:{}",
                        key.trim().to_ascii_lowercase(),
                        value.trim().to_string()
                    ));
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            let request: Value = serde_json::from_slice(&body).unwrap();
            sender.send((headers, request)).unwrap();
            let body = br#"{"choices":[{"message":{"role":"assistant","content":"DeepSeek reply"}}],"usage":{"total_tokens":12}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        });

        save_model_profile_in(
            &dir,
            &json!({
                "profile": "deepseek",
                "provider": "deepseek",
                "url": format!("http://{}", server),
                "apiKey": concat!("deepseek", "-secret"),
            }),
        )
        .unwrap();
        let result =
            provider_chat_in(&dir, &json!({"providerId": "deepseek", "text": "hello"})).unwrap();
        server_thread.join().unwrap();
        let (headers, request) = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "DeepSeek reply");
        assert_eq!(result["usage"]["total_tokens"], 12);
        assert_eq!(request["model"], DEFAULT_DEEPSEEK_MODEL);
        assert_eq!(request["messages"][0]["role"], "user");
        assert_eq!(request["messages"][0]["content"], "hello");
        assert!(
            headers
                .iter()
                .any(|header| header == "authorization:Bearer deepseek-secret")
        );
    }

    #[test]
    fn provider_chat_gemini_maps_reasoning_effort_to_thinking_level() {
        let dir = temp_test_dir("gemini-thinking-level");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = listener.local_addr().unwrap();
        let (sender, receiver) = channel::<Value>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            sender.send(serde_json::from_slice(&body).unwrap()).unwrap();
            let body = br#"{"output_text":"Gemini reply"}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        });

        save_model_profile_in(
            &dir,
            &json!({
                "profile": "gemini",
                "provider": "gemini",
                "url": format!("http://{}", server),
                "apiKey": concat!("gemini", "-secret"),
            }),
        )
        .unwrap();
        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "gemini",
                "text": "hello",
                "reasoningEffort": "medium"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let request = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "Gemini reply");
        assert_eq!(request["generation_config"]["thinking_level"], "medium");
    }

    #[test]
    fn provider_chat_kimi_maps_reasoning_effort_to_thinking_type() {
        let dir = temp_test_dir("kimi-thinking-type");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = listener.local_addr().unwrap();
        let (sender, receiver) = channel::<Value>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            sender.send(serde_json::from_slice(&body).unwrap()).unwrap();
            let body = br#"{"choices":[{"message":{"role":"assistant","content":"Kimi reply"}}]}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        });

        save_model_profile_in(
            &dir,
            &json!({
                "profile": "kimi",
                "provider": "kimi",
                "url": format!("http://{}", server),
                "apiKey": "kimi-secret",
            }),
        )
        .unwrap();
        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "kimi",
                "text": "hello",
                "reasoningEffort": "disabled"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let request = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "Kimi reply");
        assert_eq!(request["thinking"]["type"], "disabled");
        assert!(request.get("reasoning_effort").is_none());
    }

    #[test]
    fn provider_chat_messages_prepends_system_instruction() {
        let messages = provider_chat_messages(&json!({
            "system": "Stay concise.",
            "text": "Summarize this."
        }))
        .unwrap();
        assert_eq!(
            messages,
            json!([
                {"role": "system", "content": "Stay concise."},
                {"role": "user", "content": "Summarize this."}
            ])
        );
    }

    #[test]
    fn provider_chat_deepseek_accepts_runtime_api_key_without_storing_profile() {
        let dir = temp_test_dir("deepseek-runtime-key");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = listener.local_addr().unwrap();
        let (sender, receiver) = channel::<Vec<String>>();
        let server_thread = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            assert!(reader.read_line(&mut request_line).is_ok());
            assert!(request_line.starts_with("POST"));

            let mut headers = Vec::new();
            let mut content_length = 0usize;
            loop {
                let mut line = String::new();
                let bytes = reader.read_line(&mut line).unwrap();
                if bytes == 0 || line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    headers.push(format!(
                        "{}:{}",
                        key.trim().to_ascii_lowercase(),
                        value.trim().to_string()
                    ));
                    if key.eq_ignore_ascii_case("content-length") {
                        content_length = value.trim().parse::<usize>().unwrap_or(0);
                    }
                }
            }
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).unwrap();
            sender.send(headers).unwrap();
            let body =
                br#"{"choices":[{"message":{"role":"assistant","content":"Runtime key reply"}}]}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            let stream = reader.get_mut();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        });

        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "deepseek",
                "apiKey": concat!("runtime-only", "-secret"),
                "url": format!("http://{}", server),
                "text": "hello"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let headers = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "Runtime key reply");
        assert!(
            headers
                .iter()
                .any(|header| header == "authorization:Bearer runtime-only-secret")
        );
        assert!(!profiles_path(&dir).exists());
    }

    #[test]
    fn provider_chat_chatgpt_accepts_runtime_api_key_without_storing_profile() {
        let dir = temp_test_dir("chatgpt-runtime-key");
        let (url, server_thread, receiver) =
            provider_json_server(br#"{"output_text":"ChatGPT reply","usage":{"total_tokens":3}}"#);

        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "chatgpt",
                "apiKey": concat!("runtime-openai", "-secret"),
                "url": url,
                "text": "hello"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let (headers, request) = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "ChatGPT reply");
        assert_eq!(request["model"], DEFAULT_CHATGPT_MODEL);
        assert_eq!(request["input"], "hello");
        assert!(
            headers
                .iter()
                .any(|header| header == "authorization:Bearer runtime-openai-secret")
        );
        assert!(!profiles_path(&dir).exists());
    }

    #[test]
    fn provider_chat_gemini_accepts_runtime_api_key_without_storing_profile() {
        let dir = temp_test_dir("gemini-runtime-key");
        let (url, server_thread, receiver) = provider_json_server(
            br#"{"model":"gemini-3.5-flash","steps":[{"type":"model_output","content":[{"type":"text","text":"Gemini reply"}]}]}"#,
        );

        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "gemini",
                "apiKey": concat!("runtime-gemini", "-secret"),
                "url": url,
                "text": "hello"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let (headers, request) = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "Gemini reply");
        assert_eq!(request["model"], DEFAULT_GEMINI_MODEL);
        assert_eq!(request["input"], "hello");
        assert!(
            headers
                .iter()
                .any(|header| header == "x-goog-api-key:runtime-gemini-secret")
        );
        assert!(!profiles_path(&dir).exists());
    }

    #[test]
    fn provider_chat_kimi_accepts_runtime_api_key_without_storing_profile() {
        let dir = temp_test_dir("kimi-runtime-key");
        let (url, server_thread, receiver) =
            provider_json_server(br#"{"choices":[{"message":{"content":"Kimi reply"}}]}"#);

        let result = provider_chat_in(
            &dir,
            &json!({
                "providerId": "kimi",
                "apiKey": concat!("runtime-kimi", "-secret"),
                "url": url,
                "text": "hello"
            }),
        )
        .unwrap();
        server_thread.join().unwrap();
        let (headers, request) = receiver.recv().unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["output"], "Kimi reply");
        assert_eq!(request["model"], DEFAULT_KIMI_MODEL);
        assert_eq!(request["messages"][0]["content"], "hello");
        assert!(
            headers
                .iter()
                .any(|header| header == "authorization:Bearer runtime-kimi-secret")
        );
        assert!(!profiles_path(&dir).exists());
    }

    #[test]
    fn provider_credential_export_reads_deepseek_bearer_profile() {
        let dir = temp_test_dir("deepseek-credential-export");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "deepseek",
                "provider": "deepseek",
                "apiKey": concat!("exported-test", "-secret"),
            }),
        )
        .unwrap();

        let exported =
            export_provider_credential_in(&dir, &json!({"providerId": "deepseek"})).unwrap();

        assert_eq!(exported["ok"], true);
        assert_eq!(exported["providerId"], "deepseek");
        assert_eq!(exported["credentialKind"], "api-key");
        assert_eq!(exported["apiKey"], "exported-test-secret");
        assert_eq!(exported["credentialHint"], "**** cret");
        assert_eq!(exported["bodyRedacted"], true);
    }

    #[test]
    fn configured_deepseek_environment_profile_is_listed_masked_and_exportable() {
        let _guard = TestConfiguredApiKeyGuard::set("deepseek", "configured-deepseek-secret");
        let dir = temp_test_dir("deepseek-configured-environment");

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        let profile = &profiles[0];
        assert_eq!(profile["id"], "deepseek");
        assert_eq!(profile["provider"], "deepseek");
        assert_eq!(profile["credentialPresent"], true);
        assert_eq!(profile["source"], "desktop-environment");
        assert_eq!(profile["headers"]["Authorization"].as_str(), Some("***"));
        assert!(!listed.to_string().contains("configured-deepseek-secret"));

        let exported =
            export_provider_credential_in(&dir, &json!({"providerId": "deepseek"})).unwrap();
        assert_eq!(exported["ok"], true);
        assert_eq!(exported["providerId"], "deepseek");
        assert_eq!(exported["apiKey"], "configured-deepseek-secret");
        assert_eq!(exported["source"], "desktop-environment");
    }

    #[test]
    fn configured_gemini_environment_profile_is_listed_masked_and_exportable() {
        let _guard = TestConfiguredApiKeyGuard::set("gemini", "configured-gemini-secret");
        let dir = temp_test_dir("gemini-configured-environment");

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        let profile = &profiles[0];
        assert_eq!(profile["id"], "gemini");
        assert_eq!(profile["provider"], "gemini");
        assert_eq!(profile["credentialPresent"], true);
        assert_eq!(profile["source"], "desktop-environment");
        assert_eq!(profile["headers"]["x-goog-api-key"].as_str(), Some("***"));
        assert!(!listed.to_string().contains("configured-gemini-secret"));

        let exported =
            export_provider_credential_in(&dir, &json!({"providerId": "gemini"})).unwrap();
        assert_eq!(exported["ok"], true);
        assert_eq!(exported["providerId"], "gemini");
        assert_eq!(exported["apiKey"], "configured-gemini-secret");
        assert_eq!(exported["source"], "desktop-environment");
    }

    #[test]
    fn configured_gemini_oauth_profile_is_listed_masked_and_exportable() {
        let _guard = TestConfiguredOAuthCredentialGuard::set(
            "gemini",
            json!({
                "providerId": "gemini",
                "credentialKind": "oauth-pkce",
                "accessToken": "configured-gemini-access-token",
                "refreshToken": "configured-gemini-refresh-token",
                "idToken": "configured-gemini-id-token",
                "expiresAtEpochMillis": 1_850_000_000_000i64,
                "credentialHint": "OAuth",
                "source": "gemini-cli-oauth"
            }),
        );
        let dir = temp_test_dir("gemini-configured-oauth");

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        let profile = &profiles[0];
        assert_eq!(profile["id"], "gemini-oauth");
        assert_eq!(profile["provider"], "gemini");
        assert_eq!(profile["credentialKind"], "oauth-pkce");
        assert_eq!(profile["credentialPresent"], true);
        assert_eq!(profile["source"], "gemini-cli-oauth");
        assert!(
            !listed
                .to_string()
                .contains("configured-gemini-access-token")
        );
        assert!(
            !listed
                .to_string()
                .contains("configured-gemini-refresh-token")
        );

        let exported = export_provider_credential_in(
            &dir,
            &json!({"providerId": "gemini", "profileId": "gemini-oauth"}),
        )
        .unwrap();
        assert_eq!(exported["ok"], true);
        assert_eq!(exported["providerId"], "gemini");
        assert_eq!(exported["credentialKind"], "oauth-pkce");
        assert_eq!(exported["accessToken"], "configured-gemini-access-token");
        assert_eq!(exported["refreshToken"], "configured-gemini-refresh-token");
        assert_eq!(exported["credentialHint"], "OAuth");
        assert_eq!(exported["source"], "gemini-cli-oauth");
    }

    #[test]
    fn explicit_profile_id_selects_matching_provider_credential() {
        let dir = temp_test_dir("provider-profile-id-export");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "deepseek-work",
                "provider": "deepseek",
                "apiKey": "work-secret",
            }),
        )
        .unwrap();
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "deepseek-personal",
                "provider": "deepseek",
                "apiKey": concat!("personal", "-secret"),
            }),
        )
        .unwrap();

        let exported = export_provider_credential_in(
            &dir,
            &json!({"providerId": "deepseek", "profileId": "deepseek-personal"}),
        )
        .unwrap();

        assert_eq!(exported["apiKey"], "personal-secret");
    }

    #[test]
    fn account_scoped_provider_credential_delete_removes_only_exact_native_secret() {
        let dir = temp_test_dir("provider-account-scoped-delete");
        for (profile, secret) in [
            ("account-work", "work-secret"),
            ("account-personal", "personal-secret"),
        ] {
            save_model_profile_in(
                &dir,
                &json!({
                    "profile": profile,
                    "provider": "deepseek",
                    "apiKey": secret,
                }),
            )
            .unwrap();
        }

        let deleted = delete_model_profile_credential_in(
            &dir,
            &json!({"profile": "account-work", "provider": "deepseek"}),
        )
        .unwrap();
        assert_eq!(deleted["ok"], true);
        assert_eq!(deleted["deleted"], true);
        assert_eq!(deleted["credentialDeleted"], true);

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0]["id"], "account-personal");
        assert_eq!(profiles[0]["credentialPresent"], true);
        let exported = export_provider_credential_in(
            &dir,
            &json!({
                "providerId": "deepseek",
                "profileId": "account-personal"
            }),
        )
        .unwrap();
        assert_eq!(exported["apiKey"], "personal-secret");

        assert!(
            delete_model_profile_credential_in(
                &dir,
                &json!({"profile": "account-work", "provider": "deepseek"}),
            )
            .is_err()
        );
        assert!(
            delete_model_profile_credential_in(
                &dir,
                &json!({"profile": "account-personal", "provider": "gemini"}),
            )
            .is_err()
        );
    }

    #[test]
    fn provider_credential_export_reads_gemini_api_key_profile() {
        let dir = temp_test_dir("gemini-credential-export");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "gemini",
                "provider": "gemini",
                "apiKey": concat!("gemini-exported", "-secret"),
            }),
        )
        .unwrap();

        let exported =
            export_provider_credential_in(&dir, &json!({"providerId": "gemini"})).unwrap();
        let listed = list_model_profiles_in(&dir).unwrap();

        assert_eq!(exported["ok"], true);
        assert_eq!(exported["providerId"], "gemini");
        assert_eq!(exported["apiKey"], "gemini-exported-secret");
        assert_eq!(exported["bodyRedacted"], true);
        assert_eq!(
            listed["profiles"][0]["credentialStorage"].as_str(),
            Some("platform-secret-store")
        );
        assert_eq!(listed["profiles"][0]["credentialPresent"], true);
        assert!(listed["profiles"][0]["providerCredentialRef"].is_object());
    }

    #[test]
    fn list_model_profiles_uses_platform_secret_ref_for_api_key_secrets() {
        let dir = temp_test_dir("secret-masking");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "masked",
                "command": "/bin/echo",
                "apiKey": concat!("secret", "-value")
            }),
        )
        .unwrap();

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        let profile = &profiles[0];
        assert_eq!(
            profile["credentialStorage"].as_str(),
            Some("platform-secret-store")
        );
        assert_eq!(profile["credentialPresent"], true);
        assert!(profile["providerCredentialRef"].is_object());
        assert!(profile.get("headers").is_none());

        let raw = fs::read_to_string(profiles_path(&dir)).unwrap();
        assert!(!raw.contains("secret-value"));
        assert!(!raw.contains("X-LicoLite-Api-Key"));
    }

    #[test]
    fn forward_http_rejects_non_localhost_non_https_urls() {
        let dir = temp_test_dir("bad-scheme");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "bad",
                "url": "http://evil.example.com/forward",
                "apiKey": "secret"
            }),
        )
        .unwrap();

        let result = forward_in(&dir, &json!({"profile": "bad", "text": "test"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "invalid_profile");
    }

    #[test]
    fn forward_http_rejects_loopback_prefix_spoofing() {
        let dir = temp_test_dir("spoofed-loopback");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "spoofed",
                "url": "http://127.0.0.1.evil.test/forward",
                "apiKey": "secret"
            }),
        )
        .unwrap();

        let result = forward_in(&dir, &json!({"profile": "spoofed", "text": "test"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "invalid_profile");
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-forwarding-{}-{}", name, timestamp()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
