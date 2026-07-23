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
    }
}
