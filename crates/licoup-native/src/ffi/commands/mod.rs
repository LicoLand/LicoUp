//! Bounded, fail-closed native CLI admission and execution.

use anyhow::Result;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

mod adapter;
mod agent_conversation;
mod agent_hub;
mod agent_usage;
mod autostart;
mod client_conversation;
mod client_update;
mod collaboration;
mod gateway;
mod llm_gateway;
mod mcp;
mod mobile;
mod opencode_serve;
mod resource_usage;
mod secure_mesh;
mod skill;
mod snapshots;
mod state;
mod strategy;
mod targets;

const MAX_CLI_ARGUMENT_COUNT: usize = 4_096;
const MAX_CLI_ARGUMENT_BYTES: usize = 2 * 1024 * 1024;

const ADMISSION_STAGE: &str = "cli/admission";
const ADMISSION_COMPONENT: &str = "native_cli";

#[derive(Debug, PartialEq, Clone)]
pub enum CliExecution {
    Usage,
    Json(Value),
    Streamed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequiredArgumentKind {
    Json,
    Text,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandCardinality {
    Exact,
    Options,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OptionArity {
    Boolean,
    Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OptionConstraintKind {
    AtLeastOne,
    ConditionalRequired,
    MutuallyExclusive,
    OneOf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RequiredArgumentSpec {
    name: &'static str,
    kind: RequiredArgumentKind,
}

impl RequiredArgumentSpec {
    pub fn name(&self) -> &'static str {
        self.name
    }

    pub fn kind(&self) -> RequiredArgumentKind {
        self.kind
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OptionSpec {
    name: &'static str,
    arity: OptionArity,
    repeatable: bool,
    value_kind: RequiredArgumentKind,
    required: bool,
}

impl OptionSpec {
    pub fn name(&self) -> &'static str {
        self.name
    }

    pub fn arity(&self) -> OptionArity {
        self.arity
    }

    pub fn repeatable(&self) -> bool {
        self.repeatable
    }

    pub fn value_kind(&self) -> RequiredArgumentKind {
        self.value_kind
    }

    pub fn required(&self) -> bool {
        self.required
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OptionConstraintSpec {
    kind: OptionConstraintKind,
    members: &'static [&'static str],
    condition_option: Option<&'static str>,
    condition_value: Option<&'static str>,
    required_option: Option<&'static str>,
}

impl OptionConstraintSpec {
    pub fn kind(&self) -> OptionConstraintKind {
        self.kind
    }

    pub fn members(&self) -> &'static [&'static str] {
        self.members
    }

    pub fn condition_option(&self) -> Option<&'static str> {
        self.condition_option
    }

    pub fn condition_value(&self) -> Option<&'static str> {
        self.condition_value
    }

    pub fn required_option(&self) -> Option<&'static str> {
        self.required_option
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CliCommandSchema {
    source_module: &'static str,
    handler_name: &'static str,
    path: &'static [&'static str],
    required_positionals: &'static [RequiredArgumentSpec],
    options: &'static [OptionSpec],
    constraints: &'static [OptionConstraintSpec],
    cardinality: CommandCardinality,
}

impl CliCommandSchema {
    pub fn source_module(&self) -> &'static str {
        self.source_module
    }

    pub fn handler_name(&self) -> &'static str {
        self.handler_name
    }

    pub fn path(&self) -> &'static [&'static str] {
        self.path
    }

    pub fn required_positionals(&self) -> &'static [RequiredArgumentSpec] {
        self.required_positionals
    }

    pub fn options(&self) -> &'static [OptionSpec] {
        self.options
    }

    pub fn constraints(&self) -> &'static [OptionConstraintSpec] {
        self.constraints
    }

    pub fn cardinality(&self) -> CommandCardinality {
        self.cardinality
    }
}

#[derive(Clone, Copy)]
pub struct CliCommandError {
    code: &'static str,
    stage: &'static str,
    component: &'static str,
    retryable: bool,
    recovery: &'static str,
}

const EXECUTION_STAGE: &str = "cli/execution";

impl CliCommandError {
    fn from_admission(code: &'static str, recovery: &'static str) -> Self {
        Self {
            code,
            stage: ADMISSION_STAGE,
            component: ADMISSION_COMPONENT,
            retryable: false,
            recovery,
        }
    }

    fn from_handler(code: &'static str, recovery: &'static str) -> Self {
        Self {
            code,
            stage: EXECUTION_STAGE,
            component: ADMISSION_COMPONENT,
            retryable: false,
            recovery,
        }
    }

    pub fn code(&self) -> &'static str {
        self.code
    }

    pub fn stage(&self) -> &'static str {
        self.stage
    }

    pub fn component(&self) -> &'static str {
        self.component
    }

    pub fn retryable(&self) -> bool {
        self.retryable
    }

    pub fn recovery(&self) -> &'static str {
        self.recovery
    }
}

impl fmt::Debug for CliCommandError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CliCommandError")
            .field("code", &self.code)
            .field("stage", &self.stage)
            .field("component", &self.component)
            .field("retryable", &self.retryable)
            .field("recovery", &self.recovery)
            .finish()
    }
}

impl fmt::Display for CliCommandError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "native CLI request rejected ({})", self.code)
    }
}

impl std::error::Error for CliCommandError {}

type CommandFn = fn(AdmittedCommand) -> Result<CliExecution>;

struct CommandSpec {
    source_module: &'static str,
    handler_name: &'static str,
    path: &'static [&'static str],
    required_positionals: &'static [RequiredArgumentSpec],
    options: &'static [OptionSpec],
    constraints: &'static [OptionConstraintSpec],
    cardinality: CommandCardinality,
    handler: CommandFn,
    help: &'static str,
}

