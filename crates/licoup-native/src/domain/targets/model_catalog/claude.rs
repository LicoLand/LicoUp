use super::*;

const CLAUDE_CODE_CURRENT_MODEL_SOURCE: &str = "claude-current";

/// Claude Code has no non-interactive model-catalog command. Project the one
/// model configured for the next native session instead of turning an
/// unsupported `claude models` argument into a prompt and parsing its reply.
pub(super) fn claude_code_current_model_catalog(
    config_path: Option<&Path>,
    params: &Value,
) -> Value {
    let mut diagnostics = Vec::<Value>::new();
    let configured_model = claude_code_settings_path(config_path, params)
        .and_then(|path| read_claude_code_current_model(&path, &mut diagnostics));
    let model = configured_model.unwrap_or_else(|| "default".to_string());

    let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
    let provider_id = inferred_provider_id_from_model(&model);
    add_model_catalog_entry_with_provider(
        &mut entries,
        &model,
        model.eq_ignore_ascii_case("default").then_some("Default"),
        provider_id.as_deref(),
        None,
        CLAUDE_CODE_CURRENT_MODEL_SOURCE,
        BTreeSet::new(),
    );
    if provider_id.is_some() {
        for entry in entries.values_mut() {
            entry.provider_inferred = true;
        }
    }

    build_model_catalog(
        entries,
        BTreeSet::from([CLAUDE_CODE_CURRENT_MODEL_SOURCE.to_string()]),
        diagnostics,
        Some(model),
    )
}

fn claude_code_settings_path(config_path: Option<&Path>, params: &Value) -> Option<PathBuf> {
    config_path.map(Path::to_path_buf).or_else(|| {
        home_dir_for_model_catalog(params).map(|home| home.join(".claude").join("settings.json"))
    })
}

fn read_claude_code_current_model(path: &Path, diagnostics: &mut Vec<Value>) -> Option<String> {
    let source = CLAUDE_CODE_CURRENT_MODEL_SOURCE;
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return None,
        Err(_) => {
            diagnostics.push(json!({"source": source, "status": "not-readable"}));
            return None;
        }
    };
    let Some(settings) = parse_model_config_document(path, &raw) else {
        diagnostics.push(json!({"source": source, "status": "not-parseable"}));
        return None;
    };
    claude_code_current_model_from_settings(&settings)
}

fn claude_code_current_model_from_settings(settings: &Value) -> Option<String> {
    let object = settings.as_object()?;
    object
        .get("env")
        .and_then(Value::as_object)
        .and_then(|env| env.get("ANTHROPIC_MODEL"))
        .map(model_name_from_value)
        .filter(|model| !model.is_empty())
        .or_else(|| {
            object
                .get("model")
                .map(model_name_from_value)
                .filter(|model| !model.is_empty())
        })
}

fn inferred_provider_id_from_model(model: &str) -> Option<String> {
    let prefix = model
        .split_once('/')
        .map(|(provider, _)| provider)
        .or_else(|| model.split_once('-').map(|(provider, _)| provider))?;
    let normalized = sanitize_option_name(prefix)?;
    (normalized.len() >= 2 && normalized.chars().all(|ch| ch.is_ascii_alphanumeric()))
        .then(|| normalized.to_ascii_lowercase())
}
