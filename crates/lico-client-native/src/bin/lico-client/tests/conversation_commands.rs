use super::support::*;
use super::*;

#[test]
fn cli_dispatches_native_conversation_snapshot_commands() {
    let dir = temp_cli_dir("dispatch-conversation-snapshots");
    let state_root = dir.join("client-state");
    let snapshot_root = dir.join("conversation-snapshot-root");
    let archive_root = dir.join("conversation-archive-root");
    let home = dir.join("home");
    let codex_history = home.join(".codex");
    fs::create_dir_all(&codex_history).unwrap();
    fs::write(
            codex_history.join("history.jsonl"),
            r#"{"sessionId":"dispatch-archive","role":"user","content":"Dispatch LicoMesh conversation archive"}"#,
        )
        .unwrap();
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

        let collect = execute_cli(vec![
            "snapshots".into(),
            "collect".into(),
            "--topic".into(),
            "LicoMesh".into(),
            "--agent".into(),
            "codex".into(),
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
            "licomesh".into(),
            "--display-name".into(),
            "LicoMesh".into(),
            "--archive-root".into(),
            archive_root.display().to_string(),
            "--canonical-names".into(),
            "LicoMesh".into(),
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
            "licomesh".into(),
            "--state-root".into(),
            state_root.display().to_string(),
        ])
        .unwrap();
        assert_eq!(
            json_payload(&profile_get)["profile"]["profileId"],
            "licomesh"
        );

        let archive_run = execute_cli(vec![
            "snapshots".into(),
            "archive".into(),
            "run".into(),
            "--profile".into(),
            "licomesh".into(),
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
            "licomesh".into(),
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
            "licomesh".into(),
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
            "LicoMesh".into(),
            "--path".into(),
            archive_root.display().to_string(),
            "--agent".into(),
            "codex".into(),
            "--home-dir".into(),
            home.display().to_string(),
            "--state-root".into(),
            state_root.display().to_string(),
        ])
        .unwrap();
        assert_eq!(json_payload(&keyword_archive)["status"], "archived");

        let archive_plan = execute_cli(vec![
            "snapshots".into(),
            "archive".into(),
            "jobs".into(),
            "preview".into(),
            "--selection-mode".into(),
            "exact-keyword".into(),
            "--query".into(),
            "LicoMesh".into(),
            "--path".into(),
            archive_root.display().to_string(),
            "--agent".into(),
            "codex".into(),
            "--home-dir".into(),
            home.display().to_string(),
            "--state-root".into(),
            state_root.display().to_string(),
        ])
        .unwrap();
        let plan_binding = json_payload(&archive_plan)["plan"]["binding"]
            .as_str()
            .unwrap()
            .to_string();

        let archive_job = execute_cli(vec![
            "snapshots".into(),
            "archive".into(),
            "jobs".into(),
            "create".into(),
            "--selection-mode".into(),
            "exact-keyword".into(),
            "--query".into(),
            "LicoMesh".into(),
            "--path".into(),
            archive_root.display().to_string(),
            "--agent".into(),
            "codex".into(),
            "--home-dir".into(),
            home.display().to_string(),
            "--state-root".into(),
            state_root.display().to_string(),
            "--plan-binding".into(),
            plan_binding,
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
    }
}
