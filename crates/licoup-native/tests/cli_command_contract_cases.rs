//! Frozen acceptance cases for native CLI command admission.
//!
//! The Better Plan acceptance designer owns the executable cases in this file.

use anyhow::Error;
use licoup_native::ffi::commands::{
    AdmittedCommand, CliCommandError, CliCommandSchema, CliExecution, CommandCardinality,
    OptionArity, OptionConstraintKind, RequiredArgumentKind, admit_cli_command,
    cli_command_schemas, execute_cli,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const ADMISSION_STAGE: &str = "cli/admission";
const ADMISSION_COMPONENT: &str = "native_cli";
const MAX_CLI_ARGUMENT_COUNT: usize = 4_096;
const MAX_CLI_ARGUMENT_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug)]
struct RouteAuthority {
    module: &'static str,
    handler: &'static str,
    path: &'static str,
    required: &'static [(&'static str, RequiredArgumentKind)],
    cardinality: CommandCardinality,
    options: Vec<OptionAuthority>,
    constraints: &'static [ConstraintAuthority],
}

#[derive(Clone, Copy, Debug)]
struct OptionAuthority {
    name: &'static str,
    arity: OptionArity,
    repeatable: bool,
    value_kind: RequiredArgumentKind,
    required: bool,
}

#[derive(Clone, Copy, Debug)]
struct ConstraintAuthority {
    kind: OptionConstraintKind,
    members: &'static [&'static str],
    condition_option: Option<&'static str>,
    condition_value: Option<&'static str>,
    required_option: Option<&'static str>,
}

#[derive(Clone, Copy)]
struct ExpectedAdmission {
    code: &'static str,
    recovery: &'static str,
}

const MISSING_COMMAND: ExpectedAdmission = ExpectedAdmission {
    code: "cli_command_missing",
    recovery: "use_cli_help",
};
const UNKNOWN_COMMAND: ExpectedAdmission = ExpectedAdmission {
    code: "cli_command_unknown",
    recovery: "use_cli_help",
};
const UNSUPPORTED_OPERATION: ExpectedAdmission = ExpectedAdmission {
    code: "cli_operation_unsupported",
    recovery: "use_cli_help",
};
const MISSING_ARGUMENT: ExpectedAdmission = ExpectedAdmission {
    code: "cli_required_argument_missing",
    recovery: "correct_command_arguments",
};
const UNEXPECTED_ARGUMENT: ExpectedAdmission = ExpectedAdmission {
    code: "cli_argument_unexpected",
    recovery: "correct_command_arguments",
};
const UNKNOWN_OPTION: ExpectedAdmission = ExpectedAdmission {
    code: "cli_option_unknown",
    recovery: "correct_command_arguments",
};
const MISSING_OPTION: ExpectedAdmission = ExpectedAdmission {
    code: "cli_required_option_missing",
    recovery: "correct_command_arguments",
};
const MISSING_OPTION_VALUE: ExpectedAdmission = ExpectedAdmission {
    code: "cli_option_value_missing",
    recovery: "correct_command_arguments",
};
const DUPLICATE_OPTION: ExpectedAdmission = ExpectedAdmission {
    code: "cli_option_duplicate",
    recovery: "correct_command_arguments",
};
const OPTION_CONSTRAINT: ExpectedAdmission = ExpectedAdmission {
    code: "cli_option_constraint_violation",
    recovery: "correct_command_arguments",
};
const INVALID_JSON: ExpectedAdmission = ExpectedAdmission {
    code: "cli_json_invalid",
    recovery: "provide_valid_json",
};
const ARGUMENT_COUNT_EXCEEDED: ExpectedAdmission = ExpectedAdmission {
    code: "cli_argument_count_exceeded",
    recovery: "reduce_command_arguments",
};
const ARGUMENT_BYTES_EXCEEDED: ExpectedAdmission = ExpectedAdmission {
    code: "cli_argument_bytes_exceeded",
    recovery: "reduce_command_arguments",
};

#[test]
fn exact_help_is_the_only_successful_usage_dispatch() {
    for args in [["help"], ["--help"], ["-h"]] {
        assert_eq!(
            execute_cli(strings(args)).expect("an exact help route must succeed"),
            CliExecution::Usage,
            "exact help route {args:?} must be the Usage success"
        );
    }

    let cases = [
        ("empty", Vec::new(), MISSING_COMMAND),
        (
            "help with an extra positional",
            strings(["help", "private-extra-cli-oracle"]),
            UNEXPECTED_ARGUMENT,
        ),
        (
            "state get with an extra positional",
            strings(["state", "get", "settings", "private-extra-cli-oracle"]),
            UNEXPECTED_ARGUMENT,
        ),
    ];

    for (label, args, expected) in cases {
        let error = execute_cli(args).expect_err(label);
        assert_admission_error(
            &error,
            expected,
            &[
                "private-route-cli-oracle",
                "private-action-cli-oracle",
                "private-extra-cli-oracle",
            ],
        );
    }

    assert_private_failure_pair(
        "unknown top-level route",
        strings(["private-alpha-route-731"]),
        strings(["private-bravo-route-947"]),
        UNKNOWN_COMMAND,
        &["private-alpha", "route-731", "private-bravo", "route-947"],
    );
}

#[test]
fn readonly_registry_projection_exactly_matches_public_help_authority() {
    let expected = route_authorities();
    let projected = cli_command_schemas();
    assert_eq!(projected.len(), expected.len());

    let expected_by_path = expected
        .into_iter()
        .map(|route| (route.path, route))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(
        expected_by_path.len(),
        120,
        "public help authority must not contain duplicate routes"
    );
    let projected_by_path = projected
        .iter()
        .map(|schema| (schema.path().join(" "), schema))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(
        projected_by_path.len(),
        projected.len(),
        "runtime registry projection must not contain duplicate routes"
    );
    assert_eq!(
        projected_by_path
            .keys()
            .map(|path| path.as_str())
            .collect::<Vec<_>>(),
        expected_by_path.keys().copied().collect::<Vec<_>>(),
        "runtime registry must contain every and only public-help routes"
    );
    for (path, expected) in expected_by_path {
        assert_projected_schema(
            projected_by_path
                .get(path)
                .expect("projected route must exist"),
            &expected,
        );
    }
}

#[test]
fn stdin_json_routes_freeze_value_json_admission() {
    for (path, required) in [
        ("mcp http preview", true),
        ("mcp http execute", true),
        ("agent conversation open", false),
        ("agent conversation send", false),
        ("agent conversation steer", false),
        ("agent conversation cancel", false),
        ("agent conversation cleanup", false),
        ("agent conversation capabilities", false),
        ("agent conversation stream", false),
    ] {
        let route = route_authorities()
            .into_iter()
            .find(|route| route.path == path)
            .unwrap_or_else(|| panic!("missing frozen --stdin-json route {path}"));
        let option = route
            .options
            .iter()
            .find(|option| option.name == "stdin-json")
            .unwrap_or_else(|| panic!("{path} must expose --stdin-json"));
        assert_eq!(option.arity, OptionArity::Value);
        assert_eq!(option.value_kind, RequiredArgumentKind::Json);
        assert_eq!(option.required, required);
        assert!(!option.repeatable);
    }
}