struct CommandDef {
    source_module: &'static str,
    handler_name: &'static str,
    path: &'static [&'static str],
    required_positionals: &'static [RequiredArgumentSpec],
    options: &'static [OptionSpec],
    constraints: &'static [OptionConstraintSpec],
    cardinality: CommandCardinality,
    handler: CommandFn,
    help: &'static str,
}

impl CommandDef {
    fn schema(&self) -> CliCommandSchema {
        CliCommandSchema {
            source_module: self.source_module,
            handler_name: self.handler_name,
            path: self.path,
            required_positionals: self.required_positionals,
            options: self.options,
            constraints: self.constraints,
            cardinality: self.cardinality,
        }
    }
}

pub struct CommandTable {
    defs: Vec<CommandDef>,
}

impl CommandTable {
    pub fn new() -> Self {
        Self { defs: Vec::new() }
    }

    fn register_command(&mut self, spec: CommandSpec) {
        self.defs.push(CommandDef {
            source_module: spec.source_module,
            handler_name: spec.handler_name,
            path: spec.path,
            required_positionals: spec.required_positionals,
            options: spec.options,
            constraints: spec.constraints,
            cardinality: spec.cardinality,
            handler: spec.handler,
            help: spec.help,
        });
    }

    fn schemas(&self) -> Vec<CliCommandSchema> {
        self.defs.iter().map(CommandDef::schema).collect()
    }

    fn help_text(&self) -> Vec<String> {
        self.defs
            .iter()
            .map(|definition| {
                let path = definition.path.join(" ");
                let required = definition
                    .required_positionals
                    .iter()
                    .map(|argument| format!(" <{}>", argument.name))
                    .collect::<String>();
                let options = if definition.options.is_empty() {
                    String::new()
                } else {
                    " [options]".to_string()
                };
                let help = if definition.help.is_empty() {
                    String::new()
                } else {
                    format!("  — {}", definition.help)
                };
                format!("  {path}{required}{options}{help}")
            })
            .collect()
    }

    fn admit(&self, args: Vec<String>) -> Result<AdmittedCommand> {
        validate_cli_admission(&args)?;
        let mut known_root = false;
        let mut missing_path = false;
        let definition = self
            .defs
            .iter()
            .find(|definition| {
                known_root |= args
                    .first()
                    .is_some_and(|argument| definition.path.first() == Some(&argument.as_str()));
                missing_path |= args.len() < definition.path.len()
                    && args
                        .iter()
                        .zip(definition.path)
                        .all(|(argument, expected)| argument == expected);
                args.len() >= definition.path.len()
                    && args
                        .iter()
                        .take(definition.path.len())
                        .zip(definition.path)
                        .all(|(argument, expected)| argument == expected)
            })
            .ok_or_else(|| {
                if args.is_empty() {
                    admission_error("cli_command_missing", "use_cli_help")
                } else if missing_path {
                    admission_error("cli_required_argument_missing", "correct_command_arguments")
                } else if known_root {
                    admission_error("cli_operation_unsupported", "use_cli_help")
                } else {
                    admission_error("cli_command_unknown", "use_cli_help")
                }
            })?;
        let validated = validate_command_arguments(
            definition.path,
            definition.required_positionals,
            definition.cardinality,
            definition.options,
            definition.constraints,
            &args,
        )?;
        let ValidatedCommandArguments {
            required_text,
            mut required_json,
            option_flags,
            option_text,
            mut option_json,
            pending_json,
        } = validated;
        for pending in pending_json {
            let parsed = parse_json_arg(&pending.raw)?;
            if pending.option {
                option_json.insert(pending.name, parsed);
            } else {
                required_json.insert(pending.name, parsed);
            }
        }
        Ok(AdmittedCommand {
            handler: definition.handler,
            schema: definition.schema(),
            required_text,
            required_json,
            option_flags,
            option_text,
            option_json,
        })
    }
}

struct PendingJson {
    option: bool,
    name: &'static str,
    raw: String,
}

struct ValidatedCommandArguments {
    required_text: BTreeMap<&'static str, String>,
    required_json: BTreeMap<&'static str, Value>,
    option_flags: BTreeSet<&'static str>,
    option_text: BTreeMap<&'static str, String>,
    option_json: BTreeMap<&'static str, Value>,
    pending_json: Vec<PendingJson>,
}

#[derive(Debug)]
pub struct AdmittedCommand {
    handler: CommandFn,
    schema: CliCommandSchema,
    required_text: BTreeMap<&'static str, String>,
    required_json: BTreeMap<&'static str, Value>,
    option_flags: BTreeSet<&'static str>,
    option_text: BTreeMap<&'static str, String>,
    option_json: BTreeMap<&'static str, Value>,
}

impl AdmittedCommand {
    pub fn source_module(&self) -> &'static str {
        self.schema.source_module
    }

    pub fn handler_name(&self) -> &'static str {
        self.schema.handler_name
    }

    pub fn path(&self) -> &'static [&'static str] {
        self.schema.path
    }

    pub fn required_positionals(&self) -> Vec<&'static str> {
        self.schema
            .required_positionals
            .iter()
            .map(RequiredArgumentSpec::name)
            .collect()
    }

    pub fn cardinality(&self) -> CommandCardinality {
        self.schema.cardinality
    }

    pub fn option_specs(&self) -> &'static [OptionSpec] {
        self.schema.options
    }

    pub fn required_kind(&self, name: &str) -> RequiredArgumentKind {
        self.schema
            .required_positionals
            .iter()
            .find(|argument| argument.name == name)
            .map(RequiredArgumentSpec::kind)
            .unwrap_or(RequiredArgumentKind::Text)
    }

    pub fn required_text(&self, name: &str) -> &str {
        self.required_text
            .get(name)
            .map(String::as_str)
            .unwrap_or("")
    }

    pub fn required_json(&self, name: &str) -> &Value {
        self.required_json.get(name).unwrap_or(&Value::Null)
    }

    pub fn option_flag(&self, name: &str) -> bool {
        self.option_flags.contains(name)
    }

    pub fn option_text(&self, name: &str) -> Option<&str> {
        self.option_text.get(name).map(String::as_str)
    }

    pub fn option_json(&self, name: &str) -> Option<&Value> {
        self.option_json.get(name)
    }

    pub fn take_option_json(&mut self, name: &str) -> Option<Value> {
        self.option_json.remove(name)
    }

    fn execute(self) -> Result<CliExecution> {
        (self.handler)(self)
    }
}

