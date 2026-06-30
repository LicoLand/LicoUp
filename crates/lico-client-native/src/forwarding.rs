use crate::file_security::atomic_write_private_text;
use crate::paths::portable_data_dir;
use crate::url_security::is_https_or_loopback_http_url;
use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const PROFILE_SCHEMA_VERSION: u32 = 1;
const FORWARDING_DIR: &str = "model-forwarding";
const PROFILES_FILE: &str = "profiles.json";

pub fn list_model_profiles() -> Result<Value> {
    list_model_profiles_in(&portable_data_dir()?)
}

pub fn save_model_profile(params: &Value) -> Result<Value> {
    save_model_profile_in(&portable_data_dir()?, params)
}

pub fn forward(params: &Value) -> Result<Value> {
    forward_in(&portable_data_dir()?, params)
}

fn list_model_profiles_in(data_dir: &Path) -> Result<Value> {
    let document = read_profiles_document(data_dir)?;
    let profiles = document["profiles"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
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
        ] {
            if headers.contains_key(key) {
                headers.insert(key.to_string(), json!("***"));
            }
        }
    }
    profile
}

fn save_model_profile_in(data_dir: &Path, params: &Value) -> Result<Value> {
    let id = profile_id(params)?;
    let provider = params
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
        })
        .ok_or_else(|| anyhow!("model profile requires --command or --url"))?;

    if provider != "command" && provider != "http" {
        return Err(anyhow!("unsupported forwarding provider: {}", provider));
    }

    let mut profile = Map::new();
    profile.insert("id".to_string(), json!(id));
    profile.insert("provider".to_string(), json!(provider));
    let label = params
        .get("label")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| id.clone());
    profile.insert("label".to_string(), json!(label));
    if let Some(command) = params.get("command").and_then(Value::as_str) {
        profile.insert("command".to_string(), json!(command));
    }
    if let Some(args) = profile_args(params) {
        profile.insert("args".to_string(), args);
    }
    if let Some(url) = params.get("url").and_then(Value::as_str) {
        profile.insert("url".to_string(), json!(url));
    }
    let headers = profile_headers(params);
    if !headers.is_empty() {
        profile.insert("headers".to_string(), Value::Object(headers));
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
    if let Some(headers) = profile.get("headers").and_then(Value::as_object) {
        for (key, value) in headers {
            if let Some(header_value) = value.as_str() {
                request = request.set(key, header_value);
            }
        }
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

fn profile_headers(params: &Value) -> Map<String, Value> {
    let mut headers = params
        .get("headers")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if let Some(api_key) = params
        .get("apiKey")
        .or_else(|| params.get("licoApiKey"))
        .and_then(Value::as_str)
    {
        headers.insert("X-LicoLite-Api-Key".to_string(), json!(api_key));
    }
    headers
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
                "apiKey": "secret"
            }),
        )
        .unwrap();

        let raw = fs::read_to_string(profiles_path(&dir)).unwrap();
        assert!(raw.contains("\"profiles\""));
        assert!(raw.contains("\"X-LicoLite-Api-Key\""));
        assert!(!raw.contains("agent.invoke"));
        assert!(!raw.contains("customHttpAdapter"));
        assert!(!raw.contains("knowledge.agent.answer"));
    }

    #[test]
    fn thin_forwarding_rejects_missing_or_unknown_provider() {
        let dir = temp_test_dir("bad-provider");
        let missing_provider =
            save_model_profile_in(&dir, &json!({"profile": "missing"})).unwrap_err();
        assert!(missing_provider.to_string().contains("--command or --url"));

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
    fn list_model_profiles_masks_api_key_secrets() {
        let dir = temp_test_dir("secret-masking");
        save_model_profile_in(
            &dir,
            &json!({
                "profile": "masked",
                "command": "/bin/echo",
                "apiKey": "secret-value"
            }),
        )
        .unwrap();

        let listed = list_model_profiles_in(&dir).unwrap();
        let profiles = listed["profiles"].as_array().unwrap();
        assert_eq!(profiles.len(), 1);
        let profile = &profiles[0];
        let headers = profile.get("headers").and_then(Value::as_object);
        assert!(headers.is_some());
        assert_eq!(
            headers
                .unwrap()
                .get("X-LicoLite-Api-Key")
                .and_then(Value::as_str),
            Some("***")
        );

        let raw = fs::read_to_string(profiles_path(&dir)).unwrap();
        assert!(raw.contains("secret-value"));
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