#[test]
fn every_authoritative_route_is_admitted_without_executing_its_handler() {
    let authority = route_authorities();
    assert_eq!(
        authority.len(),
        120,
        "the public presentation help must expand to exactly 120 routes"
    );

    for route in authority {
        let path = strings(route.path.split_ascii_whitespace());
        let required_values = route
            .required
            .iter()
            .map(|(name, kind)| match kind {
                RequiredArgumentKind::Text => format!("accepted-{name}"),
                RequiredArgumentKind::Json => {
                    format!(r#"{{"oracle":"accepted-{name}"}}"#)
                }
            })
            .collect::<Vec<_>>();
        let mut minimum = path.clone();
        minimum.extend(required_values.iter().cloned());

        let mut insufficient = minimum.clone();
        insufficient
            .pop()
            .expect("every authority route has at least one literal path token");
        let insufficient_error = admit_cli_command(insufficient)
            .expect_err("one token below the route minimum must fail admission");
        assert_admission_error(&insufficient_error, MISSING_ARGUMENT, &[]);

        let mut valid = minimum.clone();
        let mut present_options = route
            .options
            .iter()
            .filter(|option| option.required)
            .copied()
            .collect::<Vec<_>>();
        for constraint in route.constraints {
            if matches!(
                constraint.kind,
                OptionConstraintKind::OneOf | OptionConstraintKind::AtLeastOne
            ) {
                let seed = route
                    .options
                    .iter()
                    .find(|option| Some(option.name) == constraint.members.first().copied())
                    .expect("constraint member must name a documented option");
                if !present_options
                    .iter()
                    .any(|option| option.name == seed.name)
                {
                    present_options.push(*seed);
                }
            }
        }
        for option in &present_options {
            append_option(&mut valid, *option);
        }
        let admitted = admit_cli_command(valid.clone())
            .expect("the route's documented minimum schema must be admitted");
        assert_admitted_route(&admitted, &route, &required_values, &present_options);

        for required in route.options.iter().filter(|option| option.required) {
            let mut omitted = minimum.clone();
            for option in present_options
                .iter()
                .filter(|option| option.name != required.name)
            {
                append_option(&mut omitted, *option);
            }
            assert_admission_error(
                &admit_cli_command(omitted)
                    .expect_err("every required option omission must fail admission"),
                MISSING_OPTION,
                &[],
            );
        }

        let mut unknown = valid.clone();
        unknown.push("--private-unknown-option".to_string());
        assert_admission_error(
            &admit_cli_command(unknown).expect_err("unknown options must fail admission"),
            UNKNOWN_OPTION,
            &["private-unknown-option"],
        );

        let mut positional = valid.clone();
        positional.push("private-extra-positional".to_string());
        assert_admission_error(
            &admit_cli_command(positional)
                .expect_err("undocumented trailing positionals must fail admission"),
            UNEXPECTED_ARGUMENT,
            &["private-extra-positional"],
        );

        if let Some(representative) = route.options.iter().find(|option| {
            !option.required
                && !present_options
                    .iter()
                    .any(|present| present.name == option.name)
                && !route.constraints.iter().any(|constraint| {
                    matches!(
                        constraint.kind,
                        OptionConstraintKind::OneOf | OptionConstraintKind::MutuallyExclusive
                    ) && constraint.members.contains(&option.name)
                        && present_options
                            .iter()
                            .any(|present| constraint.members.contains(&present.name))
                })
        }) {
            let mut with_option = valid.clone();
            append_option(&mut with_option, *representative);
            let admitted = admit_cli_command(with_option).unwrap_or_else(|error| {
                panic!(
                    "documented representative option for {} must be admitted: {error}",
                    route.path
                )
            });
            let mut present = present_options.clone();
            present.push(*representative);
            assert_admitted_route(&admitted, &route, &required_values, &present);
        }

        for option in &route.options {
            if option.arity == OptionArity::Value {
                let mut missing_value = minimum.clone();
                for required in route
                    .options
                    .iter()
                    .filter(|required| required.required && required.name != option.name)
                {
                    append_option(&mut missing_value, *required);
                }
                missing_value.push(format!("--{}", option.name));
                assert_admission_error(
                    &admit_cli_command(missing_value)
                        .expect_err("value options must reject a missing value"),
                    MISSING_OPTION_VALUE,
                    &[],
                );
            }

            if !option.repeatable {
                let mut duplicate = valid.clone();
                if !option.required {
                    append_option(&mut duplicate, *option);
                }
                append_option(&mut duplicate, *option);
                assert_admission_error(
                    &admit_cli_command(duplicate)
                        .expect_err("non-repeatable options must reject duplicates"),
                    DUPLICATE_OPTION,
                    &[],
                );
            }

            if option.value_kind == RequiredArgumentKind::Json {
                let mut malformed = minimum.clone();
                for required in route
                    .options
                    .iter()
                    .filter(|required| required.required && required.name != option.name)
                {
                    append_option(&mut malformed, *required);
                }
                malformed.extend([
                    format!("--{}", option.name),
                    r#"{"private":"malformed-option""#.to_string(),
                ]);
                assert_admission_error(
                    &admit_cli_command(malformed)
                        .expect_err("typed JSON options must reject malformed JSON"),
                    INVALID_JSON,
                    &["malformed-option"],
                );
            }
        }
        for constraint in route.constraints {
            let invalid =
                constraint_violation_args(&route, &minimum, &present_options, *constraint);
            assert_admission_error(
                &admit_cli_command(invalid)
                    .expect_err("each documented option relationship must fail closed"),
                OPTION_CONSTRAINT,
                &[],
            );
        }
    }
}

#[test]
fn command_argument_limits_have_exact_boundaries_and_count_precedes_bytes() {
    for canary in ["private-alpha-count-731", "private-bravo-count-947"] {
        let allowed = counted_unknown_route(MAX_CLI_ARGUMENT_COUNT, canary, false);
        let allowed_error =
            execute_cli(allowed).expect_err("exactly 4096 arguments must pass bounds admission");
        assert_admission_error(
            &allowed_error,
            UNKNOWN_COMMAND,
            &[canary, canary.split('-').next_back().unwrap_or_default()],
        );
    }
    let count_alpha = execute_cli(counted_unknown_route(
        MAX_CLI_ARGUMENT_COUNT + 1,
        "private-alpha-count-731",
        false,
    ))
    .expect_err("4097 arguments must exceed the count bound");
    let count_bravo = execute_cli(counted_unknown_route(
        MAX_CLI_ARGUMENT_COUNT + 1,
        "private-bravo-count-947",
        false,
    ))
    .expect_err("4097 arguments must exceed the count bound");
    assert_equivalent_private_errors(
        &count_alpha,
        &count_bravo,
        ARGUMENT_COUNT_EXCEEDED,
        &["private-alpha", "count-731", "private-bravo", "count-947"],
    );

    let byte_alpha = exact_byte_argument("private-alpha-byte-731", MAX_CLI_ARGUMENT_BYTES);
    let byte_bravo = exact_byte_argument("private-bravo-byte-947", MAX_CLI_ARGUMENT_BYTES);
    let allowed_alpha = execute_cli(vec![byte_alpha])
        .expect_err("an exact 2 MiB argument must pass byte admission");
    let allowed_bravo = execute_cli(vec![byte_bravo])
        .expect_err("an exact 2 MiB argument must pass byte admission");
    assert_equivalent_private_errors(
        &allowed_alpha,
        &allowed_bravo,
        UNKNOWN_COMMAND,
        &["private-alpha", "byte-731", "private-bravo", "byte-947"],
    );

    let utf8_exact_alpha =
        exact_multibyte_argument("private-alpha-utf8-731", MAX_CLI_ARGUMENT_BYTES);
    let utf8_exact_bravo =
        exact_multibyte_argument("private-bravo-utf8-947", MAX_CLI_ARGUMENT_BYTES);
    assert_eq!(utf8_exact_alpha.len(), MAX_CLI_ARGUMENT_BYTES);
    assert!(utf8_exact_alpha.chars().count() < utf8_exact_alpha.len());
    let utf8_allowed_alpha = admit_cli_command(vec![utf8_exact_alpha])
        .expect_err("exactly 2 MiB of multibyte UTF-8 must pass byte admission");
    let utf8_allowed_bravo = admit_cli_command(vec![utf8_exact_bravo])
        .expect_err("exactly 2 MiB of multibyte UTF-8 must pass byte admission");
    assert_equivalent_private_errors(
        &utf8_allowed_alpha,
        &utf8_allowed_bravo,
        UNKNOWN_COMMAND,
        &["private-alpha", "utf8-731", "private-bravo", "utf8-947"],
    );

    let utf8_oversized_alpha =
        exact_multibyte_argument("private-alpha-utf8-731", MAX_CLI_ARGUMENT_BYTES + 1);
    let utf8_oversized_bravo =
        exact_multibyte_argument("private-bravo-utf8-947", MAX_CLI_ARGUMENT_BYTES + 1);
    let utf8_error_alpha = admit_cli_command(vec![utf8_oversized_alpha])
        .expect_err("2 MiB + 1 byte of multibyte UTF-8 must fail byte admission");
    let utf8_error_bravo = admit_cli_command(vec![utf8_oversized_bravo])
        .expect_err("2 MiB + 1 byte of multibyte UTF-8 must fail byte admission");
    assert_equivalent_private_errors(
        &utf8_error_alpha,
        &utf8_error_bravo,
        ARGUMENT_BYTES_EXCEEDED,
        &["private-alpha", "utf8-731", "private-bravo", "utf8-947"],
    );

    for (label, alpha, bravo) in [
        (
            "oversized intermediate argument",
            vec![
                "private-alpha-route-731".to_string(),
                exact_byte_argument("private-alpha-middle-731", MAX_CLI_ARGUMENT_BYTES + 1),
                "tail".to_string(),
            ],
            vec![
                "private-bravo-route-947".to_string(),
                exact_byte_argument("private-bravo-middle-947", MAX_CLI_ARGUMENT_BYTES + 1),
                "tail".to_string(),
            ],
        ),
        (
            "oversized final argument",
            vec![
                "private-alpha-route-731".to_string(),
                "middle".to_string(),
                exact_byte_argument("private-alpha-final-731", MAX_CLI_ARGUMENT_BYTES + 1),
            ],
            vec![
                "private-bravo-route-947".to_string(),
                "middle".to_string(),
                exact_byte_argument("private-bravo-final-947", MAX_CLI_ARGUMENT_BYTES + 1),
            ],
        ),
    ] {
        let alpha_error = admit_cli_command(alpha).expect_err(label);
        let bravo_error = admit_cli_command(bravo).expect_err(label);
        assert_equivalent_private_errors(
            &alpha_error,
            &bravo_error,
            ARGUMENT_BYTES_EXCEEDED,
            &[
                "private-alpha",
                "middle-731",
                "final-731",
                "private-bravo",
                "middle-947",
                "final-947",
            ],
        );
    }

    let individually_bounded_alpha = vec![
        exact_byte_argument("private-alpha-total-a-731", MAX_CLI_ARGUMENT_BYTES),
        exact_byte_argument("private-alpha-total-b-731", MAX_CLI_ARGUMENT_BYTES),
    ];
    let individually_bounded_bravo = vec![
        exact_byte_argument("private-bravo-total-a-947", MAX_CLI_ARGUMENT_BYTES),
        exact_byte_argument("private-bravo-total-b-947", MAX_CLI_ARGUMENT_BYTES),
    ];
    let total_alpha = admit_cli_command(individually_bounded_alpha)
        .expect_err("aggregate size above 2 MiB must not become a total-byte rejection");
    let total_bravo = admit_cli_command(individually_bounded_bravo)
        .expect_err("aggregate size above 2 MiB must not become a total-byte rejection");
    assert_equivalent_private_errors(
        &total_alpha,
        &total_bravo,
        UNKNOWN_COMMAND,
        &[
            "private-alpha",
            "total-a-731",
            "total-b-731",
            "private-bravo",
            "total-a-947",
            "total-b-947",
        ],
    );

    let oversized_alpha = exact_byte_argument("private-alpha-byte-731", MAX_CLI_ARGUMENT_BYTES + 1);
    let oversized_bravo = exact_byte_argument("private-bravo-byte-947", MAX_CLI_ARGUMENT_BYTES + 1);
    let byte_error_alpha = execute_cli(vec![oversized_alpha])
        .expect_err("a 2 MiB + 1 byte argument must exceed the byte bound");
    let byte_error_bravo = execute_cli(vec![oversized_bravo])
        .expect_err("a 2 MiB + 1 byte argument must exceed the byte bound");
    assert_equivalent_private_errors(
        &byte_error_alpha,
        &byte_error_bravo,
        ARGUMENT_BYTES_EXCEEDED,
        &["private-alpha", "byte-731", "private-bravo", "byte-947"],
    );

    let priority_alpha = execute_cli(counted_unknown_route(
        MAX_CLI_ARGUMENT_COUNT + 1,
        "private-alpha-priority-731",
        true,
    ))
    .expect_err("combined overflow must fail");
    let priority_bravo = execute_cli(counted_unknown_route(
        MAX_CLI_ARGUMENT_COUNT + 1,
        "private-bravo-priority-947",
        true,
    ))
    .expect_err("combined overflow must fail");
    assert_equivalent_private_errors(
        &priority_alpha,
        &priority_bravo,
        ARGUMENT_COUNT_EXCEEDED,
        &[
            "private-alpha",
            "priority-731",
            "private-bravo",
            "priority-947",
        ],
    );
}

#[test]
fn every_direct_index_command_family_rejects_missing_route_tokens_without_panicking() {
    let cases: &[(&str, &[&str])] = &[
        ("state get collection", &["state", "get"]),
        ("state set collection and payload", &["state", "set"]),
        ("state set payload", &["state", "set", "settings"]),
        ("agent conversation operation", &["agent", "conversation"]),
        ("agent pairing operation", &["agents", "pair"]),
        ("target inspect target", &["targets", "inspect"]),
        ("OpenCode serve action", &["opencode-serve"]),
        ("snapshot restore identifier", &["snapshots", "restore"]),
        ("snapshot root action", &["snapshots", "root"]),
        ("snapshot profile action", &["snapshots", "profiles"]),
        ("snapshot archive action", &["snapshots", "archive"]),
        (
            "snapshot archive job action",
            &["snapshots", "archive", "jobs"],
        ),
        ("conversation action", &["conversations"]),
        ("mobile relay noun and action", &["mobile", "relay"]),
        ("mobile relay action", &["mobile", "relay", "config"]),
    ];

    for (label, args) in cases {
        let error = execute_cli(strings(args.iter().copied())).expect_err(label);
        assert_admission_error(&error, MISSING_ARGUMENT, &[]);
    }
}

#[test]
fn unsupported_dynamic_family_actions_are_typed_failures_instead_of_usage() {
    let cases: &[(&str, &[&str])] = &[
        ("agent pairing", &["agents", "pair"]),
        ("snapshot root", &["snapshots", "root"]),
        ("snapshot profiles", &["snapshots", "profiles"]),
        ("snapshot archive", &["snapshots", "archive"]),
        ("snapshot archive jobs", &["snapshots", "archive", "jobs"]),
        ("conversation", &["conversations"]),
        ("OpenCode serve", &["opencode-serve"]),
        ("mobile relay", &["mobile", "relay", "config"]),
    ];

    for (label, prefix) in cases {
        let mut alpha = strings(prefix.iter().copied());
        alpha.push("private-alpha-action-731".to_string());
        let mut bravo = strings(prefix.iter().copied());
        bravo.push("private-bravo-action-947".to_string());
        assert_private_failure_pair(
            label,
            alpha,
            bravo,
            UNSUPPORTED_OPERATION,
            &["private-alpha", "action-731", "private-bravo", "action-947"],
        );
    }
}

#[test]
fn real_binary_admission_failures_do_not_emit_private_arguments() {
    let cases = [
        (
            "unknown",
            strings(["private-alpha-binary-unknown-731"]),
            strings(["private-bravo-binary-unknown-947"]),
            "private-alpha-binary-unknown-731",
            "private-bravo-binary-unknown-947",
        ),
        (
            "unsupported operation",
            strings(["state", "private-alpha-binary-action-731"]),
            strings(["state", "private-bravo-binary-action-947"]),
            "private-alpha-binary-action-731",
            "private-bravo-binary-action-947",
        ),
        (
            "unexpected argument",
            strings(["state", "get", "settings", "private-alpha-binary-extra-731"]),
            strings(["state", "get", "settings", "private-bravo-binary-extra-947"]),
            "private-alpha-binary-extra-731",
            "private-bravo-binary-extra-947",
        ),
        (
            "malformed JSON",
            strings([
                "state",
                "set",
                "settings",
                r#"{"private":"private-alpha-binary-json-731""#,
            ]),
            strings([
                "state",
                "set",
                "settings",
                r#"{"private":"private-bravo-binary-json-947""#,
            ]),
            "private-alpha-binary-json-731",
            "private-bravo-binary-json-947",
        ),
        (
            "argument count overflow",
            counted_unknown_route(
                MAX_CLI_ARGUMENT_COUNT + 1,
                "private-alpha-binary-count-731",
                false,
            ),
            counted_unknown_route(
                MAX_CLI_ARGUMENT_COUNT + 1,
                "private-bravo-binary-count-947",
                false,
            ),
            "private-alpha-binary-count-731",
            "private-bravo-binary-count-947",
        ),
    ];

    for (label, alpha_args, bravo_args, alpha_canary, bravo_canary) in cases {
        let alpha = run_lico_client(&alpha_args);
        let bravo = run_lico_client(&bravo_args);
        assert!(
            !alpha.status.success() && !bravo.status.success(),
            "{label} must remain a real binary admission failure"
        );
        let alpha_fragment = alpha_canary
            .rsplit("binary-")
            .next()
            .unwrap_or(alpha_canary);
        let bravo_fragment = bravo_canary
            .rsplit("binary-")
            .next()
            .unwrap_or(bravo_canary);
        let forbidden = [alpha_canary, bravo_canary, alpha_fragment, bravo_fragment];
        assert_process_output_redacted(&alpha, &forbidden, label);
        assert_process_output_redacted(&bravo, &forbidden, label);
        assert_eq!(alpha.stdout, bravo.stdout, "{label} stdout must be stable");
        assert_eq!(alpha.stderr, bravo.stderr, "{label} stderr must be stable");
    }

    let byte_alpha_canary = "private-alpha-binary-byte-731";
    let byte_bravo_canary = "private-bravo-binary-byte-947";
    let byte_alpha = run_lico_client_rpc(vec![exact_byte_argument(
        byte_alpha_canary,
        MAX_CLI_ARGUMENT_BYTES + 1,
    )]);
    let byte_bravo = run_lico_client_rpc(vec![exact_byte_argument(
        byte_bravo_canary,
        MAX_CLI_ARGUMENT_BYTES + 1,
    )]);
    assert_process_output_redacted(
        &byte_alpha,
        &[byte_alpha_canary, byte_bravo_canary, "byte-731", "byte-947"],
        "argument byte overflow",
    );
    assert_process_output_redacted(
        &byte_bravo,
        &[byte_alpha_canary, byte_bravo_canary, "byte-731", "byte-947"],
        "argument byte overflow",
    );
    assert_eq!(byte_alpha.stdout, byte_bravo.stdout);
    assert_eq!(byte_alpha.stderr, byte_bravo.stderr);
    for output in [&byte_alpha, &byte_bravo] {
        let line = std::str::from_utf8(&output.stdout)
            .expect("RPC stdout must be UTF-8")
            .lines()
            .find(|line| !line.trim().is_empty())
            .expect("RPC must return one line-delimited response");
        let response: Value = serde_json::from_str(line).expect("RPC response must be JSON");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], ARGUMENT_BYTES_EXCEEDED.code);
        assert_eq!(response["error"]["stage"], ADMISSION_STAGE);
        assert_eq!(response["error"]["component"], ADMISSION_COMPONENT);
        assert_eq!(response["error"]["retryable"], false);
        assert_eq!(
            response["error"]["recovery"],
            ARGUMENT_BYTES_EXCEEDED.recovery
        );
    }
}

