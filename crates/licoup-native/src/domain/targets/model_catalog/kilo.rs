use super::*;

pub(super) fn collect_kilo_code_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(home) = home_dir_for_model_catalog(params) else {
        diagnostics.push(json!({
            "source": "kilo-state",
            "status": "home-unavailable",
        }));
        return;
    };

    let vscode_state_paths = {
        let explicit = param_paths(params, &["kiloVsCodeStateDbPath", "kiloVscodeStateDbPath"]);
        if explicit.is_empty() {
            kilo_vscode_state_db_paths(&home)
        } else {
            explicit
        }
    };
    for path in vscode_state_paths {
        collect_kilo_models_from_vscode_state_db(&path, entries, diagnostics);
    }

    let kilo_db_paths = {
        let explicit = param_paths(params, &["kiloDbPath", "kiloDatabasePath"]);
        if explicit.is_empty() {
            vec![
                home.join(".local")
                    .join("share")
                    .join("kilo")
                    .join("kilo.db"),
            ]
        } else {
            explicit
        }
    };
    for path in kilo_db_paths {
        collect_kilo_models_from_local_db(&path, entries, diagnostics);
    }
}

pub(super) fn kilo_vscode_state_db_paths(home: &Path) -> Vec<PathBuf> {
    let roots = match std::env::consts::OS {
        "windows" => {
            let app_data = default_app_data_dir(home);
            vec![
                app_data.join("Code"),
                app_data.join("Code - Insiders"),
                app_data.join("Cursor"),
                app_data.join("VSCodium"),
            ]
        }
        "macos" => {
            let app_support = home.join("Library").join("Application Support");
            vec![
                app_support.join("Code"),
                app_support.join("Code - Insiders"),
                app_support.join("Cursor"),
                app_support.join("VSCodium"),
            ]
        }
        _ => vec![
            home.join(".config").join("Code"),
            home.join(".config").join("Code - Insiders"),
            home.join(".config").join("Cursor"),
            home.join(".config").join("VSCodium"),
        ],
    };
    roots
        .into_iter()
        .map(|root| root.join("User").join("globalStorage").join("state.vscdb"))
        .filter(|path| path.exists())
        .collect()
}

pub(super) fn collect_kilo_models_from_vscode_state_db(
    path: &Path,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(connection) = open_sqlite_readonly(path) else {
        if path.exists() {
            diagnostics.push(json!({
                "source": "kilo-vscode-state",
                "status": "not-readable",
            }));
        }
        return;
    };
    let mut statement = match connection.prepare("SELECT value FROM ItemTable WHERE key=?1") {
        Ok(statement) => statement,
        Err(_) => {
            diagnostics.push(json!({
                "source": "kilo-vscode-state",
                "status": "schema-mismatch",
            }));
            return;
        }
    };
    let value = statement
        .query_row(["kilocode.kilo-code"], |row| row.get::<_, String>(0))
        .ok();
    let Some(value) = value else {
        return;
    };
    let Ok(parsed) = serde_json::from_str::<Value>(&value) else {
        diagnostics.push(json!({
            "source": "kilo-vscode-state",
            "status": "not-parseable",
        }));
        return;
    };
    collect_kilo_models_from_state_value(&parsed, "kilo-vscode-state", entries);
}

pub(super) fn collect_kilo_models_from_state_value(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let Some(object) = value.as_object() else {
        return;
    };
    for key in ["recentModels", "favoriteModels"] {
        if let Some(items) = object.get(key).and_then(Value::as_array) {
            for item in items {
                collect_kilo_model_ref(item, source, entries);
            }
        }
    }
    if let Some(selections) = object.get("variantSelections").and_then(Value::as_object) {
        for (raw_key, variant) in selections {
            let Some((provider_id, model_id)) =
                kilo_provider_and_model_id_from_selection_key(raw_key)
            else {
                continue;
            };
            let efforts = variant
                .as_str()
                .and_then(sanitize_option_name)
                .into_iter()
                .collect::<BTreeSet<_>>();
            add_model_catalog_entry_with_provider(
                entries,
                &model_id,
                None,
                provider_id.as_deref(),
                None,
                source,
                efforts,
            );
        }
    }
}

