use anyhow::Result;
use serde_json::Value;
use std::env;

fn main() -> Result<()> {
    env_logger::init();
    match lico_client_native::commands::execute_cli(env::args().skip(1).collect::<Vec<_>>())? {
        lico_client_native::commands::CliExecution::Usage => print_usage(),
        lico_client_native::commands::CliExecution::Json(value) => print_json(&value),
    }
    Ok(())
}

fn print_json(value: &Value) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_string())
    );
}

fn print_usage() {
    eprintln!(
        "Usage:
  lico-client model profiles list
  lico-client model profiles set <profile-id> [--command CMD|--url URL] [--args JSON] [--api-key KEY]
  lico-client forward --profile <profile-id> --text <input>
  lico-client state get|set <settings|targets|pairings|skills|pins|identities|snapshot-bridges|conversation-archive-profiles|agent-usage-reports> [json]
  lico-client process-identity bootstrap claim --server-url URL --claim-token TOKEN --default-identity-hash HASH [--client-id ID]
  lico-client process-identity request sign --request-url URL [--method POST] [--body-text JSON]
  lico-client process-identity status [--server-url URL|--package-id ID]
  lico-client local-runtime ensure|build [--port 17328] [--rebuild true]
  lico-client local-runtime start|restart [--port 17328]
  lico-client local-runtime stop|status|logs [--tail N]
  lico-client source-queue add|list|status|pause|resume|retry|cancel|drain [--path PATH|--text TEXT] [--server-url URL]
  lico-client connectors list|sync|status [--connector local-directory|icloud-local-projection|onedrive-local-projection] [--path PATH]
  lico-client connectors mirror inspect [--limit N]
  lico-client knowledge-cache sync|search|evidence|get|status [--evidence-json JSON|--evidence-file PATH|--query TEXT|--evidence-id ID]
  lico-client mail preview|enqueue|status|cancel --mailbox NAME [--since DATE|--until DATE|--query TEXT]
  lico-client mcp-local-bridge plan|start|stop|status|register [--port 17328|--server-url URL]
  lico-client activity list [--type TYPE] [--target TARGET] [--limit N]
  lico-client snapshots list [--target TARGET]
  lico-client snapshots restore <snapshot-id>
  lico-client snapshots root get|set [--path PATH]
  lico-client snapshots curator get|set [--target AGENT|--clear true] [--command CMD] [--args JSON] [--cwd PATH]
  lico-client snapshots collections list [--snapshot-root PATH]
  lico-client snapshots profiles list|get|import [--profile PROFILE_ID|--profile-json JSON|--profile-file PATH]  # diagnostic
  lico-client snapshots archive jobs create --keywords KEYWORDS --path PATH [--curation true|false]
  lico-client snapshots archive jobs status|events|cancel --job-id JOB_ID
  lico-client snapshots archive jobs list|drain [--job-id JOB_ID] [--once true]
  lico-client snapshots archive collect --keywords KEYWORDS --path PATH [--curation true|false] [--trigger manual|agent|scheduled]  # diagnostic
  lico-client snapshots archive run|verify|report --profile PROFILE_ID [--curation true|false] [--trigger manual|agent|scheduled]  # diagnostic
  lico-client snapshots archive verify --collection-path PATH
  lico-client snapshots bridge ensure --target TARGET [--config-path PATH]
  lico-client snapshots curation start --topic TOPIC [--agent AGENT] [--read-budget N]
  lico-client snapshots curation candidates list --curation-session-id ID
  lico-client snapshots curation candidate expand --curation-session-id ID --candidate-id ID
  lico-client snapshots curation submit-result --curation-session-id ID [--curation-result-json JSON|--curation-result-file PATH]
  lico-client snapshots collect --topic TOPIC [--agent AGENT] [--curation true|false] [--curation-result-json JSON|--curation-result-file PATH]
  lico-client conversations list|append|delete --agent AGENT [--session-id ID] [--text TEXT]
  lico-client agent-usage scan [--agent AGENT] [--observe-ms MS] [--state-root PATH]
  lico-client agent-usage report [--agent AGENT] [--limit N] [--state-root PATH]
  lico-client agent message send --agent AGENT --text TEXT [--session-id ID] [--cwd PATH] [--command CMD] [--args JSON]
  lico-client agents pair request|approve|revoke|list --agent AGENT [--target TARGET]
  lico-client skill list --agent AGENT
  lico-client skill get <skill-id> --agent AGENT --json
  lico-client skill install plan|apply --agent AGENT --url GITHUB_URL [--install-root PATH] [--name NAME] [--overwrite true|false] [--pin true|false]
  lico-client skill install rollback --agent AGENT --snapshot-id ID
  lico-client skill visibility set <skill-id> --agent AGENT --hidden true|false
  lico-client skill pin set <skill-id> --agent AGENT --version VERSION
  lico-client targets scan [--state-root PATH] [--include-accessible-environments true|false] [--installer-scan-command PATH]
  lico-client targets add --target <target> [--config-path PATH] [--binary-path PATH] [--history-root PATH] [--state-root PATH]
  lico-client targets inspect <target> [--state-root PATH]
  lico-client mobile relay config get|set [--use-custom-gateway true|false] [--custom-gateway-url URL] [--relay-enabled true|false]
  lico-client mobile relay pairing create|status|claim|revoke [--pairing-code CODE] [--pairing-id ID] [--mobile-token TOKEN]
  lico-client mobile relay pc check-in
  lico-client mobile relay commands poll|sync|complete|create|result [--command-id ID] [--type TYPE] [--payload JSON] [--mobile-token TOKEN]
  lico-client secure-mesh status|envelope validate|payload seal|payload open|command policy|command evaluate|command execute [--payload JSON] [--context JSON] [--ledger-path PATH]
  lico-client secure-mesh device-trust evaluate --identity JSON [--previous-identity JSON] [--trust-state verified|cross_signed|unverified|key_changed|revoked]
  lico-client secure-mesh file route --manifest JSON
  lico-client mcp plugin status|update|rollback --target <target> [--config-path PATH] [--discovery-file PATH] [--registry-file PATH] [--state-root PATH]
  lico-client mcp config plan --target <target> [--config-path PATH] [--base-url URL|--discovery-file PATH|--registry-file PATH] [--state-root PATH]
  lico-client mcp config apply --target <target> [--config-path PATH] [--base-url URL|--discovery-file PATH|--registry-file PATH] [--token TOKEN] [--state-root PATH]
  lico-client mcp config rollback --target <target> [--snapshot-id ID] [--state-root PATH]"
    );
}