#[test]
fn stdio_rpc_projects_every_admission_error_class_with_stable_metadata() {
    assert_rpc_admission_pair(
        "empty command",
        Vec::new(),
        Vec::new(),
        MISSING_COMMAND,
        &[],
    );
    assert_rpc_admission_pair(
        "missing required positional",
        strings(["state", "set", "private-alpha-rpc-missing-731"]),
        strings(["state", "set", "private-bravo-rpc-missing-947"]),
        MISSING_ARGUMENT,
        &[
            "private-alpha",
            "missing-731",
            "private-bravo",
            "missing-947",
        ],
    );
    assert_rpc_admission_pair(
        "missing required option",
        strings([
            "snapshots",
            "archive",
            "jobs",
            "create",
            "--selection-mode",
            "all",
            "--path",
            "private-alpha-rpc-required-731",
        ]),
        strings([
            "snapshots",
            "archive",
            "jobs",
            "create",
            "--selection-mode",
            "all",
            "--path",
            "private-bravo-rpc-required-947",
        ]),
        MISSING_OPTION,
        &[
            "private-alpha",
            "required-731",
            "private-bravo",
            "required-947",
        ],
    );
    assert_rpc_admission_pair(
        "unknown route",
        strings(["private-alpha-rpc-unknown-731"]),
        strings(["private-bravo-rpc-unknown-947"]),
        UNKNOWN_COMMAND,
        &[
            "private-alpha",
            "unknown-731",
            "private-bravo",
            "unknown-947",
        ],
    );
    assert_rpc_admission_pair(
        "unsupported operation",
        strings(["state", "private-alpha-rpc-action-731"]),
        strings(["state", "private-bravo-rpc-action-947"]),
        UNSUPPORTED_OPERATION,
        &["private-alpha", "action-731", "private-bravo", "action-947"],
    );
    assert_rpc_admission_pair(
        "unknown option",
        strings(["state", "get", "settings", "--private-alpha-rpc-option-731"]),
        strings(["state", "get", "settings", "--private-bravo-rpc-option-947"]),
        UNKNOWN_OPTION,
        &["private-alpha", "option-731", "private-bravo", "option-947"],
    );
    assert_rpc_admission_pair(
        "unexpected positional",
        strings(["state", "get", "settings", "private-alpha-rpc-extra-731"]),
        strings(["state", "get", "settings", "private-bravo-rpc-extra-947"]),
        UNEXPECTED_ARGUMENT,
        &["private-alpha", "extra-731", "private-bravo", "extra-947"],
    );
    assert_rpc_admission_pair(
        "missing option value",
        strings([
            "activity",
            "list",
            "--target",
            "private-alpha-rpc-value-731",
            "--limit",
        ]),
        strings([
            "activity",
            "list",
            "--target",
            "private-bravo-rpc-value-947",
            "--limit",
        ]),
        MISSING_OPTION_VALUE,
        &["private-alpha", "value-731", "private-bravo", "value-947"],
    );
    assert_rpc_admission_pair(
        "duplicate option",
        strings([
            "activity",
            "list",
            "--limit",
            "private-alpha-rpc-duplicate-731",
            "--limit",
            "private-alpha-rpc-duplicate-731",
        ]),
        strings([
            "activity",
            "list",
            "--limit",
            "private-bravo-rpc-duplicate-947",
            "--limit",
            "private-bravo-rpc-duplicate-947",
        ]),
        DUPLICATE_OPTION,
        &[
            "private-alpha",
            "duplicate-731",
            "private-bravo",
            "duplicate-947",
        ],
    );
    assert_rpc_admission_pair(
        "option constraint",
        strings([
            "skill",
            "delete",
            "plan",
            "--skill",
            "private-alpha-rpc-constraint-731",
        ]),
        strings([
            "skill",
            "delete",
            "plan",
            "--skill",
            "private-bravo-rpc-constraint-947",
        ]),
        OPTION_CONSTRAINT,
        &[
            "private-alpha",
            "constraint-731",
            "private-bravo",
            "constraint-947",
        ],
    );
    assert_rpc_admission_pair(
        "malformed JSON option",
        strings([
            "secure-mesh",
            "file",
            "route",
            "--manifest",
            r#"{"private":"private-alpha-rpc-json-731""#,
        ]),
        strings([
            "secure-mesh",
            "file",
            "route",
            "--manifest",
            r#"{"private":"private-bravo-rpc-json-947""#,
        ]),
        INVALID_JSON,
        &["private-alpha", "json-731", "private-bravo", "json-947"],
    );
    for route in [
        "mcp http preview",
        "mcp http execute",
        "agent conversation open",
        "agent conversation send",
        "agent conversation steer",
        "agent conversation cancel",
        "agent conversation cleanup",
        "agent conversation capabilities",
        "agent conversation stream",
    ] {
        let mut alpha = route
            .split_whitespace()
            .map(str::to_string)
            .collect::<Vec<_>>();
        alpha.extend(strings([
            "--stdin-json",
            r#"{"private":"private-alpha-rpc-stdin-json-731""#,
        ]));
        let mut bravo = route
            .split_whitespace()
            .map(str::to_string)
            .collect::<Vec<_>>();
        bravo.extend(strings([
            "--stdin-json",
            r#"{"private":"private-bravo-rpc-stdin-json-947""#,
        ]));
        assert_rpc_admission_pair(
            &format!("{route} malformed --stdin-json"),
            alpha,
            bravo,
            INVALID_JSON,
            &[
                "private-alpha",
                "stdin-json-731",
                "private-bravo",
                "stdin-json-947",
            ],
        );
    }
    assert_rpc_admission_pair(
        "argument count overflow",
        counted_unknown_route(
            MAX_CLI_ARGUMENT_COUNT + 1,
            "private-alpha-rpc-count-731",
            false,
        ),
        counted_unknown_route(
            MAX_CLI_ARGUMENT_COUNT + 1,
            "private-bravo-rpc-count-947",
            false,
        ),
        ARGUMENT_COUNT_EXCEEDED,
        &["private-alpha", "count-731", "private-bravo", "count-947"],
    );
    assert_rpc_admission_pair(
        "argument byte overflow",
        vec![exact_byte_argument(
            "private-alpha-rpc-byte-731",
            MAX_CLI_ARGUMENT_BYTES + 1,
        )],
        vec![exact_byte_argument(
            "private-bravo-rpc-byte-947",
            MAX_CLI_ARGUMENT_BYTES + 1,
        )],
        ARGUMENT_BYTES_EXCEEDED,
        &["private-alpha", "byte-731", "private-bravo", "byte-947"],
    );
}