pub(super) fn collect_kilo_model_ref(
    value: &Value,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let Some(object) = value.as_object() else {
        return;
    };
    let Some(model_id) = object
        .get("modelID")
        .or_else(|| object.get("modelId"))
        .or_else(|| object.get("id"))
        .or_else(|| object.get("model"))
        .and_then(Value::as_str)
        .and_then(sanitize_model_name)
    else {
        return;
    };
    let efforts = object
        .get("variant")
        .or_else(|| object.get("reasoningEffort"))
        .or_else(|| object.get("thinking"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name)
        .into_iter()
        .collect::<BTreeSet<_>>();
    let provider_id = object
        .get("providerID")
        .or_else(|| object.get("providerId"))
        .or_else(|| object.get("provider_id"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name);
    let provider_name = object
        .get("providerName")
        .or_else(|| object.get("providerLabel"))
        .or_else(|| object.get("provider"))
        .and_then(Value::as_str)
        .and_then(sanitize_option_name);
    add_model_catalog_entry_with_provider(
        entries,
        &model_id,
        model_display_name_from_object(object, &model_id).as_deref(),
        provider_id.as_deref(),
        provider_name.as_deref(),
        source,
        efforts,
    );
}

pub(super) fn kilo_provider_and_model_id_from_selection_key(
    value: &str,
) -> Option<(Option<String>, String)> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parts = trimmed.split('/').collect::<Vec<_>>();
    let (provider_id, model_id) = if parts.len() >= 4 && parts[0] == "agent" {
        (sanitize_option_name(parts[2]), parts[3..].join("/"))
    } else if parts.len() >= 2 && parts[0] == "kilo" {
        (sanitize_option_name(parts[0]), parts[1..].join("/"))
    } else {
        (None, trimmed.to_string())
    };
    sanitize_model_name(&model_id).map(|model_id| (provider_id, model_id))
}

pub(super) fn collect_kilo_models_from_local_db(
    path: &Path,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let Some(connection) = open_sqlite_readonly(path) else {
        if path.exists() {
            diagnostics.push(json!({
                "source": "kilo-local-db",
                "status": "not-readable",
            }));
        }
        return;
    };
    if sqlite_table_exists(&connection, "session_message") {
        collect_kilo_models_from_session_messages(&connection, entries, diagnostics);
    }
    if sqlite_table_exists(&connection, "session") {
        collect_kilo_models_from_session_rows(&connection, entries);
    }
}

pub(super) fn collect_kilo_models_from_session_messages(
    connection: &Connection,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let mut statement = match connection.prepare(
        "SELECT data FROM session_message WHERE type='model-switched' ORDER BY time_created DESC LIMIT 200",
    ) {
        Ok(statement) => statement,
        Err(_) => return,
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(0)) else {
        diagnostics.push(json!({
            "source": "kilo-local-db",
            "status": "query-failed",
        }));
        return;
    };
    for row in rows.flatten() {
        let Ok(value) = serde_json::from_str::<Value>(&row) else {
            continue;
        };
        if let Some(model) = value.get("model") {
            collect_kilo_model_ref(model, "kilo-local-db", entries);
        }
    }
}

pub(super) fn collect_kilo_models_from_session_rows(
    connection: &Connection,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) {
    let mut statement = match connection.prepare(
        "SELECT model FROM session WHERE model IS NOT NULL AND trim(model) <> '' ORDER BY time_updated DESC LIMIT 200",
    ) {
        Ok(statement) => statement,
        Err(_) => return,
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(0)) else {
        return;
    };
    for row in rows.flatten() {
        if let Some(name) = sanitize_model_name(&row) {
            add_model_catalog_entry(entries, &name, "kilo-local-db", BTreeSet::new());
        }
    }
}

pub(super) fn open_sqlite_readonly(path: &Path) -> Option<Connection> {
    if !path.exists() {
        return None;
    }
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
}

pub(super) fn sqlite_table_exists(connection: &Connection, table: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok()
}