fn admission_error(code: &'static str, recovery: &'static str) -> CliCommandError {
    CliCommandError::from_admission(code, recovery)
}

/// Structured handler-side failure for an admissible command whose dispatch
/// route disagrees with the registered command table. This is an interior
/// inconsistency, never an assertion panic: the host-facing boundary always
/// returns a typed failure with a stable problem code.
pub(super) fn handler_error(code: &'static str, recovery: &'static str) -> CliCommandError {
    CliCommandError::from_handler(code, recovery)
}

fn validate_cli_admission(args: &[String]) -> Result<()> {
    if args.len() > MAX_CLI_ARGUMENT_COUNT {
        return Err(
            admission_error("cli_argument_count_exceeded", "reduce_command_arguments").into(),
        );
    }
    if args
        .iter()
        .any(|argument| argument.len() > MAX_CLI_ARGUMENT_BYTES)
    {
        return Err(
            admission_error("cli_argument_bytes_exceeded", "reduce_command_arguments").into(),
        );
    }
    if args.len() > 1
        && args
            .first()
            .is_some_and(|value| matches!(value.as_str(), "help" | "--help" | "-h"))
    {
        return Err(admission_error("cli_argument_unexpected", "correct_command_arguments").into());
    }
    Ok(())
}

fn validate_command_arguments(
    path: &'static [&'static str],
    required_positionals: &'static [RequiredArgumentSpec],
    cardinality: CommandCardinality,
    options: &'static [OptionSpec],
    constraints: &'static [OptionConstraintSpec],
    args: &[String],
) -> Result<ValidatedCommandArguments> {
    let mut required_text = BTreeMap::new();
    let required_json = BTreeMap::new();
    let mut option_flags = BTreeSet::new();
    let mut option_text = BTreeMap::new();
    let option_json = BTreeMap::new();
    let mut pending_json = Vec::new();
    let mut cursor = path.len();

    for spec in required_positionals {
        let Some(raw) = args.get(cursor).filter(|value| !value.starts_with("--")) else {
            return Err(admission_error(
                "cli_required_argument_missing",
                "correct_command_arguments",
            )
            .into());
        };
        match spec.kind {
            RequiredArgumentKind::Text => {
                required_text.insert(spec.name, raw.clone());
            }
            RequiredArgumentKind::Json => pending_json.push(PendingJson {
                option: false,
                name: spec.name,
                raw: raw.clone(),
            }),
        }
        cursor += 1;
    }

    if cardinality == CommandCardinality::Exact {
        if cursor != args.len() {
            let code = if args[cursor].starts_with("--") {
                "cli_option_unknown"
            } else {
                "cli_argument_unexpected"
            };
            return Err(admission_error(code, "correct_command_arguments").into());
        }
    } else {
        while cursor < args.len() {
            let raw_name = args[cursor].strip_prefix("--").ok_or_else(|| {
                admission_error("cli_argument_unexpected", "correct_command_arguments")
            })?;
            let spec = options
                .iter()
                .find(|candidate| candidate.name == raw_name)
                .ok_or_else(|| {
                    admission_error("cli_option_unknown", "correct_command_arguments")
                })?;
            let already_present = option_flags.contains(spec.name)
                || option_text.contains_key(spec.name)
                || pending_json
                    .iter()
                    .any(|pending| pending.option && pending.name == spec.name);
            if already_present && !spec.repeatable {
                return Err(
                    admission_error("cli_option_duplicate", "correct_command_arguments").into(),
                );
            }
            cursor += 1;
            match spec.arity {
                OptionArity::Boolean => {
                    option_flags.insert(spec.name);
                }
                OptionArity::Value => {
                    let Some(raw) = args.get(cursor).filter(|value| !value.starts_with("--"))
                    else {
                        return Err(admission_error(
                            "cli_option_value_missing",
                            "correct_command_arguments",
                        )
                        .into());
                    };
                    match spec.value_kind {
                        RequiredArgumentKind::Text => {
                            option_text.insert(spec.name, raw.clone());
                        }
                        RequiredArgumentKind::Json => pending_json.push(PendingJson {
                            option: true,
                            name: spec.name,
                            raw: raw.clone(),
                        }),
                    }
                    cursor += 1;
                }
            }
        }
    }

    for spec in options.iter().filter(|spec| spec.required) {
        let present = option_flags.contains(spec.name)
            || option_text.contains_key(spec.name)
            || pending_json
                .iter()
                .any(|pending| pending.option && pending.name == spec.name);
        if !present {
            return Err(admission_error(
                "cli_required_option_missing",
                "correct_command_arguments",
            )
            .into());
        }
    }
    validate_option_constraints(constraints, &option_flags, &option_text, &pending_json)?;

    Ok(ValidatedCommandArguments {
        required_text,
        required_json,
        option_flags,
        option_text,
        option_json,
        pending_json,
    })
}