#[test]
fn state_write_admission_is_bounded_atomic_and_redacted() {
    let _serial = cli_environment_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let portable_root = temporary_directory("cli-command-admission");
    let _portable = PortableDataOverride::set(&portable_root);

    let initial = json!({
        "items": [{
            "key": "cli-admission-oracle",
            "value": "original"
        }]
    });
    let replacement = json!({
        "items": [{
            "key": "cli-admission-oracle",
            "value": "replacement"
        }]
    });

    let baseline = state_set(&initial);
    assert_eq!(state_get(), baseline, "valid state set/get must round-trip");

    let missing_payload = execute_cli(strings(["state", "set", "settings"]))
        .expect_err("state set without a payload must fail admission");
    assert_admission_error(&missing_payload, MISSING_ARGUMENT, &[]);
    assert_state_unchanged(&baseline, "missing state-set payload");

    let state_unknown_alpha = execute_cli(strings(["state", "private-alpha-action-731"]))
        .expect_err("unknown state action must fail admission");
    assert_admission_error(
        &state_unknown_alpha,
        UNSUPPORTED_OPERATION,
        &["private-alpha", "action-731"],
    );
    assert_state_unchanged(&baseline, "first unsupported state action");
    let state_unknown_bravo = execute_cli(strings(["state", "private-bravo-action-947"]))
        .expect_err("unknown state action must fail admission");
    assert_admission_error(
        &state_unknown_bravo,
        UNSUPPORTED_OPERATION,
        &["private-bravo", "action-947"],
    );
    assert_state_unchanged(&baseline, "second unsupported state action");
    assert_equivalent_private_errors(
        &state_unknown_alpha,
        &state_unknown_bravo,
        UNSUPPORTED_OPERATION,
        &["private-alpha", "action-731", "private-bravo", "action-947"],
    );

    let malformed_alpha = r#"{"items":[{"value":"private-alpha-malformed-731"}]"#.to_string();
    let malformed_bravo = r#"{"items":[{"value":"private-bravo-malformed-947"}]"#.to_string();
    let malformed_error_alpha = execute_cli(strings([
        "state",
        "set",
        "settings",
        malformed_alpha.as_str(),
    ]))
    .expect_err("malformed state JSON must fail admission");
    assert_admission_error(
        &malformed_error_alpha,
        INVALID_JSON,
        &["private-alpha", "malformed-731"],
    );
    assert_state_unchanged(&baseline, "first malformed JSON");
    let malformed_error_bravo = execute_cli(strings([
        "state",
        "set",
        "settings",
        malformed_bravo.as_str(),
    ]))
    .expect_err("malformed state JSON must fail admission");
    assert_admission_error(
        &malformed_error_bravo,
        INVALID_JSON,
        &["private-bravo", "malformed-947"],
    );
    assert_state_unchanged(&baseline, "second malformed JSON");
    assert_equivalent_private_errors(
        &malformed_error_alpha,
        &malformed_error_bravo,
        INVALID_JSON,
        &[
            "private-alpha",
            "malformed-731",
            "private-bravo",
            "malformed-947",
        ],
    );

    let oversized_alpha = oversized_json_payload("private-alpha-oversized-731");
    let oversized_bravo = oversized_json_payload("private-bravo-oversized-947");
    let oversized_error_alpha = execute_cli(strings([
        "state",
        "set",
        "settings",
        oversized_alpha.as_str(),
    ]))
    .expect_err("oversized state payload must fail admission");
    assert_admission_error(
        &oversized_error_alpha,
        ARGUMENT_BYTES_EXCEEDED,
        &["private-alpha", "oversized-731"],
    );
    assert_state_unchanged(&baseline, "first oversized payload");
    let oversized_error_bravo = execute_cli(strings([
        "state",
        "set",
        "settings",
        oversized_bravo.as_str(),
    ]))
    .expect_err("oversized state payload must fail admission");
    assert_admission_error(
        &oversized_error_bravo,
        ARGUMENT_BYTES_EXCEEDED,
        &["private-bravo", "oversized-947"],
    );
    assert_state_unchanged(&baseline, "second oversized payload");
    assert_equivalent_private_errors(
        &oversized_error_alpha,
        &oversized_error_bravo,
        ARGUMENT_BYTES_EXCEEDED,
        &[
            "private-alpha",
            "oversized-731",
            "private-bravo",
            "oversized-947",
        ],
    );

    let replacement_text = replacement.to_string();
    let count_error_alpha = execute_cli(state_count_overflow(
        &replacement_text,
        "private-alpha-count-731",
    ))
    .expect_err("excessive argument count must fail admission");
    assert_admission_error(
        &count_error_alpha,
        ARGUMENT_COUNT_EXCEEDED,
        &["private-alpha", "count-731"],
    );
    assert_state_unchanged(&baseline, "first argument-count overflow");
    let count_error_bravo = execute_cli(state_count_overflow(
        &replacement_text,
        "private-bravo-count-947",
    ))
    .expect_err("excessive argument count must fail admission");
    assert_admission_error(
        &count_error_bravo,
        ARGUMENT_COUNT_EXCEEDED,
        &["private-bravo", "count-947"],
    );
    assert_state_unchanged(&baseline, "second argument-count overflow");
    assert_equivalent_private_errors(
        &count_error_alpha,
        &count_error_bravo,
        ARGUMENT_COUNT_EXCEEDED,
        &["private-alpha", "count-731", "private-bravo", "count-947"],
    );

    let extra_error_alpha = execute_cli(strings([
        "state",
        "set",
        "settings",
        replacement_text.as_str(),
        "private-alpha-extra-731",
    ]))
    .expect_err("an unexpected state-set positional must fail admission");
    assert_admission_error(
        &extra_error_alpha,
        UNEXPECTED_ARGUMENT,
        &["private-alpha", "extra-731"],
    );
    assert_state_unchanged(&baseline, "first unexpected positional");
    let extra_error_bravo = execute_cli(strings([
        "state",
        "set",
        "settings",
        replacement_text.as_str(),
        "private-bravo-extra-947",
    ]))
    .expect_err("an unexpected state-set positional must fail admission");
    assert_admission_error(
        &extra_error_bravo,
        UNEXPECTED_ARGUMENT,
        &["private-bravo", "extra-947"],
    );
    assert_state_unchanged(&baseline, "second unexpected positional");
    assert_equivalent_private_errors(
        &extra_error_alpha,
        &extra_error_bravo,
        UNEXPECTED_ARGUMENT,
        &["private-alpha", "extra-731", "private-bravo", "extra-947"],
    );

    let replacement_document = state_set(&replacement);
    assert_ne!(
        replacement_document, baseline,
        "the valid replacement must be observably distinct"
    );
    assert_eq!(
        state_get(),
        replacement_document,
        "valid state set/get must remain successful after rejected requests"
    );
}

