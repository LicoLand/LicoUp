use super::support::*;
use super::*;

#[test]
fn cli_dispatches_help_and_error_paths() {
    let dir = temp_cli_dir("dispatch-errors");

    {
        let _guard = cli_env_lock().lock().unwrap();
        let _portable = set_portable_dir(&dir);

        let empty = execute_cli(vec![]);
        assert!(empty.is_err());

        let help = execute_cli(vec!["help".into()]);
        assert!(matches!(
            help.unwrap(),
            licoup_native::ffi::commands::CliExecution::Usage
        ));

        let flag_help = execute_cli(vec!["--help".into()]);
        assert!(matches!(
            flag_help.unwrap(),
            licoup_native::ffi::commands::CliExecution::Usage
        ));

        let unknown = execute_cli(vec!["unknown".into()]);
        assert!(unknown.is_err());

        let bad_state = execute_cli(vec!["state".into(), "get".into(), "does-not-exist".into()]);
        assert!(bad_state.is_err());
    }
}

#[test]
fn cli_parse_json_args_and_keys() {
    use licoup_native::ffi::commands;
    assert_eq!(
        commands::parse_json_arg("{\"x\":1}").unwrap()["x"],
        json!(1)
    );
    assert!(commands::parse_json_arg("bad json").is_err());
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