fn validate_option_constraints(
    constraints: &'static [OptionConstraintSpec],
    option_flags: &BTreeSet<&'static str>,
    option_text: &BTreeMap<&'static str, String>,
    pending_json: &[PendingJson],
) -> Result<()> {
    let present = |name: &str| {
        option_flags.contains(name)
            || option_text.contains_key(name)
            || pending_json
                .iter()
                .any(|pending| pending.option && pending.name == name)
    };
    for constraint in constraints {
        let member_count = constraint
            .members
            .iter()
            .filter(|member| present(member))
            .count();
        let valid = match constraint.kind {
            OptionConstraintKind::AtLeastOne => member_count >= 1,
            OptionConstraintKind::MutuallyExclusive => member_count <= 1,
            OptionConstraintKind::OneOf => member_count == 1,
            OptionConstraintKind::ConditionalRequired => {
                let condition_matches = constraint
                    .condition_option
                    .zip(constraint.condition_value)
                    .is_some_and(|(name, value)| {
                        option_text.get(name).map(String::as_str) == Some(value)
                    });
                !condition_matches || constraint.required_option.is_some_and(|name| present(name))
            }
        };
        if !valid {
            return Err(admission_error(
                "cli_option_constraint_violation",
                "correct_command_arguments",
            )
            .into());
        }
    }
    Ok(())
}

pub fn parse_json_arg(raw: &str) -> Result<Value> {
    serde_json::from_str(raw).map_err(|_| {
        CliCommandError::from_admission("cli_json_invalid", "provide_valid_json").into()
    })
}

pub fn cli_command_schemas() -> Vec<CliCommandSchema> {
    build_command_table().schemas()
}

pub fn admit_cli_command(args: Vec<String>) -> Result<AdmittedCommand> {
    build_command_table().admit(args)
}

pub fn execute_cli(args: Vec<String>) -> Result<CliExecution> {
    if matches!(
        args.as_slice(),
        [value] if matches!(value.as_str(), "help" | "--help" | "-h")
    ) {
        let _ = build_command_table().help_text();
        return Ok(CliExecution::Usage);
    }
    admit_cli_command(args)?.execute()
}

pub fn cli_params(args: &[String]) -> Value {
    let mut params = Map::new();
    let mut positionals = Vec::<Value>::new();
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        if let Some(raw_key) = argument.strip_prefix("--") {
            let key = cli_param_key(raw_key);
            if let Some(value) = args.get(index + 1).filter(|value| !value.starts_with("--")) {
                params.insert(key, json!(value));
                index += 2;
            } else {
                params.insert(key, json!(true));
                index += 1;
            }
        } else {
            positionals.push(json!(argument));
            index += 1;
        }
    }
    if !positionals.is_empty() {
        if !params.contains_key("target") {
            if let Some(target) = positionals.first().and_then(Value::as_str) {
                params.insert("target".to_string(), json!(target));
            }
        }
        params.insert("positionals".to_string(), Value::Array(positionals));
    }
    Value::Object(params)
}

pub(super) fn admitted_params(
    text_values: &[(&str, Option<&str>)],
    json_values: &[(&str, Option<&Value>)],
    flags: &[(&str, bool)],
) -> Value {
    let mut params = Map::new();
    for (key, value) in text_values {
        if let Some(value) = value {
            params.insert((*key).to_string(), json!(value));
        }
    }
    for (key, value) in json_values {
        if let Some(value) = value {
            params.insert((*key).to_string(), (*value).clone());
        }
    }
    for (key, value) in flags {
        if *value {
            params.insert((*key).to_string(), Value::Bool(true));
        }
    }
    Value::Object(params)
}

fn cli_param_key(raw: &str) -> String {
    let mut output = String::new();
    let mut uppercase_next = false;
    for character in raw.chars() {
        if character == '-' || character == '_' {
            uppercase_next = true;
        } else if uppercase_next {
            output.extend(character.to_uppercase());
            uppercase_next = false;
        } else {
            output.push(character);
        }
    }
    output
}