fn assert_admission_error(error: &Error, expected: ExpectedAdmission, forbidden_inputs: &[&str]) {
    let typed = error
        .downcast_ref::<CliCommandError>()
        .expect("CLI admission failures must be downcastable to CliCommandError");
    assert_eq!(typed.code(), expected.code);
    assert_eq!(typed.stage(), ADMISSION_STAGE);
    assert_eq!(typed.component(), ADMISSION_COMPONENT);
    assert!(!typed.retryable());
    assert_eq!(typed.recovery(), expected.recovery);

    // String inspection is deliberately limited to the privacy oracle. Semantic
    // classification above relies exclusively on typed fields.
    let public_display = error.to_string();
    let public_chain = format!("{error:#}");
    let public_debug = format!("{error:?}");
    for forbidden in forbidden_inputs {
        assert!(
            !public_display.contains(forbidden)
                && !public_chain.contains(forbidden)
                && !public_debug.contains(forbidden),
            "public CLI errors must not echo command paths or payloads"
        );
    }
}

fn assert_private_failure_pair(
    label: &str,
    alpha_args: Vec<String>,
    bravo_args: Vec<String>,
    expected: ExpectedAdmission,
    forbidden_inputs: &[&str],
) {
    let alpha = execute_cli(alpha_args).expect_err(label);
    let bravo = execute_cli(bravo_args).expect_err(label);
    assert_equivalent_private_errors(&alpha, &bravo, expected, forbidden_inputs);
}

fn assert_equivalent_private_errors(
    alpha: &Error,
    bravo: &Error,
    expected: ExpectedAdmission,
    forbidden_inputs: &[&str],
) {
    assert_admission_error(alpha, expected, forbidden_inputs);
    assert_admission_error(bravo, expected, forbidden_inputs);
    assert_eq!(
        public_error_surfaces(alpha),
        public_error_surfaces(bravo),
        "private inputs in the same error class must have identical public errors"
    );
}

fn public_error_surfaces(error: &Error) -> (String, String, String) {
    (
        error.to_string(),
        format!("{error:#}"),
        format!("{error:?}"),
    )
}

fn run_lico_client(args: &[String]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_licoup-cli"))
        .args(args)
        .env_remove("RUST_LOG")
        .env_remove("RUST_BACKTRACE")
        .output()
        .expect("the real licoup binary must be runnable")
}

fn run_lico_client_rpc(args: Vec<String>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_licoup-cli"))
        .args(["rpc", "stdio"])
        .env_remove("RUST_LOG")
        .env_remove("RUST_BACKTRACE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the real licoup RPC subprocess must start");
    let request = json!({
        "protocol": "licoup.stdio.v1",
        "id": "cli-admission-byte-boundary",
        "workflowId": "cli-admission-byte-boundary",
        "method": "execute",
        "args": args,
    });
    child
        .stdin
        .take()
        .expect("RPC stdin must be piped")
        .write_all(format!("{request}\n").as_bytes())
        .expect("RPC request must be writable");
    child
        .wait_with_output()
        .expect("the real licoup RPC subprocess must finish")
}

fn rpc_response(output: &Output) -> Value {
    let line = std::str::from_utf8(&output.stdout)
        .expect("RPC stdout must be UTF-8")
        .lines()
        .find(|line| !line.trim().is_empty())
        .expect("RPC must return one line-delimited response");
    serde_json::from_str(line).expect("RPC response must be JSON")
}

fn assert_rpc_admission_pair(
    label: &str,
    alpha_args: Vec<String>,
    bravo_args: Vec<String>,
    expected: ExpectedAdmission,
    forbidden: &[&str],
) {
    let alpha = run_lico_client_rpc(alpha_args);
    let bravo = run_lico_client_rpc(bravo_args);
    assert_eq!(alpha.stdout, bravo.stdout, "{label} stdout must be stable");
    assert_eq!(alpha.stderr, bravo.stderr, "{label} stderr must be stable");
    assert_process_output_redacted(&alpha, forbidden, label);
    assert_process_output_redacted(&bravo, forbidden, label);
    for response in [rpc_response(&alpha), rpc_response(&bravo)] {
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], expected.code);
        assert_eq!(response["error"]["stage"], ADMISSION_STAGE);
        assert_eq!(response["error"]["component"], ADMISSION_COMPONENT);
        assert_eq!(response["error"]["retryable"], false);
        assert_eq!(response["error"]["recovery"], expected.recovery);
    }
}

fn assert_process_output_redacted(output: &Output, forbidden: &[&str], label: &str) {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for canary in forbidden {
        assert!(
            !stdout.contains(canary) && !stderr.contains(canary),
            "{label} must not expose either request canary on stdout or stderr"
        );
    }
}

fn assert_projected_schema(actual: &CliCommandSchema, expected: &RouteAuthority) {
    assert_eq!(actual.source_module(), expected.module);
    assert_eq!(actual.handler_name(), expected.handler);
    assert_eq!(
        actual.path(),
        expected.path.split_ascii_whitespace().collect::<Vec<_>>()
    );
    assert_eq!(actual.cardinality(), expected.cardinality);
    assert_eq!(actual.required_positionals().len(), expected.required.len());
    for (actual, (name, kind)) in actual.required_positionals().iter().zip(expected.required) {
        assert_eq!(actual.name(), *name);
        assert_eq!(actual.kind(), *kind);
    }
    assert_eq!(actual.options().len(), expected.options.len());
    for (actual, expected) in actual.options().iter().zip(&expected.options) {
        assert_eq!(actual.name(), expected.name);
        assert_eq!(actual.arity(), expected.arity);
        assert_eq!(actual.repeatable(), expected.repeatable);
        assert_eq!(actual.value_kind(), expected.value_kind);
        assert_eq!(actual.required(), expected.required);
    }
    assert_eq!(actual.constraints().len(), expected.constraints.len());
    for (actual, expected) in actual.constraints().iter().zip(expected.constraints) {
        assert_eq!(actual.kind(), expected.kind);
        assert_eq!(actual.members(), expected.members);
        assert_eq!(actual.condition_option(), expected.condition_option);
        assert_eq!(actual.condition_value(), expected.condition_value);
        assert_eq!(actual.required_option(), expected.required_option);
    }
}