#[cfg(test)]
mod tests {
    use rand::RngCore;
    use serde_json::{Value, json};
    use std::env;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn execute_cli(
        args: Vec<String>,
    ) -> anyhow::Result<lico_client_native::commands::CliExecution> {
        lico_client_native::commands::execute_cli(args)
    }

    fn stdin_echo_command_args() -> (&'static str, Option<String>) {
        #[cfg(windows)]
        {
            ("cmd.exe", Some(json!(["/C", "more"]).to_string()))
        }
        #[cfg(not(windows))]
        {
            ("/bin/cat", None)
        }
    }

    fn signed_receipt_discovery(endpoint: &str, path: &Path) {
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let secret_bytes = bytes;
        let mcp_url = format!("{}/mcp", endpoint.trim_end_matches('/'));
        let (receipt, public_key) = lico_client_native::mcp_trust::test_signed_receipt(
            endpoint,
            &mcp_url,
            "test-key",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );
        let doc = serde_json::json!({
            "url": endpoint,
            "trustReceipt": receipt,
            "pinnedPublicKey": public_key
        });
        fs::write(path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    }

    #[test]
    fn cli_dispatches_state_profiles_targets() {
        let dir = temp_cli_dir("dispatch");
        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);
            let (forward_command, forward_args) = stdin_echo_command_args();

            let mut profile_set_args = vec![
                "model".into(),
                "profiles".into(),
                "set".into(),
                "--profile".into(),
                "cat".into(),
                "--command".into(),
                forward_command.into(),
                "--label".into(),
                "Cat".into(),
            ];
            if let Some(forward_args) = forward_args {
                profile_set_args.push("--args".into());
                profile_set_args.push(forward_args);
            }
            let profile_set = execute_cli(profile_set_args).unwrap();
            assert_eq!(json_payload(&profile_set)["status"], "saved");

            let profiles =
                execute_cli(vec!["model".into(), "profiles".into(), "list".into()]).unwrap();
            let profiles = json_payload(&profiles);
            assert_eq!(profiles["ok"], true);
            assert_eq!(profiles["profiles"][0]["id"], "cat");

            let forward = execute_cli(vec![
                "forward".into(),
                "--profile".into(),
                "cat".into(),
                "--text".into(),
                "hello-forward".into(),
            ])
            .unwrap();
            let forward_output = json_payload(&forward)["output"]
                .as_str()
                .unwrap_or_default()
                .to_string();
            assert!(forward_output.contains("hello-forward"));

            let set_state = execute_cli(vec![
                "state".into(),
                "set".into(),
                "targets".into(),
                r#"{"items": []}"#.into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&set_state)["ok"], true);

            let get_state =
                execute_cli(vec!["state".into(), "get".into(), "targets".into()]).unwrap();
            let got = json_payload(&get_state);
            assert_eq!(got["collection"], "targets");

            let activities = execute_cli(vec![
                "activity".into(),
                "list".into(),
                "--limit".into(),
                "5".into(),
            ])
            .unwrap();
            assert!(json_payload(&activities)["ok"].as_bool().unwrap_or(false));

            let list_targets = execute_cli(vec![
                "targets".into(),
                "scan".into(),
                "--state-root".into(),
                dir.join("future-client").display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&list_targets)["ok"], true);
            let inspect_target =
                execute_cli(vec!["targets".into(), "inspect".into(), "opencode".into()]).unwrap();
            assert_eq!(
                json_payload(&inspect_target)["target"]["target"],
                "opencode"
            );

            let added = execute_cli(vec![
                "targets".into(),
                "add".into(),
                "--target".into(),
                "opencode".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&added)["status"], "accepted");

            let native_history_root = dir.join("native-codex-history");
            fs::create_dir_all(&native_history_root).unwrap();
            fs::write(
                native_history_root.join("history.jsonl"),
                [
                    r#"{"role":"user","content":"hello from native codex history"}"#,
                    r#"{"role":"assistant","content":"native history response"}"#,
                ]
                .join("\n"),
            )
            .unwrap();

            let conversations = execute_cli(vec![
                "conversations".into(),
                "list".into(),
                "--agent".into(),
                "codex".into(),
                "--root".into(),
                native_history_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&conversations)["sessions"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );
            assert_eq!(json_payload(&conversations)["mode"], "native-history");

            let usage = execute_cli(vec![
                "agent-usage".into(),
                "scan".into(),
                "--agent".into(),
                "codex".into(),
                "--root".into(),
                native_history_root.display().to_string(),
                "--state-root".into(),
                dir.join("future-client").display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&usage)["mode"], "agent-usage-metering");
            assert_eq!(json_payload(&usage)["summary"]["agentCount"], 1);

            let usage_report = execute_cli(vec![
                "agent-usage".into(),
                "report".into(),
                "--agent".into(),
                "codex".into(),
                "--state-root".into(),
                dir.join("future-client").display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&usage_report)["reports"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );

            let relay_config = execute_cli(vec![
                "mobile".into(),
                "relay".into(),
                "config".into(),
                "set".into(),
                "--use-custom-gateway".into(),
                "true".into(),
                "--custom-gateway-url".into(),
                "https://relay.example.test/".into(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&relay_config)["config"]["useCustomGateway"],
                true
            );
            assert_eq!(
                json_payload(&relay_config)["config"]["customGatewayUrl"],
                "https://relay.example.test"
            );
        }
    }

    #[test]
    fn cli_dispatches_mcp_and_skill_paths() {
        let dir = temp_cli_dir("dispatch-mcp");
        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);

            let requested = execute_cli(vec![
                "agents".into(),
                "pair".into(),
                "request".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&requested)["status"], "requested");

            let pair_list = execute_cli(vec![
                "agents".into(),
                "pair".into(),
                "list".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&pair_list)["pairings"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );

            let approved = execute_cli(vec![
                "agents".into(),
                "pair".into(),
                "approve".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&approved)["status"], "approved");

            let skill_list = execute_cli(vec![
                "skill".into(),
                "list".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&skill_list)["ok"], true);
            assert_eq!(
                json_payload(&skill_list)["skills"]
                    .as_array()
                    .unwrap()
                    .len(),
                0
            );

            let get_unavailable = execute_cli(vec![
                "skill".into(),
                "get".into(),
                "review".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&get_unavailable)["error"], "protocol_deferred");

            let visibility = execute_cli(vec![
                "skill".into(),
                "visibility".into(),
                "set".into(),
                "--agent".into(),
                "codex".into(),
                "--skill".into(),
                "review".into(),
                "--visibility".into(),
                "hidden".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&visibility)["hidden"], true);
            assert_eq!(json_payload(&visibility)["skillId"], "review");

            let pin = execute_cli(vec![
                "skill".into(),
                "pin".into(),
                "set".into(),
                "--agent".into(),
                "codex".into(),
                "--skill".into(),
                "review".into(),
                "--version".into(),
                "1.0.0".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&pin)["version"], "1.0.0");

            let revoked = execute_cli(vec![
                "agents".into(),
                "pair".into(),
                "revoke".into(),
                "--agent".into(),
                "codex".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&revoked)["status"], "revoked");

            let plugin_status = execute_cli(vec![
                "mcp".into(),
                "plugin".into(),
                "status".into(),
                "--target".into(),
                "opencode".into(),
            ])
            .unwrap();
            assert!(matches!(
                json_payload(&plugin_status)["status"].as_str(),
                Some("configured") | Some("not-configured")
            ));

            let discovery_file = dir.join("mcp-discovery.json");
            signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

            let config_path = dir.join("opencode.jsonc");
            fs::write(&config_path, "{}\n").unwrap();
            let plugin_update = execute_cli(vec![
                "mcp".into(),
                "plugin".into(),
                "update".into(),
                "--target".into(),
                "opencode".into(),
                "--config-path".into(),
                config_path.display().to_string(),
                "--state-root".into(),
                dir.join("future-client").display().to_string(),
                "--token".into(),
                "plugin-token".into(),
                "--discovery-file".into(),
                discovery_file.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&plugin_update)["status"], "updated");

            let snapshot_id = json_payload(&plugin_update)
                .get("apply")
                .and_then(|a| a.get("snapshotId"))
                .and_then(|s| s.as_str())
                .unwrap_or("snapshot-missing")
                .to_string();

            let plugin_rollback = execute_cli(vec![
                "mcp".into(),
                "plugin".into(),
                "rollback".into(),
                "--target".into(),
                "opencode".into(),
                "--snapshot-id".into(),
                snapshot_id,
            ])
            .unwrap();
            assert_eq!(json_payload(&plugin_rollback)["status"], "rolled_back");
        }
    }

    #[test]
    fn cli_dispatches_mcp_config_and_snapshots() {
        let dir = temp_cli_dir("dispatch-config");
        let config_path = dir.join("opencode.jsonc");
        fs::write(&config_path, "{}\n").unwrap();

        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);
            let state_root = dir.join("future-client");

            let discovery_file = dir.join("mcp-discovery.json");
            signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

            let plan = execute_cli(vec![
                "mcp".into(),
                "config".into(),
                "plan".into(),
                "--target".into(),
                "opencode".into(),
                "--discovery-file".into(),
                discovery_file.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&plan)["status"], "planned");

            let apply = execute_cli(vec![
                "mcp".into(),
                "config".into(),
                "apply".into(),
                "--target".into(),
                "opencode".into(),
                "--config-path".into(),
                config_path.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
                "--token".into(),
                "x-token".into(),
                "--discovery-file".into(),
                discovery_file.display().to_string(),
            ])
            .unwrap();
            let apply = json_payload(&apply);
            assert_eq!(apply["status"], "applied");
            assert!(apply["snapshotId"].is_string());

            let rollback = execute_cli(vec![
                "mcp".into(),
                "config".into(),
                "rollback".into(),
                "--target".into(),
                "opencode".into(),
                "--snapshot-id".into(),
                apply["snapshotId"].as_str().unwrap().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&rollback)["status"], "rolled_back");

            let conflict = execute_cli(vec![
                "mcp".into(),
                "config".into(),
                "apply".into(),
                "--target".into(),
                "opencode".into(),
                "--config-path".into(),
                config_path.display().to_string(),
                "--expected-hash".into(),
                "bad-hash".into(),
                "--discovery-file".into(),
                discovery_file.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&conflict)["status"], "field_conflict");

            let list = execute_cli(vec![
                "snapshots".into(),
                "list".into(),
                "--target".into(),
                "opencode".into(),
            ])
            .unwrap();
            let list = json_payload(&list);
            assert_eq!(list["ok"], true);
            let snapshot_id = list["snapshots"]
                .as_array()
                .and_then(|items| items.first())
                .and_then(|item| item.get("snapshotId"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if !snapshot_id.is_empty() {
                let restore = execute_cli(vec!["snapshots".into(), "restore".into(), snapshot_id]);
                assert!(restore.is_ok());
            }
        }
    }

    #[test]
    fn cli_dispatches_native_conversation_snapshot_commands() {
        let dir = temp_cli_dir("dispatch-conversation-snapshots");
        let state_root = dir.join("future-client");
        let snapshot_root = dir.join("conversation-snapshot-root");
        let archive_root = dir.join("conversation-archive-root");
        let home = dir.join("home");
        let codex_history = home.join(".codex");
        fs::create_dir_all(&codex_history).unwrap();
        fs::write(
            codex_history.join("history.jsonl"),
            r#"{"sessionId":"dispatch-archive","role":"user","content":"Dispatch LicoLite conversation archive"}"#,
        )
        .unwrap();
        let bridge_config = dir.join("bridge-settings.json");
        fs::write(&bridge_config, "{}\n").unwrap();

        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);

            let root_set = execute_cli(vec![
                "snapshots".into(),
                "root".into(),
                "set".into(),
                "--path".into(),
                snapshot_root.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&root_set)["status"], "set");

            let root_get = execute_cli(vec![
                "snapshots".into(),
                "root".into(),
                "get".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&root_get)["snapshotRoot"],
                snapshot_root.display().to_string()
            );

            let bridge = execute_cli(vec![
                "snapshots".into(),
                "bridge".into(),
                "ensure".into(),
                "--target".into(),
                "codex".into(),
                "--config-path".into(),
                bridge_config.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&bridge)["status"], "verified");

            let curator_set = execute_cli(vec![
                "snapshots".into(),
                "curator".into(),
                "set".into(),
                "--target".into(),
                "codex".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&curator_set)["preferredSnapshotCurator"]["target"],
                "codex"
            );

            let curator_get = execute_cli(vec![
                "snapshots".into(),
                "curator".into(),
                "get".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&curator_get)["configured"], true);

            let collect = execute_cli(vec![
                "snapshots".into(),
                "collect".into(),
                "--topic".into(),
                "dispatch topic".into(),
                "--agent".into(),
                "codex".into(),
                "--curation".into(),
                "false".into(),
                "--home-dir".into(),
                home.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&collect)["ok"], true);

            let collections = execute_cli(vec![
                "snapshots".into(),
                "collections".into(),
                "list".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&collections)["collections"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );

            let profile_import = execute_cli(vec![
                "snapshots".into(),
                "profiles".into(),
                "import".into(),
                "--profile-id".into(),
                "licolite".into(),
                "--display-name".into(),
                "LicoLite".into(),
                "--archive-root".into(),
                archive_root.display().to_string(),
                "--canonical-names".into(),
                "LicoLite".into(),
                "--expected-agents".into(),
                "codex".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&profile_import)["status"], "imported");

            let profiles = execute_cli(vec![
                "snapshots".into(),
                "profiles".into(),
                "list".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&profiles)["profiles"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );

            let profile_get = execute_cli(vec![
                "snapshots".into(),
                "profiles".into(),
                "get".into(),
                "--profile".into(),
                "licolite".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&profile_get)["profile"]["profileId"],
                "licolite"
            );

            let archive_run = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "run".into(),
                "--profile".into(),
                "licolite".into(),
                "--home-dir".into(),
                home.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&archive_run)["mode"], "conversation-archive");
            assert_eq!(json_payload(&archive_run)["selectedCount"], 1);

            let archive_verify = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "verify".into(),
                "--profile".into(),
                "licolite".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(
                json_payload(&archive_verify)["validation"]["healthStatus"],
                "ok"
            );

            let archive_report = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "report".into(),
                "--profile".into(),
                "licolite".into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&archive_report)["indexCount"], 1);

            let keyword_archive = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "collect".into(),
                "--keywords".into(),
                "LicoLite".into(),
                "--path".into(),
                archive_root.display().to_string(),
                "--agent".into(),
                "codex".into(),
                "--curation".into(),
                "false".into(),
                "--home-dir".into(),
                home.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&keyword_archive)["status"], "archived");

            let archive_job = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "jobs".into(),
                "create".into(),
                "--keywords".into(),
                "LicoLite".into(),
                "--path".into(),
                archive_root.display().to_string(),
                "--agent".into(),
                "codex".into(),
                "--curation".into(),
                "false".into(),
                "--home-dir".into(),
                home.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            let archive_job = json_payload(&archive_job);
            assert_eq!(archive_job["status"], "queued");
            assert_eq!(archive_job["eventConsistency"]["ok"], true);
            let archive_job_id = archive_job["jobId"].as_str().unwrap().to_string();

            let archive_job_status = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "jobs".into(),
                "status".into(),
                "--job-id".into(),
                archive_job_id.clone(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&archive_job_status)["status"], "queued");

            let archive_job_events = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "jobs".into(),
                "events".into(),
                "--job-id".into(),
                archive_job_id.clone(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert!(
                json_payload(&archive_job_events)["events"]
                    .as_array()
                    .unwrap()
                    .len()
                    >= 2
            );

            let archive_job_drain = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "jobs".into(),
                "drain".into(),
                "--job-id".into(),
                archive_job_id.clone(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&archive_job_drain)["status"], "drained");
            assert_eq!(json_payload(&archive_job_drain)["completed"], 1);

            let archive_job_completed = execute_cli(vec![
                "snapshots".into(),
                "archive".into(),
                "jobs".into(),
                "status".into(),
                "--job-id".into(),
                archive_job_id,
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            let archive_job_completed = json_payload(&archive_job_completed);
            assert_eq!(archive_job_completed["status"], "completed");
            assert_eq!(archive_job_completed["eventConsistency"]["ok"], true);

            let curation = execute_cli(vec![
                "snapshots".into(),
                "curation".into(),
                "start".into(),
                "--topic".into(),
                "dispatch topic".into(),
                "--agent".into(),
                "codex".into(),
                "--home-dir".into(),
                home.display().to_string(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            let curation = json_payload(&curation);
            assert_eq!(curation["status"], "started");
            let session_id = curation["curationSessionId"].as_str().unwrap().to_string();

            let candidates = execute_cli(vec![
                "snapshots".into(),
                "curation".into(),
                "candidates".into(),
                "list".into(),
                "--curation-session-id".into(),
                session_id.clone(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&candidates)["status"], "listed");

            let submitted = execute_cli(vec![
                "snapshots".into(),
                "curation".into(),
                "submit-result".into(),
                "--curation-session-id".into(),
                session_id,
                "--curation-result-json".into(),
                r#"{"selectedCandidateIds":[]}"#.into(),
                "--state-root".into(),
                state_root.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&submitted)["status"], "submitted");
        }
    }

    #[test]
    fn cli_dispatches_gap_closure_client_surfaces() {
        let dir = temp_cli_dir("gap-client-surfaces");
        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);

            let added = execute_cli(vec![
                "source-queue".into(),
                "add".into(),
                "--text".into(),
                "source queue text".into(),
                "--source-type".into(),
                "manual-text".into(),
                "--provider-id".into(),
                "test".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&added)["status"], "enqueued");

            let paused = execute_cli(vec!["source-queue".into(), "pause".into()]).unwrap();
            assert_eq!(json_payload(&paused)["paused"], true);
            let resumed = execute_cli(vec!["source-queue".into(), "resume".into()]).unwrap();
            assert_eq!(json_payload(&resumed)["paused"], false);
            let drained = execute_cli(vec!["source-queue".into(), "drain".into()]).unwrap();
            assert_eq!(json_payload(&drained)["deferred"], 1);

            let source_dir = dir.join("local-source");
            fs::create_dir_all(&source_dir).unwrap();
            fs::write(source_dir.join("note.txt"), "connector file").unwrap();
            let connectors = execute_cli(vec!["connectors".into(), "list".into()]).unwrap();
            assert_eq!(
                json_payload(&connectors)["connectors"]
                    .as_array()
                    .unwrap()
                    .len(),
                4
            );
            let synced = execute_cli(vec![
                "connectors".into(),
                "sync".into(),
                "--connector".into(),
                "local-directory".into(),
                "--path".into(),
                source_dir.display().to_string(),
            ])
            .unwrap();
            assert_eq!(json_payload(&synced)["status"], "enqueued");
            let mirror =
                execute_cli(vec!["connectors".into(), "mirror".into(), "inspect".into()]).unwrap();
            assert_eq!(
                json_payload(&mirror)["entries"].as_array().unwrap().len(),
                1
            );

            let synced_cache = execute_cli(vec![
                "knowledge-cache".into(),
                "sync".into(),
                "--evidence-json".into(),
                r#"{"id":"ev-1","title":"Queue recovery","text":"Source queue resumes uploads"}"#
                    .into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&synced_cache)["upserted"], 1);
            let searched = execute_cli(vec![
                "knowledge-cache".into(),
                "search".into(),
                "--query".into(),
                "queue".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&searched)["authoritative"], false);

            let mail_preview = execute_cli(vec![
                "mail".into(),
                "preview".into(),
                "--mailbox".into(),
                "Inbox".into(),
                "--since".into(),
                "2026-06-01".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&mail_preview)["status"], "preview_ready");
            let mail_enqueue = execute_cli(vec![
                "mail".into(),
                "enqueue".into(),
                "--mailbox".into(),
                "Inbox".into(),
                "--since".into(),
                "2026-06-01".into(),
            ])
            .unwrap();
            assert_eq!(json_payload(&mail_enqueue)["status"], "enqueued");

            let bridge_plan = execute_cli(vec!["mcp-local-bridge".into(), "plan".into()]).unwrap();
            assert_eq!(json_payload(&bridge_plan)["directServiceHubStdio"], false);
            let bridge_register =
                execute_cli(vec!["mcp-local-bridge".into(), "register".into()]).unwrap();
            assert_eq!(
                json_payload(&bridge_register)["status"],
                "registration_planned"
            );
        }
    }

    #[test]
    fn cli_dispatches_local_runtime_status_before_start() {
        let dir = temp_cli_dir("local-runtime-status");
        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);
            let status = execute_cli(vec!["local-runtime".into(), "status".into()]).unwrap();
            let payload = json_payload(&status);
            assert_eq!(payload["ok"], true);
            assert_eq!(payload["status"], "stopped");
        }
    }

    #[test]
    fn cli_dispatches_help_and_error_paths() {
        let dir = temp_cli_dir("dispatch-errors");

        {
            let _guard = cli_env_lock().lock().unwrap();
            let _portable = set_portable_dir(&dir);

            let empty = execute_cli(vec![]);
            assert!(matches!(
                empty.unwrap(),
                lico_client_native::commands::CliExecution::Usage
            ));

            let help = execute_cli(vec!["help".into()]);
            assert!(matches!(
                help.unwrap(),
                lico_client_native::commands::CliExecution::Usage
            ));

            let flag_help = execute_cli(vec!["--help".into()]);
            assert!(matches!(
                flag_help.unwrap(),
                lico_client_native::commands::CliExecution::Usage
            ));

            let unknown = execute_cli(vec!["unknown".into()]);
            assert!(matches!(
                unknown.unwrap(),
                lico_client_native::commands::CliExecution::Usage
            ));

            let bad_state =
                execute_cli(vec!["state".into(), "get".into(), "does-not-exist".into()]);
            assert!(bad_state.is_err());

            let bad_forward = execute_cli(vec!["forward".into(), "--text".into(), "ping".into()]);
            assert!(bad_forward.is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn cli_dispatches_agent_message_send_runtime_adapter() {
        let dir = temp_cli_dir("dispatch-runtime");
        let script = dir.join("echo-agent.sh");
        fs::write(&script, "#!/bin/sh\nprintf 'cli-runtime:%s' \"$1\"\n").unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).unwrap();

        let result = execute_cli(vec![
            "agent".into(),
            "message".into(),
            "send".into(),
            "--agent".into(),
            "codex".into(),
            "--text".into(),
            "hello-cli-runtime".into(),
            "--command".into(),
            script.display().to_string(),
            "--args".into(),
            r#"["{prompt}"]"#.into(),
            "--timeout-ms".into(),
            "5000".into(),
        ])
        .unwrap();

        let payload = json_payload(&result);
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["mode"], "runtime-adapter");
        assert_eq!(payload["runtimeProtocol"], "configured-command");
        assert_eq!(payload["output"], "cli-runtime:hello-cli-runtime");
    }

    #[test]
    fn cli_parse_json_args_and_keys() {
        use lico_client_native::commands;
        assert_eq!(commands::parse_json_arg("{\"x\":1}")["x"], json!(1));
        assert_eq!(commands::parse_json_arg("bad json"), json!({}));
        let params = commands::cli_params(&[
            "--target".into(),
            "opencode".into(),
            "alpha".into(),
            "--dry-run".into(),
            "false".into(),
        ]);
        assert_eq!(params["target"], "opencode");
        assert_eq!(params["dryRun"], "false");

        let bare_flag = commands::cli_params(&["--dry-run".into()]);
        assert_eq!(bare_flag["dryRun"], true);
    }

    fn set_portable_dir(path: &Path) -> PortableDirGuard {
        PortableDirGuard::set(path)
    }

    fn json_payload(result: &lico_client_native::commands::CliExecution) -> &Value {
        match result {
            lico_client_native::commands::CliExecution::Json(value) => value,
            lico_client_native::commands::CliExecution::Usage => panic!("expected json result"),
        }
    }

    fn temp_cli_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-client-native-test-{}-{}-{}",
            name,
            now.as_secs(),
            now.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn cli_env_lock() -> &'static std::sync::Mutex<()> {
        static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
    }

    struct PortableDirGuard {
        previous: Option<PathBuf>,
    }

    impl PortableDirGuard {
        fn set(path: &Path) -> Self {
            let previous =
                lico_client_native::paths::set_portable_data_dir_override(Some(path.to_path_buf()));
            Self { previous }
        }
    }

    impl Drop for PortableDirGuard {
        fn drop(&mut self) {
            lico_client_native::paths::set_portable_data_dir_override(self.previous.take());
        }
    }
}