const UPDATE_ROUTE_OPTIONS: &[OptionSpec] = &[
    OptionSpec {
        name: "channel",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "manifest-path",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "public-keys-path",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "revocation-path",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "source-path",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "source",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "repo",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "staging-root",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "state-root",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "current-version",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "execute",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "install-root",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "gui-pid",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
    OptionSpec {
        name: "wait-for-script",
        arity: OptionArity::Value,
        repeatable: false,
        value_kind: RequiredArgumentKind::Text,
        required: false,
    },
];

const UPDATE_ROUTE_CONSTRAINTS: &[OptionConstraintSpec] = &[
    OptionConstraintSpec {
        kind: OptionConstraintKind::MutuallyExclusive,
        members: &["source-path", "source"],
        condition_option: None,
        condition_value: None,
        required_option: None,
    },
    OptionConstraintSpec {
        kind: OptionConstraintKind::MutuallyExclusive,
        members: &["source-path", "repo"],
        condition_option: None,
        condition_value: None,
        required_option: None,
    },
];

fn build_command_table() -> CommandTable {
    let mut table = CommandTable::new();
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_catalog",
        path: &["adapter", "catalog"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: adapter::handle_catalog,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_antigravity_status",
        path: &["adapter", "antigravity", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: adapter::handle_antigravity_status,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_antigravity_install",
        path: &["adapter", "antigravity", "install"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: adapter::handle_antigravity_install,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_antigravity_uninstall",
        path: &["adapter", "antigravity", "uninstall"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: adapter::handle_antigravity_uninstall,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_antigravity_authorize",
        path: &["adapter", "antigravity", "authorize"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "binary-path",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_antigravity_authorize,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_codex_plugin_status",
        path: &["adapter", "codex", "plugin", "status"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "binary-path",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_codex_plugin_status,
        help: "Probe the managed LicoUp Codex Plugin without exposing local inventory.",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_codex_plugin_plan",
        path: &["adapter", "codex", "plugin", "plan"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "binary-path",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_codex_plugin_plan,
        help: "Plan an explicitly confirmed GitHub LicoUp Codex Plugin installation.",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_codex_plugin_install",
        path: &["adapter", "codex", "plugin", "install"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_codex_plugin_install,
        help: "Install the digest-bound LicoUp Codex Plugin after confirmation.",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_subagent_mcp_status",
        path: &["adapter", "subagent-mcp", "status"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "mcp-binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_subagent_mcp_status,
        help: "Probe Subagent MCP readiness for a main agent without silent install.",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_subagent_mcp_plan",
        path: &["adapter", "subagent-mcp", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "mcp-binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_subagent_mcp_plan,
        help: "Plan a digest-confirmed Subagent MCP install for a supported main agent.",
    });
    table.register_command(CommandSpec {
        source_module: "adapter.rs",
        handler_name: "handle_subagent_mcp_install",
        path: &["adapter", "subagent-mcp", "install"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "mcp-binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: adapter::handle_subagent_mcp_install,
        help: "Install Subagent MCP for a supported main agent after digest confirmation.",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "open"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "send"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "steer"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "cancel"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "capabilities"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "stream"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agent_conversation",
        path: &["agent", "conversation", "cleanup"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agent_conversation,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_conversation.rs",
        handler_name: "handle_conversation_execute",
        path: &["conversation", "execute"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: client_conversation::handle_conversation_execute,
        help: "Execute a canonical Conversation action.",
    });
    table.register_command(CommandSpec {
        source_module: "strategy.rs",
        handler_name: "handle_strategy_execute",
        path: &["strategy", "execute"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: strategy::handle_strategy_execute,
        help: "Execute an Adaptive Flywheel strategy action.",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agents_pair",
        path: &["agents", "pair", "request"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agents_pair,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agents_pair",
        path: &["agents", "pair", "approve"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agents_pair,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agents_pair",
        path: &["agents", "pair", "revoke"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agents_pair,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_conversation.rs",
        handler_name: "handle_agents_pair",
        path: &["agents", "pair", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_conversation::handle_agents_pair,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_hub.rs",
        handler_name: "handle_catalog",
        path: &["agent-hub", "catalog"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_hub::handle_catalog,
        help: "Project Agent Hub cards from warehouse recipes; optional agent-id runs one live local lookup",
    });
    table.register_command(CommandSpec {
        source_module: "agent_hub.rs",
        handler_name: "handle_plan",
        path: &["agent-hub", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "operation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_hub::handle_plan,
        help: "Plan one Agent Hub install, update, or uninstall",
    });
    table.register_command(CommandSpec {
        source_module: "agent_hub.rs",
        handler_name: "handle_apply",
        path: &["agent-hub", "apply"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "operation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "cancel",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_hub::handle_apply,
        help: "Apply one confirmed Agent Hub plan",
    });
    table.register_command(CommandSpec {
        source_module: "agent_usage.rs",
        handler_name: "handle_agent_usage_scan",
        path: &["agent-usage", "scan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "history-days",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "timezone-offset-minutes",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "timezone-transitions-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "force-refresh",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "state-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_usage::handle_agent_usage_scan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "agent_usage.rs",
        handler_name: "handle_agent_usage_report",
        path: &["agent-usage", "report"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "state-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: agent_usage::handle_agent_usage_report,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "resource_usage.rs",
        handler_name: "handle_resource_usage_scan",
        path: &["resource-usage", "scan"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "state-root",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: resource_usage::handle_resource_usage_scan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "status"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "check"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "download"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "verify"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "apply"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "client_update.rs",
        handler_name: "handle_update",
        path: &["update", "rollback"],
        required_positionals: &[],
        options: UPDATE_ROUTE_OPTIONS,
        constraints: UPDATE_ROUTE_CONSTRAINTS,
        cardinality: CommandCardinality::Options,
        handler: client_update::handle_update,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_status",
        path: &["collaboration", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_status,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_enable",
        path: &["collaboration", "enable"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_enable,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_install_plan",
        path: &["collaboration", "install", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "github-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["github-url", "plan-id"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_install_plan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_install_apply",
        path: &["collaboration", "install", "apply"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "github-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["github-url", "plan-id"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_install_apply,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_install_cancel",
        path: &["collaboration", "install", "cancel"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "github-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["github-url", "plan-id"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_install_cancel,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_workflow_catalog",
        path: &["collaboration", "workflow", "catalog"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_workflow_catalog,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_deployment_plan",
        path: &["collaboration", "workflow", "local-deployment", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "selected-feature-ids",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "destination",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "destination-confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-plan-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-package-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_local_deployment_plan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_deployment_apply",
        path: &["collaboration", "workflow", "local-deployment", "apply"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "selected-feature-ids",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "destination",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "destination-confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-plan-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-package-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_local_deployment_apply,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_mcp_install_plan",
        path: &["collaboration", "workflow", "mcp-install", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "selected-plugin-ids",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "agent-destinations",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: true,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-plan-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-package-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_mcp_install_plan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_mcp_install_apply",
        path: &["collaboration", "workflow", "mcp-install", "apply"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "selected-plugin-ids",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "agent-destinations",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: true,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-plan-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "expected-package-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_mcp_install_apply,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_workflow_cancel",
        path: &["collaboration", "workflow", "cancel"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "plan-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "expected-plan-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "expected-package-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_workflow_cancel,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_server_status",
        path: &["collaboration", "local-server", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_local_server_status,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_server_start",
        path: &["collaboration", "local-server", "start"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "deployment-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_local_server_start,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_server_stop",
        path: &["collaboration", "local-server", "stop"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "deployment-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_local_server_stop,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_local_server_uninstall",
        path: &["collaboration", "local-server", "uninstall"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "request-origin",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "deployment-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "expected-assembly-manifest-digest-sha256",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: collaboration::handle_local_server_uninstall,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_disable",
        path: &["collaboration", "disable"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_disable,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "collaboration.rs",
        handler_name: "handle_cleanup",
        path: &["collaboration", "cleanup"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: collaboration::handle_cleanup,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mcp.rs",
        handler_name: "handle_preview",
        path: &["mcp", "http", "preview"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mcp::handle_preview,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mcp.rs",
        handler_name: "handle_execute",
        path: &["mcp", "http", "execute"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mcp::handle_execute,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "config", "get"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "authorize",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "hydrate-secrets",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "config", "set"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "station-base-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "relay-enabled",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "pc-client-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "pc-client-name",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "pairing-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "paired",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "reset-pairing",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "pairing", "create"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "pairing-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "pairing", "claim"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "pairing-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "pairing", "status"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "pairing-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "pairing", "revoke"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "pairing-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "pc", "check-in"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "poll"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "sync"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "allow-interaction",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "create"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "create-secure"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "client-intent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "command-kind",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "target-agent-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "workspace-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "body",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "station-base-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "allow-interaction",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "result"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "result-secure"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "idempotency-key",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "acknowledge-receipt-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "commands", "result-replay-proof"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "command-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "mobile.rs",
        handler_name: "handle_mobile_relay",
        path: &["mobile", "relay", "e2ee", "secret-store-cleanup"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "disposable-proof",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: mobile::handle_mobile_relay,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "opencode_serve.rs",
        handler_name: "handle_opencode_serve",
        path: &["opencode-serve", "ensure"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "executable",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "attach-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: opencode_serve::handle_opencode_serve,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "opencode_serve.rs",
        handler_name: "handle_opencode_serve",
        path: &["opencode-serve", "start"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "executable",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "attach-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: opencode_serve::handle_opencode_serve,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "opencode_serve.rs",
        handler_name: "handle_opencode_serve",
        path: &["opencode-serve", "stop"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "executable",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "attach-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: opencode_serve::handle_opencode_serve,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "opencode_serve.rs",
        handler_name: "handle_opencode_serve",
        path: &["opencode-serve", "restart"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "executable",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "attach-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: opencode_serve::handle_opencode_serve,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "opencode_serve.rs",
        handler_name: "handle_opencode_serve",
        path: &["opencode-serve", "status"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "executable",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "attach-url",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: opencode_serve::handle_opencode_serve,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "status"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "payload",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "context",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "ledger-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "envelope", "validate"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "payload",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "context",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "ledger-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "command", "policy"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "payload",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "context",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "ledger-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "command", "evaluate"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "payload",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "context",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "ledger-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "command", "execute"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "payload",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "context",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "ledger-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "device-trust", "evaluate"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "identity",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: true,
            },
            OptionSpec {
                name: "previous-identity",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "trust-state",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "file", "route"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "manifest",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "file", "receive-destination"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "manifest",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: true,
            },
            OptionSpec {
                name: "approved-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "conflict-policy",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "file", "receive-confirmation"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "manifest",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: true,
            },
            OptionSpec {
                name: "approved-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "user-confirmed",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "approval", "request"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "pending-operation-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "decision",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "approval", "fanout"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "pending-operation-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "decision",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "approval", "respond"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "pending-operation-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "decision",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "responding-endpoint-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "response-nonce",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "approval", "inbox"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "pending-operation-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "decision",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "secure_mesh.rs",
        handler_name: "handle_secure_mesh",
        path: &["secure-mesh", "approval", "adapter-capability"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "pending-operation-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "decision",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: secure_mesh::handle_secure_mesh,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_list",
        path: &["skill", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "skill-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_list,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_get",
        path: &["skill", "get"],
        required_positionals: &[RequiredArgumentSpec {
            name: "skill-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "skill-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_get,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_delete_plan",
        path: &["skill", "delete", "plan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "skill",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_delete_plan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_delete_apply",
        path: &["skill", "delete", "apply"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "skill",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_delete_apply,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_visibility",
        path: &["skill", "visibility", "set"],
        required_positionals: &[RequiredArgumentSpec {
            name: "skill-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "hidden",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_visibility,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_usage_report",
        path: &["skill", "usage", "report"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "skill",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "days",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "from",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "to",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["days", "from"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_usage_report,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "skill.rs",
        handler_name: "handle_skill_usage_scan",
        path: &["skill", "usage", "scan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "history-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "home-dir",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "force-refresh",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: skill::handle_skill_usage_scan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_list",
        path: &["snapshots", "list"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "target",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_list,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_restore",
        path: &["snapshots", "restore"],
        required_positionals: &[RequiredArgumentSpec {
            name: "snapshot-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: snapshots::handle_snapshots_restore,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_collect",
        path: &["snapshots", "collect"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "topic",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_collect,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_root",
        path: &["snapshots", "root", "get"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "path",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_root,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_root",
        path: &["snapshots", "root", "set"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "path",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_root,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_profiles",
        path: &["snapshots", "profiles", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "profile-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "profile-file",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["profile", "profile-json", "profile-file"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_profiles,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_profiles",
        path: &["snapshots", "profiles", "get"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "profile-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "profile-file",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["profile", "profile-json", "profile-file"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_profiles,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_profiles",
        path: &["snapshots", "profiles", "import"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "profile-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
            OptionSpec {
                name: "profile-file",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::MutuallyExclusive,
            members: &["profile", "profile-json", "profile-file"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_profiles,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "collect"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "keywords",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "trigger",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "run"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "trigger",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "verify"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "trigger",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "collection-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::OneOf,
            members: &["profile", "collection-path"],
            condition_option: None,
            condition_value: None,
            required_option: None,
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "report"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "profile",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "trigger",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "preview"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "selection-mode",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "query",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::ConditionalRequired,
            members: &[],
            condition_option: Some("selection-mode"),
            condition_value: Some("exact-keyword"),
            required_option: Some("query"),
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "create"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "selection-mode",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "query",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "plan-binding",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[OptionConstraintSpec {
            kind: OptionConstraintKind::ConditionalRequired,
            members: &[],
            condition_option: Some("selection-mode"),
            condition_value: Some("exact-keyword"),
            required_option: Some("query"),
        }],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "status"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "job-id",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "job-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "once",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "events"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "job-id",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "cancel"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "job-id",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_archive",
        path: &["snapshots", "archive", "jobs", "drain"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "job-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "once",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_archive,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_snapshots_collections",
        path: &["snapshots", "collections", "list"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "snapshot-root",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_snapshots_collections,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_conversations",
        path: &["conversations", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "offset",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "session-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "text",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_conversations,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_conversations",
        path: &["conversations", "stream"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "offset",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "session-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "text",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_conversations,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_conversations",
        path: &["conversations", "append"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "offset",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "session-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "text",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_conversations,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "snapshots.rs",
        handler_name: "handle_conversations",
        path: &["conversations", "delete"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "agent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "offset",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "session-id",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "text",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: snapshots::handle_conversations,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "state.rs",
        handler_name: "handle_state_get",
        path: &["state", "get"],
        required_positionals: &[RequiredArgumentSpec {
            name: "collection",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: state::handle_state_get,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "state.rs",
        handler_name: "handle_state_set",
        path: &["state", "set"],
        required_positionals: &[
            RequiredArgumentSpec {
                name: "collection",
                kind: RequiredArgumentKind::Text,
            },
            RequiredArgumentSpec {
                name: "payload",
                kind: RequiredArgumentKind::Json,
            },
        ],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: state::handle_state_set,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "state.rs",
        handler_name: "handle_activity_list",
        path: &["activity", "list"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "type",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "limit",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: state::handle_activity_list,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "targets.rs",
        handler_name: "handle_targets_scan",
        path: &["targets", "scan"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "state-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "include-accessible-environments",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "include-history-model-catalog",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "enable-agent-cli-model-lookup",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: targets::handle_targets_scan,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "targets.rs",
        handler_name: "handle_targets_add",
        path: &["targets", "add"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "target",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "config-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "binary-path",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "history-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "state-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "stdin-json",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Json,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: targets::handle_targets_add,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "targets.rs",
        handler_name: "handle_targets_inspect",
        path: &["targets", "inspect"],
        required_positionals: &[RequiredArgumentSpec {
            name: "target",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[
            OptionSpec {
                name: "state-root",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "include-accessible-environments",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "enable-agent-cli-model-lookup",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: targets::handle_targets_inspect,
        help: "",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_status",
        path: &["llm-gateway", "credentials", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_status,
        help: "System-keyring availability and lease options",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_list",
        path: &["llm-gateway", "credentials", "list"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_list,
        help: "List non-secret model API key metadata without authorization",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_authorize",
        path: &["llm-gateway", "credentials", "authorize"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "credential-id",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_authorize,
        help: "Authorize loading model API keys into the native app session",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_clear",
        path: &["llm-gateway", "credentials", "clear"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "credential-id",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_clear,
        help: "Clear model API keys from the native app session without deleting vault entries",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_create",
        path: &["llm-gateway", "credentials", "create"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_create,
        help: "Save a private stdin API key after system authorization",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_delete",
        path: &["llm-gateway", "credentials", "delete"],
        required_positionals: &[RequiredArgumentSpec {
            name: "credential-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_delete,
        help: "Permanently delete one Keychain item",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_lease",
        path: &["llm-gateway", "credentials", "lease"],
        required_positionals: &[RequiredArgumentSpec {
            name: "days",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_lease,
        help: "Set process lease to 7/30/60/90/180/365 days",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_update",
        path: &["llm-gateway", "credentials", "update"],
        required_positionals: &[RequiredArgumentSpec {
            name: "credential-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_update,
        help: "Rename a credential or extend its validity period",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_agent_plan",
        path: &["llm-gateway", "agent-config", "plan"],
        required_positionals: &[
            RequiredArgumentSpec {
                name: "agent",
                kind: RequiredArgumentKind::Text,
            },
            RequiredArgumentSpec {
                name: "config-root",
                kind: RequiredArgumentKind::Text,
            },
        ],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_agent_plan,
        help: "Preview a secret-free Codex, Claude Code, OpenCode, or Pi Gateway configuration",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_agent_apply",
        path: &["llm-gateway", "agent-config", "apply"],
        required_positionals: &[
            RequiredArgumentSpec {
                name: "agent",
                kind: RequiredArgumentKind::Text,
            },
            RequiredArgumentSpec {
                name: "config-root",
                kind: RequiredArgumentKind::Text,
            },
        ],
        options: &[
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "confirmation",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "confirmed",
                arity: OptionArity::Boolean,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_agent_apply,
        help: "Apply a confirmed secret-free Gateway profile",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_status",
        path: &["llm-gateway", "service", "status"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_service_status,
        help: "Report the local LLM Gateway service state",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_usage",
        path: &["llm-gateway", "service", "usage"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_service_usage,
        help: "Report request counts observed by the local LLM Gateway",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_initialize",
        path: &["llm-gateway", "service", "initialize"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_service_initialize,
        help: "Initialize the local LLM Gateway service without authorization",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_start",
        path: &["llm-gateway", "service", "start"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_service_start,
        help: "Start the managed local LLM Gateway service",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_stop",
        path: &["llm-gateway", "service", "stop"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_service_stop,
        help: "Stop the managed local LLM Gateway service",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_autostart_status",
        path: &["llm-gateway", "service", "autostart-status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_service_autostart_status,
        help: "Report whether the LLM Gateway starts at user login",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_autostart_enable",
        path: &["llm-gateway", "service", "autostart-enable"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: llm_gateway::handle_service_autostart_enable,
        help: "Install login autostart for the local LLM Gateway (starts alone, no credentials)",
    });
    table.register_command(CommandSpec {
        source_module: "llm_gateway.rs",
        handler_name: "handle_service_autostart_disable",
        path: &["llm-gateway", "service", "autostart-disable"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: llm_gateway::handle_service_autostart_disable,
        help: "Remove login autostart for the local LLM Gateway",
    });
    table.register_command(CommandSpec {
        source_module: "autostart.rs",
        handler_name: "handle_status",
        path: &["autostart", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: autostart::handle_status,
        help: "Report desktop, Gateway, and local MCP login autostart state",
    });
    table.register_command(CommandSpec {
        source_module: "autostart.rs",
        handler_name: "handle_set",
        path: &["autostart", "set"],
        required_positionals: &[],
        options: &[
            OptionSpec {
                name: "component",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "enabled",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: true,
            },
            OptionSpec {
                name: "silent",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
            OptionSpec {
                name: "port",
                arity: OptionArity::Value,
                repeatable: false,
                value_kind: RequiredArgumentKind::Text,
                required: false,
            },
        ],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: autostart::handle_set,
        help: "Enable or disable login autostart for desktop, gateway, or mcp",
    });
    table.register_command(CommandSpec {
        source_module: "autostart.rs",
        handler_name: "handle_prepare_mcp",
        path: &["autostart", "prepare-mcp"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: autostart::handle_prepare_mcp,
        help: "Login oneshot: verify packaged local MCP binaries without silent install",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_help",
        path: &["gateway", "help"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_help,
        help: "Describe the two-layer Gateway Runtime CLI",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_client_token",
        path: &["gateway", "client-token"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "agent",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_client_token,
        help: "Print the private local Gateway client token for an admitted agent",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_service_status",
        path: &["gateway", "service", "status"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_service_status,
        help: "Report Gateway Runtime state (LLM + channels)",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_service_start",
        path: &["gateway", "service", "start"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_service_start,
        help: "Start the unified Gateway Runtime process",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_service_stop",
        path: &["gateway", "service", "stop"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_service_stop,
        help: "Stop the unified Gateway Runtime process",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_service_initialize",
        path: &["gateway", "service", "initialize"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "port",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Text,
            required: false,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_service_initialize,
        help: "Initialize the Gateway Runtime without credential authorization",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_inventory_reload",
        path: &["gateway", "inventory", "reload"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_inventory_reload,
        help: "Hot-reload verified conversation readiness into the running Gateway",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_channel_status",
        path: &["gateway", "channel", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_channel_status,
        help: "Report Communication Channel layer status",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_credentials_status",
        path: &["gateway", "channel", "telegram", "credentials", "status"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_telegram_credentials_status,
        help: "Report whether a Telegram bot token is configured",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_credentials_set",
        path: &["gateway", "channel", "telegram", "credentials", "set"],
        required_positionals: &[],
        options: &[OptionSpec {
            name: "stdin-json",
            arity: OptionArity::Value,
            repeatable: false,
            value_kind: RequiredArgumentKind::Json,
            required: true,
        }],
        constraints: &[],
        cardinality: CommandCardinality::Options,
        handler: gateway::handle_telegram_credentials_set,
        help: "Store a Telegram bot token from private stdin JSON",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_credentials_clear",
        path: &["gateway", "channel", "telegram", "credentials", "clear"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_telegram_credentials_clear,
        help: "Remove the stored Telegram bot token",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_pairing_list",
        path: &["gateway", "channel", "telegram", "pairing", "list"],
        required_positionals: &[],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_telegram_pairing_list,
        help: "List pending Telegram DM pairing codes",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_pairing_approve",
        path: &["gateway", "channel", "telegram", "pairing", "approve"],
        required_positionals: &[RequiredArgumentSpec {
            name: "code",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_telegram_pairing_approve,
        help: "Approve a Telegram DM pairing code",
    });
    table.register_command(CommandSpec {
        source_module: "gateway.rs",
        handler_name: "handle_telegram_pairing_revoke",
        path: &["gateway", "channel", "telegram", "pairing", "revoke"],
        required_positionals: &[RequiredArgumentSpec {
            name: "chat-id",
            kind: RequiredArgumentKind::Text,
        }],
        options: &[],
        constraints: &[],
        cardinality: CommandCardinality::Exact,
        handler: gateway::handle_telegram_pairing_revoke,
        help: "Revoke Telegram DM access for a chat id",
    });
    table
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Host-facing boundary guard: malformed JSON admitted as an FFI command
    /// argument yields a structured typed failure (problem code preserved
    /// downcast as `CliCommandError`) and never unwinds the process; the
    /// boundary remains able to serve the next command.
    #[test]
    fn ffi_boundary_malformed_json_is_structured_failure_with_process_alive() {
        let malformed = execute_cli(vec![
            "agent".to_string(),
            "conversation".to_string(),
            "open".to_string(),
            "--stdin-json".to_string(),
            "{not-json:".to_string(),
        ]);
        let error = malformed.expect_err("malformed JSON must be rejected at the boundary");
        let command_error = error
            .downcast_ref::<CliCommandError>()
            .expect("boundary failure must be typed as CliCommandError");
        assert_eq!(command_error.code(), "cli_json_invalid");
        assert_eq!(command_error.stage(), "cli/admission");
        assert!(!command_error.retryable());

        // The same process boundary still serves a subsequent valid command.
        match execute_cli(vec!["adapter".to_string(), "catalog".to_string()]) {
            Ok(CliExecution::Json(value)) => assert_eq!(value["ok"], true),
            Ok(_) => assert!(
                false,
                "catalog command must return JSON after a rejected request"
            ),
            Err(error) => assert!(
                false,
                "catalog command must succeed after a rejected request: {error}"
            ),
        }
    }
}