fn assert_admitted_route(
    admitted: &AdmittedCommand,
    expected: &RouteAuthority,
    required_values: &[String],
    present_options: &[OptionAuthority],
) {
    let expected_path = expected.path.split_ascii_whitespace().collect::<Vec<_>>();
    let expected_required = expected
        .required
        .iter()
        .map(|(name, _)| *name)
        .collect::<Vec<_>>();
    assert_eq!(admitted.source_module(), expected.module);
    assert_eq!(admitted.handler_name(), expected.handler);
    assert_eq!(admitted.path(), expected_path);
    assert_eq!(admitted.required_positionals(), expected_required);
    assert_eq!(admitted.cardinality(), expected.cardinality);
    assert_eq!(admitted.option_specs().len(), expected.options.len());
    for (actual, option) in admitted.option_specs().iter().zip(&expected.options) {
        assert_eq!(actual.name(), option.name);
        assert_eq!(actual.arity(), option.arity);
        assert_eq!(actual.repeatable(), option.repeatable);
        assert_eq!(actual.value_kind(), option.value_kind);
        assert_eq!(actual.required(), option.required);
    }
    for ((name, kind), value) in expected.required.iter().zip(required_values) {
        assert_eq!(admitted.required_kind(name), *kind);
        match kind {
            RequiredArgumentKind::Text => assert_eq!(
                admitted.required_text(name),
                value,
                "text positional {name} must be available only as admitted text"
            ),
            RequiredArgumentKind::Json => assert_eq!(
                admitted.required_json(name),
                &serde_json::from_str::<Value>(value).expect("oracle JSON must be valid"),
                "JSON positional {name} must be stored as an owned parsed value"
            ),
        }
    }
    for option in present_options {
        match (option.arity, option.value_kind) {
            (OptionArity::Boolean, _) => assert!(admitted.option_flag(option.name)),
            (OptionArity::Value, RequiredArgumentKind::Text) => assert_eq!(
                admitted.option_text(option.name),
                Some(sample_option_value(*option).as_str())
            ),
            (OptionArity::Value, RequiredArgumentKind::Json) => assert_eq!(
                admitted.option_json(option.name),
                Some(&json!({"oracle": option.name}))
            ),
        }
    }
}

fn append_option(args: &mut Vec<String>, option: OptionAuthority) {
    args.push(format!("--{}", option.name));
    if option.arity == OptionArity::Value {
        args.push(sample_option_value(option));
    }
}

fn sample_option_value(option: OptionAuthority) -> String {
    match option.value_kind {
        RequiredArgumentKind::Text => format!("accepted-{}", option.name),
        RequiredArgumentKind::Json => json!({"oracle": option.name}).to_string(),
    }
}

fn constraint_violation_args(
    route: &RouteAuthority,
    minimum: &[String],
    present: &[OptionAuthority],
    constraint: ConstraintAuthority,
) -> Vec<String> {
    let mut selected = present
        .iter()
        .copied()
        .filter(|option| {
            !constraint.members.contains(&option.name)
                && Some(option.name) != constraint.condition_option
                && Some(option.name) != constraint.required_option
        })
        .collect::<Vec<_>>();
    let mut args = minimum.to_vec();
    match constraint.kind {
        OptionConstraintKind::OneOf | OptionConstraintKind::MutuallyExclusive => {
            for name in constraint.members.iter().take(2) {
                selected.push(
                    *route
                        .options
                        .iter()
                        .find(|option| option.name == *name)
                        .expect("constraint member must name a documented option"),
                );
            }
        }
        OptionConstraintKind::AtLeastOne => {}
        OptionConstraintKind::ConditionalRequired => {
            for option in &selected {
                append_option(&mut args, *option);
            }
            args.extend([
                format!(
                    "--{}",
                    constraint
                        .condition_option
                        .expect("conditional option must be named")
                ),
                constraint
                    .condition_value
                    .expect("conditional value must be named")
                    .to_string(),
            ]);
            return args;
        }
    }
    for option in selected {
        append_option(&mut args, option);
    }
    args
}

