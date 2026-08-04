use super::support::*;

#[test]
fn cli_dispatches_agent_pairing_and_skill_paths() {
    let dir = temp_cli_dir("dispatch-pairing-skill");
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
        assert_eq!(json_payload(&requested)["status"], "approved");

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
        assert_eq!(json_payload(&get_unavailable)["error"], "not_found");

        let visibility = execute_cli(vec![
            "skill".into(),
            "visibility".into(),
            "set".into(),
            "review".into(),
            "--agent".into(),
            "codex".into(),
            "--hidden".into(),
            "true".into(),
        ])
        .unwrap();
        assert_eq!(json_payload(&visibility)["hidden"], true);
        assert_eq!(json_payload(&visibility)["skillId"], "review");

        let pin = execute_cli(vec![
            "skill".into(),
            "pin".into(),
            "set".into(),
            "review".into(),
            "--agent".into(),
            "codex".into(),
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
    }
}

#[test]
fn cli_dispatches_skill_usage_scan_and_report_with_all_time_totals() {
    let dir = temp_cli_dir("skill-usage-scan");
    let history = dir.join("history");
    std::fs::create_dir_all(&history).unwrap();
    std::fs::write(
        history.join("session.jsonl"),
        concat!(
            "{\"type\":\"assistant\",\"timestamp\":\"2026-07-14T00:00:02Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu-a\",\"name\":\"Skill\",\"input\":{\"skill\":\"lint-fix\"}}]}}\n",
            "{\"type\":\"assistant\",\"timestamp\":\"2026-07-14T00:00:03Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu-b\",\"name\":\"Skill\",\"input\":{\"skill\":\"lint-fix\"}}]}}\n"
        ),
    )
    .unwrap();
    {
        let _guard = cli_env_lock().lock().unwrap();
        let _portable = set_portable_dir(&dir);

        let scan_args = || {
            vec![
                "skill".into(),
                "usage".into(),
                "scan".into(),
                "--agent".into(),
                "claude-code".into(),
                "--history-root".into(),
                history.to_string_lossy().to_string(),
            ]
        };
        let scan = execute_cli(scan_args()).unwrap();
        assert_eq!(json_payload(&scan)["ok"], true);
        assert_eq!(json_payload(&scan)["invocationsAdded"], 2);
        assert_eq!(json_payload(&scan)["filesScanned"], 1);
        assert_eq!(json_payload(&scan)["agents"][0]["agentId"], "claude-code");
        assert_eq!(
            json_payload(&scan)["watermark"]["sourceKind"],
            "skill-usage-scan-source"
        );

        // A second scan is idempotent: the unchanged watermark skips the file.
        let rescan = execute_cli(scan_args()).unwrap();
        assert_eq!(json_payload(&rescan)["invocationsAdded"], 0);
        assert_eq!(json_payload(&rescan)["filesUnchanged"], 1);

        let report = execute_cli(vec![
            "skill".into(),
            "usage".into(),
            "report".into(),
            "--agent".into(),
            "claude-code".into(),
            "--from".into(),
            "2026-07-14".into(),
            "--to".into(),
            "2026-07-14".into(),
        ])
        .unwrap();
        assert_eq!(json_payload(&report)["totalInvocations"], 2);
        assert_eq!(json_payload(&report)["allTimeInvocations"], 2);
        assert_eq!(
            json_payload(&report)["totalsBySkill"][0]["skillId"],
            "lint-fix"
        );
        assert_eq!(json_payload(&report)["totalsBySkill"][0]["count"], 2);
    }
}