fn route_authorities() -> Vec<RouteAuthority> {
    use CommandCardinality::{Exact, Options};
    use RequiredArgumentKind::{Json, Text};

    let mut routes = Vec::with_capacity(120);
    add_authority_routes(
        &mut routes,
        "adapter.rs",
        "handle_catalog",
        &["adapter catalog"],
        Exact,
    );
    add_authority_routes(
        &mut routes,
        "adapter.rs",
        "handle_antigravity_status",
        &["adapter antigravity status"],
        Exact,
    );
    add_authority_routes(
        &mut routes,
        "adapter.rs",
        "handle_antigravity_install",
        &["adapter antigravity install"],
        Exact,
    );
    add_authority_routes(
        &mut routes,
        "adapter.rs",
        "handle_antigravity_uninstall",
        &["adapter antigravity uninstall"],
        Exact,
    );
    add_authority_routes(
        &mut routes,
        "agent_conversation.rs",
        "handle_agent_conversation",
        &[
            "agent conversation open",
            "agent conversation send",
            "agent conversation steer",
            "agent conversation cancel",
            "agent conversation capabilities",
            "agent conversation stream",
            "agent conversation cleanup",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "agent_conversation.rs",
        "handle_agents_pair",
        &[
            "agents pair request",
            "agents pair approve",
            "agents pair revoke",
            "agents pair list",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "agent_usage.rs",
        "handle_agent_usage_scan",
        &["agent-usage scan"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "agent_usage.rs",
        "handle_agent_usage_report",
        &["agent-usage report"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "client_update.rs",
        "handle_update",
        &[
            "update status",
            "update check",
            "update download",
            "update verify",
            "update apply",
        ],
        Options,
    );
    for (path, handler) in [
        ("collaboration status", "handle_status"),
        ("collaboration enable", "handle_enable"),
        ("collaboration install plan", "handle_install_plan"),
        ("collaboration install apply", "handle_install_apply"),
        ("collaboration install cancel", "handle_install_cancel"),
        ("collaboration workflow catalog", "handle_workflow_catalog"),
        (
            "collaboration workflow local-deployment plan",
            "handle_local_deployment_plan",
        ),
        (
            "collaboration workflow local-deployment apply",
            "handle_local_deployment_apply",
        ),
        (
            "collaboration workflow mcp-install plan",
            "handle_mcp_install_plan",
        ),
        (
            "collaboration workflow mcp-install apply",
            "handle_mcp_install_apply",
        ),
        ("collaboration workflow cancel", "handle_workflow_cancel"),
        (
            "collaboration local-server status",
            "handle_local_server_status",
        ),
        (
            "collaboration local-server start",
            "handle_local_server_start",
        ),
        (
            "collaboration local-server stop",
            "handle_local_server_stop",
        ),
        (
            "collaboration local-server uninstall",
            "handle_local_server_uninstall",
        ),
        ("collaboration disable", "handle_disable"),
        ("collaboration cleanup", "handle_cleanup"),
    ] {
        add_authority_routes(&mut routes, "collaboration.rs", handler, &[path], Options);
    }
    add_authority_routes(
        &mut routes,
        "mcp.rs",
        "handle_preview",
        &["mcp http preview"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "mcp.rs",
        "handle_execute",
        &["mcp http execute"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "mobile.rs",
        "handle_mobile_relay",
        &[
            "mobile relay config get",
            "mobile relay config set",
            "mobile relay pairing create",
            "mobile relay pairing claim",
            "mobile relay pairing status",
            "mobile relay pairing revoke",
            "mobile relay pc check-in",
            "mobile relay commands poll",
            "mobile relay commands sync",
            "mobile relay commands complete",
            "mobile relay commands create",
            "mobile relay commands result",
            "mobile relay commands result-secure",
            "mobile relay commands result-replay-proof",
            "mobile relay e2ee secret-store-cleanup",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "opencode_serve.rs",
        "handle_opencode_serve",
        &[
            "opencode-serve ensure",
            "opencode-serve start",
            "opencode-serve stop",
            "opencode-serve restart",
            "opencode-serve status",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "secure_mesh.rs",
        "handle_secure_mesh",
        &[
            "secure-mesh status",
            "secure-mesh envelope validate",
            "secure-mesh command policy",
            "secure-mesh command evaluate",
            "secure-mesh command execute",
            "secure-mesh device-trust evaluate",
            "secure-mesh file route",
            "secure-mesh file receive-destination",
            "secure-mesh file receive-confirmation",
            "secure-mesh approval request",
            "secure-mesh approval fanout",
            "secure-mesh approval respond",
            "secure-mesh approval inbox",
            "secure-mesh approval adapter-capability",
        ],
        Options,
    );
    for (path, handler) in [
        ("skill list", "handle_skill_list"),
        ("skill get", "handle_skill_get"),
        ("skill install plan", "handle_skill_install_plan"),
        ("skill install apply", "handle_skill_install_apply"),
        ("skill install rollback", "handle_skill_install_rollback"),
        ("skill update plan", "handle_skill_update_plan"),
        ("skill update apply", "handle_skill_update_apply"),
        ("skill delete plan", "handle_skill_delete_plan"),
        ("skill delete apply", "handle_skill_delete_apply"),
        ("skill auto-update set", "handle_skill_auto_update_set"),
        ("skill auto-update run", "handle_skill_auto_update_run"),
        ("skill visibility set", "handle_skill_visibility"),
        ("skill pin set", "handle_skill_pin"),
        ("skill usage report", "handle_skill_usage_report"),
    ] {
        add_authority_routes(&mut routes, "skill.rs", handler, &[path], Options);
    }
    add_authority_routes(
        &mut routes,
        "skill.rs",
        "handle_skill_auto_update_tick",
        &["skill auto-update tick"],
        Exact,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_list",
        &["snapshots list"],
        Options,
    );
    routes.push(RouteAuthority {
        module: "snapshots.rs",
        handler: "handle_snapshots_restore",
        path: "snapshots restore",
        required: &[("snapshot-id", Text)],
        cardinality: Exact,
        options: vec![],
        constraints: &[],
    });
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_collect",
        &["snapshots collect"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_root",
        &["snapshots root get", "snapshots root set"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_profiles",
        &[
            "snapshots profiles list",
            "snapshots profiles get",
            "snapshots profiles import",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_archive",
        &[
            "snapshots archive collect",
            "snapshots archive run",
            "snapshots archive verify",
            "snapshots archive report",
            "snapshots archive jobs preview",
            "snapshots archive jobs create",
            "snapshots archive jobs status",
            "snapshots archive jobs list",
            "snapshots archive jobs events",
            "snapshots archive jobs cancel",
            "snapshots archive jobs drain",
        ],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_snapshots_collections",
        &["snapshots collections list"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "snapshots.rs",
        "handle_conversations",
        &[
            "conversations list",
            "conversations stream",
            "conversations append",
            "conversations delete",
        ],
        Options,
    );
    routes.extend([
        RouteAuthority {
            module: "state.rs",
            handler: "handle_state_get",
            path: "state get",
            required: &[("collection", Text)],
            cardinality: Exact,
            options: vec![],
            constraints: &[],
        },
        RouteAuthority {
            module: "state.rs",
            handler: "handle_state_set",
            path: "state set",
            required: &[("collection", Text), ("payload", Json)],
            cardinality: Exact,
            options: vec![],
            constraints: &[],
        },
    ]);
    add_authority_routes(
        &mut routes,
        "state.rs",
        "handle_activity_list",
        &["activity list"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "targets.rs",
        "handle_targets_scan",
        &["targets scan"],
        Options,
    );
    add_authority_routes(
        &mut routes,
        "targets.rs",
        "handle_targets_add",
        &["targets add"],
        Options,
    );
    routes.push(RouteAuthority {
        module: "targets.rs",
        handler: "handle_targets_inspect",
        path: "targets inspect",
        required: &[("target", Text)],
        cardinality: Options,
        options: vec![],
        constraints: &[],
    });
    for route in &mut routes {
        route.required = match route.path {
            "skill get" | "skill visibility set" | "skill pin set" => &[("skill-id", Text)],
            _ => route.required,
        };
        route.options = options_for_route(route.path);
        route.constraints = constraints_for_route(route.path);
        route.cardinality = if route.options.is_empty() {
            Exact
        } else {
            Options
        };
    }
    routes
}

fn add_authority_routes(
    routes: &mut Vec<RouteAuthority>,
    module: &'static str,
    handler: &'static str,
    paths: &[&'static str],
    cardinality: CommandCardinality,
) {
    routes.extend(paths.iter().copied().map(|path| RouteAuthority {
        module,
        handler,
        path,
        required: &[],
        cardinality,
        options: vec![],
        constraints: &[],
    }));
}

const fn value_option(
    name: &'static str,
    value_kind: RequiredArgumentKind,
    required: bool,
) -> OptionAuthority {
    OptionAuthority {
        name,
        arity: OptionArity::Value,
        repeatable: false,
        value_kind,
        required,
    }
}

const fn boolean_option(name: &'static str) -> OptionAuthority {
    OptionAuthority {
        name,
        arity: OptionArity::Boolean,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    }
}

fn options_for_route(path: &str) -> Vec<OptionAuthority> {
    use RequiredArgumentKind::{Json, Text};
    let options: &[OptionAuthority] = match path {
        "opencode-serve ensure"
        | "opencode-serve start"
        | "opencode-serve stop"
        | "opencode-serve restart"
        | "opencode-serve status" => &[
            value_option("port", Text, false),
            value_option("executable", Text, false),
            value_option("attach-url", Text, false),
        ],
        "activity list" => &[
            value_option("type", Text, false),
            value_option("target", Text, false),
            value_option("limit", Text, false),
        ],
        "snapshots list" => &[value_option("target", Text, false)],
        "snapshots root get" | "snapshots root set" => &[value_option("path", Text, false)],
        "snapshots collections list" => &[value_option("snapshot-root", Text, false)],
        "snapshots profiles list" | "snapshots profiles get" | "snapshots profiles import" => &[
            value_option("profile", Text, false),
            value_option("profile-json", Json, false),
            value_option("profile-file", Text, false),
        ],
        "snapshots archive jobs preview" => &[
            value_option("selection-mode", Text, true),
            value_option("query", Text, false),
            value_option("path", Text, true),
            value_option("agent", Text, false),
        ],
        "snapshots archive jobs create" => &[
            value_option("selection-mode", Text, true),
            value_option("query", Text, false),
            value_option("path", Text, true),
            value_option("plan-binding", Text, true),
            value_option("agent", Text, false),
        ],
        "snapshots archive jobs status"
        | "snapshots archive jobs events"
        | "snapshots archive jobs cancel" => &[value_option("job-id", Text, true)],
        "snapshots archive jobs list" | "snapshots archive jobs drain" => &[
            value_option("job-id", Text, false),
            value_option("once", Text, false),
        ],
        "snapshots archive collect" => &[
            value_option("keywords", Text, true),
            value_option("path", Text, true),
            value_option("trigger", Text, false),
        ],
        "snapshots archive run" | "snapshots archive report" => &[
            value_option("profile", Text, true),
            value_option("trigger", Text, false),
        ],
        "snapshots archive verify" => &[
            value_option("profile", Text, false),
            value_option("trigger", Text, false),
            value_option("collection-path", Text, false),
        ],
        "snapshots collect" => &[
            value_option("topic", Text, true),
            value_option("agent", Text, false),
        ],
        "conversations list"
        | "conversations append"
        | "conversations delete"
        | "conversations stream" => &[
            value_option("agent", Text, true),
            value_option("limit", Text, false),
            value_option("offset", Text, false),
            value_option("session-id", Text, false),
            value_option("text", Text, false),
        ],
        "agent-usage scan" => &[
            value_option("agent", Text, false),
            value_option("history-days", Text, false),
            value_option("timezone-offset-minutes", Text, false),
            value_option("timezone-transitions-json", Json, false),
            boolean_option("force-refresh"),
            value_option("state-root", Text, false),
        ],
        "agent-usage report" => &[
            value_option("agent", Text, false),
            value_option("limit", Text, false),
            value_option("state-root", Text, false),
        ],
        "mcp http preview" | "mcp http execute" => &[value_option("stdin-json", Json, true)],
        "update status" | "update check" | "update download" | "update verify" | "update apply" => {
            &[
                value_option("channel", Text, false),
                value_option("manifest-path", Text, false),
                value_option("public-keys-path", Text, false),
                value_option("source-path", Text, false),
            ]
        }
        "collaboration install plan"
        | "collaboration install apply"
        | "collaboration install cancel" => &[
            value_option("github-url", Text, false),
            value_option("plan-id", Text, false),
            value_option("expected-digest-sha256", Text, false),
            value_option("confirmed", Text, false),
        ],
        "collaboration workflow local-deployment plan"
        | "collaboration workflow local-deployment apply" => &[
            value_option("request-origin", Text, true),
            value_option("selected-feature-ids", Text, true),
            value_option("destination", Text, true),
            value_option("destination-confirmed", Text, true),
            value_option("port", Text, false),
            value_option("plan-id", Text, false),
            value_option("expected-plan-digest-sha256", Text, false),
            value_option("expected-package-digest-sha256", Text, false),
            value_option("confirmed", Text, false),
        ],
        "collaboration local-server start" | "collaboration local-server stop" => &[
            value_option("request-origin", Text, true),
            value_option("deployment-id", Text, true),
            value_option("confirmed", Text, true),
        ],
        "collaboration local-server uninstall" => &[
            value_option("request-origin", Text, true),
            value_option("deployment-id", Text, true),
            value_option("expected-assembly-manifest-digest-sha256", Text, true),
            value_option("confirmed", Text, true),
        ],
        "collaboration workflow mcp-install plan" | "collaboration workflow mcp-install apply" => {
            &[
                value_option("request-origin", Text, true),
                value_option("selected-plugin-ids", Text, true),
                value_option("agent-destinations", Json, true),
                value_option("plan-id", Text, false),
                value_option("expected-plan-digest-sha256", Text, false),
                value_option("expected-package-digest-sha256", Text, false),
                value_option("confirmed", Text, false),
            ]
        }
        "collaboration workflow cancel" => &[
            value_option("request-origin", Text, true),
            value_option("plan-id", Text, true),
            value_option("expected-plan-digest-sha256", Text, true),
            value_option("expected-package-digest-sha256", Text, true),
            value_option("confirmed", Text, true),
        ],
        "agent conversation open"
        | "agent conversation send"
        | "agent conversation steer"
        | "agent conversation cancel"
        | "agent conversation cleanup"
        | "agent conversation capabilities"
        | "agent conversation stream" => &[value_option("stdin-json", Json, false)],
        "agents pair request"
        | "agents pair approve"
        | "agents pair revoke"
        | "agents pair list" => &[
            value_option("agent", Text, true),
            value_option("target", Text, false),
        ],
        "skill list" => &[
            value_option("agent", Text, true),
            value_option("refresh-local", Text, false),
            value_option("install-root", Text, false),
        ],
        "skill get" => &[
            value_option("agent", Text, true),
            value_option("discover-local", Text, false),
            value_option("install-root", Text, false),
        ],
        "skill install plan" | "skill install apply" => &[
            value_option("agent", Text, true),
            value_option("url", Text, true),
            value_option("install-root", Text, false),
            value_option("name", Text, false),
            value_option("overwrite", Text, false),
            value_option("pin", Text, false),
        ],
        "skill install rollback" => &[
            value_option("agent", Text, true),
            value_option("snapshot-id", Text, true),
        ],
        "skill update plan" => &[
            value_option("agent", Text, true),
            value_option("skill", Text, true),
            value_option("source-path", Text, false),
            value_option("url", Text, false),
        ],
        "skill update apply" => &[
            value_option("agent", Text, true),
            value_option("skill", Text, true),
            value_option("confirmation", Text, true),
            value_option("source-path", Text, false),
            value_option("url", Text, false),
        ],
        "skill auto-update set" => &[
            value_option("agent", Text, true),
            value_option("skill", Text, true),
            value_option("enabled", Text, true),
            value_option("direct-user-action", Text, true),
            value_option("source-path", Text, false),
            value_option("url", Text, false),
        ],
        "skill auto-update run" => &[
            value_option("agent", Text, true),
            value_option("direct-user-action", Text, true),
            value_option("skill", Text, false),
        ],
        "skill delete plan" | "skill delete apply" => &[
            value_option("skill", Text, true),
            value_option("agent", Text, false),
            value_option("agents", Text, false),
            value_option("confirmation", Text, false),
        ],
        "skill visibility set" => &[
            value_option("agent", Text, true),
            value_option("hidden", Text, true),
        ],
        "skill pin set" => &[
            value_option("agent", Text, true),
            value_option("version", Text, true),
        ],
        "skill usage report" => &[
            value_option("agent", Text, false),
            value_option("skill", Text, false),
            value_option("days", Text, false),
            value_option("from", Text, false),
            value_option("to", Text, false),
        ],
        "targets scan" => &[
            value_option("state-root", Text, false),
            value_option("include-accessible-environments", Text, false),
            value_option("include-history-model-catalog", Text, false),
            value_option("installer-scan-command", Text, false),
        ],
        "targets add" => &[
            value_option("target", Text, true),
            value_option("config-path", Text, false),
            value_option("binary-path", Text, false),
            value_option("history-root", Text, false),
            value_option("state-root", Text, false),
        ],
        "targets inspect" => &[value_option("state-root", Text, false)],
        "mobile relay config get" | "mobile relay config set" => &[
            value_option("use-custom-gateway", Text, false),
            value_option("custom-gateway-url", Text, false),
            value_option("relay-enabled", Text, false),
        ],
        "mobile relay pairing create"
        | "mobile relay pairing status"
        | "mobile relay pairing claim"
        | "mobile relay pairing revoke" => &[
            value_option("pairing-code", Text, false),
            value_option("pairing-id", Text, false),
            value_option("mobile-token", Text, false),
        ],
        "mobile relay commands poll"
        | "mobile relay commands sync"
        | "mobile relay commands complete"
        | "mobile relay commands create"
        | "mobile relay commands result"
        | "mobile relay commands result-secure"
        | "mobile relay commands result-replay-proof" => &[
            value_option("command-id", Text, false),
            value_option("type", Text, false),
            value_option("payload", Json, false),
            value_option("mobile-token", Text, false),
        ],
        "mobile relay e2ee secret-store-cleanup" => &[value_option("disposable-proof", Text, true)],
        "secure-mesh status"
        | "secure-mesh envelope validate"
        | "secure-mesh command policy"
        | "secure-mesh command evaluate"
        | "secure-mesh command execute" => &[
            value_option("payload", Json, false),
            value_option("context", Json, false),
            value_option("ledger-path", Text, false),
        ],
        "secure-mesh device-trust evaluate" => &[
            value_option("identity", Json, true),
            value_option("previous-identity", Json, false),
            value_option("trust-state", Text, false),
        ],
        "secure-mesh file route" => &[value_option("manifest", Json, true)],
        "secure-mesh file receive-destination" => &[
            value_option("manifest", Json, true),
            value_option("approved-root", Text, true),
            value_option("conflict-policy", Text, false),
        ],
        "secure-mesh file receive-confirmation" => &[
            value_option("manifest", Json, true),
            value_option("approved-root", Text, true),
            value_option("user-confirmed", Text, true),
        ],
        "secure-mesh approval request"
        | "secure-mesh approval fanout"
        | "secure-mesh approval respond"
        | "secure-mesh approval inbox"
        | "secure-mesh approval adapter-capability" => &[
            value_option("pending-operation-id", Text, false),
            value_option("decision", Text, false),
        ],
        _ => &[],
    };
    options.to_vec()
}

fn constraints_for_route(path: &str) -> &'static [ConstraintAuthority] {
    use OptionConstraintKind::{AtLeastOne, ConditionalRequired, MutuallyExclusive, OneOf};
    match path {
        "snapshots profiles list" | "snapshots profiles get" | "snapshots profiles import" => {
            &[ConstraintAuthority {
                kind: MutuallyExclusive,
                members: &["profile", "profile-json", "profile-file"],
                condition_option: None,
                condition_value: None,
                required_option: None,
            }]
        }
        "snapshots archive jobs preview" | "snapshots archive jobs create" => {
            &[ConstraintAuthority {
                kind: ConditionalRequired,
                members: &[],
                condition_option: Some("selection-mode"),
                condition_value: Some("exact-keyword"),
                required_option: Some("query"),
            }]
        }
        "snapshots archive verify" => &[ConstraintAuthority {
            kind: OneOf,
            members: &["profile", "collection-path"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        "collaboration install plan"
        | "collaboration install apply"
        | "collaboration install cancel" => &[ConstraintAuthority {
            kind: MutuallyExclusive,
            members: &["github-url", "plan-id"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        "skill update plan" | "skill update apply" | "skill auto-update set" => {
            &[ConstraintAuthority {
                kind: MutuallyExclusive,
                members: &["source-path", "url"],
                condition_option: None,
                condition_value: None,
                required_option: None,
            }]
        }
        "skill delete plan" | "skill delete apply" => &[
            ConstraintAuthority {
                kind: AtLeastOne,
                members: &["agent", "agents"],
                condition_option: None,
                condition_value: None,
                required_option: None,
            },
            ConstraintAuthority {
                kind: MutuallyExclusive,
                members: &["agent", "agents"],
                condition_option: None,
                condition_value: None,
                required_option: None,
            },
        ],
        "skill usage report" => &[ConstraintAuthority {
            kind: MutuallyExclusive,
            members: &["days", "from"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        _ => &[],
    }
}

fn counted_unknown_route(total: usize, canary: &str, oversized_first: bool) -> Vec<String> {
    assert!(total > 0);
    let first = if oversized_first {
        exact_byte_argument(canary, MAX_CLI_ARGUMENT_BYTES + 1)
    } else {
        canary.to_string()
    };
    let mut args = Vec::with_capacity(total);
    args.push(first);
    args.resize(total, "x".to_string());
    args
}

fn exact_byte_argument(canary: &str, bytes: usize) -> String {
    assert!(canary.is_ascii());
    assert!(canary.len() <= bytes);
    format!("{canary}{}", "x".repeat(bytes - canary.len()))
}

fn exact_multibyte_argument(canary: &str, bytes: usize) -> String {
    assert!(canary.is_ascii());
    assert!(canary.len() <= bytes);
    let mut value = canary.to_string();
    let multibyte_count = (bytes - value.len()) / "界".len();
    value.push_str(&"界".repeat(multibyte_count));
    value.push_str(&"x".repeat(bytes - value.len()));
    assert_eq!(value.len(), bytes);
    value
}

fn oversized_json_payload(canary: &str) -> String {
    format!(
        r#"{{"items":[{{"value":"{canary}{}"}}]}}"#,
        "x".repeat(MAX_CLI_ARGUMENT_BYTES)
    )
}

fn state_count_overflow(payload: &str, canary: &str) -> Vec<String> {
    let mut args = strings(["state", "set", "settings", payload]);
    args.resize(MAX_CLI_ARGUMENT_COUNT + 1, canary.to_string());
    args
}

fn assert_state_unchanged(baseline: &Value, rejected_case: &str) {
    assert_eq!(
        state_get(),
        *baseline,
        "{rejected_case} must not mutate portable state"
    );
}

fn state_set(value: &Value) -> Value {
    let payload = value.to_string();
    match execute_cli(strings(["state", "set", "settings", payload.as_str()]))
        .expect("valid state set must succeed")
    {
        CliExecution::Json(value) => value["document"].clone(),
        other => panic!("valid state set returned {other:?}"),
    }
}

fn state_get() -> Value {
    match execute_cli(strings(["state", "get", "settings"])).expect("valid state get must succeed")
    {
        CliExecution::Json(value) => value["document"].clone(),
        other => panic!("valid state get returned {other:?}"),
    }
}

fn strings<'a>(values: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    values.into_iter().map(str::to_owned).collect()
}

fn cli_environment_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn temporary_directory(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let path = std::env::temp_dir().join(format!("{label}-{}-{nonce}", std::process::id()));
    fs::create_dir_all(&path).expect("create isolated portable state root");
    path
}

struct PortableDataOverride {
    previous: Option<PathBuf>,
    root: PathBuf,
}

impl PortableDataOverride {
    fn set(root: &Path) -> Self {
        let previous = licoup_native::platform::paths::set_portable_data_dir_override(Some(
            root.to_path_buf(),
        ));
        Self {
            previous,
            root: root.to_path_buf(),
        }
    }
}

impl Drop for PortableDataOverride {
    fn drop(&mut self) {
        licoup_native::platform::paths::set_portable_data_dir_override(self.previous.take());
        let _ = fs::remove_dir_all(&self.root);
    }
}
