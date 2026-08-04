use super::*;

mod config_documents {
    use super::*;

    #[test]
    fn model_catalog_reads_models_from_client_config() {
        let dir = temp_test_dir("model-catalog-config");
        let config_path = dir.join("config.toml");
        fs::write(
            &config_path,
            r#"
model = "gpt-5.5"
model_reasoning_effort = "high"

[profiles.review]
model = "gpt-5.4-mini"
"#,
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            Some(&config_path),
            &json!({"includeHistoryModelCatalog": false}),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.5"
                && model["displayName"] == "GPT-5.5"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("high"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4-mini" && model["displayName"] == "GPT-5.4-Mini"
        }));
        let rendered = serde_json::to_string(&catalog).unwrap();
        assert!(!rendered.contains("api_key"));
    }

    #[test]
    fn model_catalog_reads_default_model_from_top_level_config() {
        let dir = temp_test_dir("model-catalog-default-model");
        let config_path = dir.join("config.toml");
        fs::write(
            &config_path,
            r#"
model = "gpt-5.5"

[profiles.review]
model = "gpt-5.4-mini"
"#,
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            Some(&config_path),
            &json!({"includeHistoryModelCatalog": false}),
        );
        // The top-level `model` key is the configured default; nested profile
        // models stay picker entries and never become the default.
        assert_eq!(catalog["defaultModel"], json!("gpt-5.5"));
    }

    #[test]
    fn model_catalog_default_model_prefers_fixture_over_config() {
        let dir = temp_test_dir("model-catalog-default-fixture");
        let config_path = dir.join("config.toml");
        fs::write(&config_path, "model = \"gpt-5.5\"\n").unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            Some(&config_path),
            &json!({
                "includeHistoryModelCatalog": false,
                "modelCatalogFixture": {
                    "codex": {
                        "defaultModel": "fixture-model",
                        "models": ["fixture-model"],
                    },
                },
            }),
        );
        assert_eq!(catalog["defaultModel"], json!("fixture-model"));
    }

    #[test]
    fn model_catalog_without_default_model_emits_empty_string() {
        let dir = temp_test_dir("model-catalog-no-default-model");
        let config_path = dir.join("config.toml");
        fs::write(&config_path, "model_reasoning_effort = \"high\"\n").unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            Some(&config_path),
            &json!({"includeHistoryModelCatalog": false}),
        );
        assert_eq!(catalog["defaultModel"], json!(""));
    }

    #[test]
    fn model_catalog_reads_codex_structured_model_catalog() {
        let home = temp_test_dir("codex-model-catalog");
        let catalog_path = home
            .join(".codex")
            .join("model-catalogs")
            .join("available.json");
        fs::create_dir_all(catalog_path.parent().unwrap()).unwrap();
        fs::write(
            &catalog_path,
            json!({
                "models": [
                    {
                        "slug": "gpt-5.4",
                        "display_name": "gpt-5.4",
                        "supported_reasoning_levels": [
                            {"effort": "medium"}
                        ]
                    },
                    {
                        "slug": "gpt-5.4-mini",
                        "display_name": "GPT-5.4-Mini",
                        "supported_reasoning_levels": [
                            {"effort": "low"},
                            {"effort": "medium"},
                            {"effort": "high"},
                            {"effort": "xhigh"}
                        ]
                    },
                    {
                        "slug": "deepseek-v4-pro",
                        "display_name": "DeepSeek V4 Pro",
                        "supported_reasoning_levels": [
                            {"effort": "high"}
                        ]
                    },
                    {
                        "slug": "codex-auto-review",
                        "display_name": "Codex Auto Review",
                        "visibility": "hide",
                        "supported_reasoning_levels": [
                            {"effort": "high"}
                        ]
                    }
                ]
            })
            .to_string(),
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "codex",
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4"
                && model["displayName"] == "GPT-5.4"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("medium"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "gpt-5.4-mini"
                && model["displayName"] == "GPT-5.4-Mini"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("xhigh"))
        }));
        assert!(models.iter().any(|model| {
            model["name"] == "deepseek-v4-pro"
                && model["displayName"] == "DeepSeek V4 Pro"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("high"))
        }));
        assert!(
            !models
                .iter()
                .any(|model| model["name"] == "codex-auto-review")
        );
    }

    #[test]
    fn model_catalog_reads_claude_code_settings_models() {
        let home = temp_test_dir("claude-code-model-catalog");
        let settings_path = home.join(".claude").join("settings.json");
        fs::create_dir_all(settings_path.parent().unwrap()).unwrap();
        fs::write(
            &settings_path,
            json!({
                "env": {
                    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-flash",
                    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-pro",
                    "CLAUDE_CODE_EFFORT_LEVEL": "xhigh"
                }
            })
            .to_string(),
        )
        .unwrap();

        let catalog = model_catalog_for_target(
            "claude-code",
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "deepseek-v4-pro[1m]"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("xhigh"))
        }));
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek-v4-flash")
        );
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek-v4-pro")
        );
        assert_eq!(catalog["defaultModel"], json!("deepseek-v4-pro[1m]"));
    }
}

mod antigravity {
    use super::super::antigravity::collect_model_catalog_from_cli_lines;
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    #[cfg(unix)]
    use std::time::{Duration, Instant};

    #[test]
    fn model_catalog_preserves_antigravity_available_model_names() {
        let catalog = model_catalog_for_target(
            "antigravity",
            None,
            &json!({
                "includeHistoryModelCatalog": false,
                "antigravityAvailableModelsJson": json!({
                    "models": {
                        "gemini-flash-medium": {
                            "displayName": "Gemini 3.5 Flash (Medium)",
                            "reasoningEfforts": ["low", "medium", "high"]
                        },
                        "claude-opus-thinking": {
                            "displayName": "Claude Opus 4.6 (Thinking)",
                            "reasoningEfforts": ["high"]
                        }
                    }
                }).to_string()
            }),
        );

        let names = catalog["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|model| model["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert!(names.contains(&"Gemini 3.5 Flash (Medium)"));
        assert!(names.contains(&"Claude Opus 4.6 (Thinking)"));
        assert!(
            catalog["models"]
                .as_array()
                .unwrap()
                .iter()
                .all(|model| model["reasoningEfforts"].as_array().unwrap().is_empty())
        );
    }

    #[test]
    fn model_catalog_reads_antigravity_cli_model_lines() {
        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let added = collect_model_catalog_from_cli_lines(
            r#"
Gemini 3.5 Flash (Medium)
Gemini 3.5 Flash (High)
Claude Opus 4.6 (Thinking)
"#,
            "antigravity-cli:models",
            &mut entries,
        );

        assert_eq!(added, 3);
        assert!(entries.values().any(|entry| {
            entry.name == "Gemini 3.5 Flash (Medium)" && entry.provider.is_none()
        }));
        assert!(entries.values().all(|entry| !entry.provider_inferred));
    }

    #[cfg(unix)]
    #[test]
    fn antigravity_cli_model_lookup_preserves_real_results() {
        let dir = temp_test_dir("antigravity-cli-models");
        let config_path = dir.join("settings.json");
        fs::write(&config_path, r#"{"model":"gemini-3.1-pro-preview"}"#).unwrap();
        let executable = dir.join("agent-models");
        fs::write(
            &executable,
            "#!/bin/sh\nprintf 'gemini-3.6-flash-medium\\nclaude-opus-4-6-thinking\\ngpt-oss-120b-medium\\n'\n",
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();

        let catalog = model_catalog_for_target(
            "antigravity",
            Some(&config_path),
            &json!({
                "includeHistoryModelCatalog": false,
                "enableAgentCliModelLookup": true,
                "antigravityCliPath": display_path(executable),
            }),
        );

        assert!(
            catalog["models"]
                .as_array()
                .unwrap()
                .iter()
                .any(|model| model["name"] == "gemini-3.6-flash-medium")
        );
        assert!(
            !catalog["models"]
                .as_array()
                .unwrap()
                .iter()
                .any(|model| model["name"] == "gemini-3.1-pro-preview")
        );
        assert!(
            catalog["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("antigravity-cli"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn antigravity_cli_model_lookup_times_out_without_blocking_catalog() {
        let dir = temp_test_dir("antigravity-cli-timeout");
        let executable = dir.join("agent-models");
        fs::write(&executable, "#!/bin/sh\nsleep 30\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let started = Instant::now();

        let catalog = model_catalog_for_target(
            "antigravity",
            None,
            &json!({
                "includeHistoryModelCatalog": false,
                "enableAgentCliModelLookup": true,
                "antigravityCliPath": display_path(executable),
                "antigravityCliModelLookupTimeoutMs": 100,
            }),
        );

        assert!(started.elapsed() < Duration::from_secs(3));
        assert!(catalog["diagnostics"].as_array().unwrap().iter().any(
            |diagnostic| diagnostic["source"] == "antigravity-cli:models"
                && diagnostic["status"] == "timeout"
        ));
    }
}

mod cursor {
    use super::super::cursor::collect_cursor_model_catalog_from_cli_output;
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn cursor_cli_output_preserves_native_selector_ids() {
        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let added = collect_cursor_model_catalog_from_cli_output(
            "Available models\n\ncursor-grok-4.5-high - Cursor Grok 4.5\ngemini-3.6-flash-high - Gemini 3.6 Flash\n\nTip: use --model <id>\n",
            "cursor-cli:models",
            &mut entries,
        );

        assert_eq!(added.added, 2);
        let grok = entries.get("cursor-grok-4.5-high").unwrap();
        assert_eq!(grok.name, "cursor-grok-4.5-high");
        assert_eq!(grok.display_name, "Cursor Grok 4.5");
        assert!(!entries.contains_key("Available models"));
    }

    #[cfg(unix)]
    #[test]
    fn cursor_cli_model_lookup_reads_installed_catalog() {
        let dir = temp_test_dir("cursor-cli-models");
        let executable = dir.join("cursor-agent");
        fs::write(
            &executable,
            "#!/bin/sh\nprintf 'Available models\\n\\nauto - Auto (default)\\ncursor-grok-4.5-high - Cursor Grok 4.5\\ncomposer-2.5 - Composer 2.5 (current)\\n'\n",
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();

        let catalog = model_catalog_for_target(
            "cursor",
            None,
            &json!({
                "includeHistoryModelCatalog": false,
                "enableAgentCliModelLookup": true,
                "cursorCliPath": display_path(executable),
            }),
        );

        assert!(catalog["models"].as_array().unwrap().iter().any(|model| {
            model["name"] == "cursor-grok-4.5-high" && model["displayName"] == "Cursor Grok 4.5"
        }));
        assert_eq!(catalog["defaultModel"], json!("auto"));
        assert!(catalog["models"].as_array().unwrap().iter().any(|model| {
            model["name"] == "composer-2.5" && model["displayName"] == "Composer 2.5"
        }));
        assert!(
            catalog["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("cursor-cli"))
        );
    }

    #[test]
    fn cursor_cli_output_keeps_default_and_current_rows_separate() {
        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let parsed = collect_cursor_model_catalog_from_cli_output(
            "Available models\n\nauto - Auto (default)\ncomposer-2.5 - Composer 2.5 (current)\n",
            "cursor-cli:models",
            &mut entries,
        );

        assert_eq!(parsed.default_model.as_deref(), Some("auto"));
        assert_eq!(parsed.current_model.as_deref(), Some("composer-2.5"));
        assert_eq!(entries.get("auto").unwrap().display_name, "Auto");
    }

    #[cfg(unix)]
    #[test]
    fn cursor_native_catalog_replaces_stale_config_models() {
        let dir = temp_test_dir("cursor-authoritative-models");
        let config_path = dir.join("settings.json");
        fs::write(&config_path, r#"{"model":"stale-cursor-model"}"#).unwrap();
        let executable = dir.join("cursor-agent");
        fs::write(
            &executable,
            "#!/bin/sh\nprintf 'Available models\\n\\ncomposer-2.5 - Composer 2.5 (current)\\n'\n",
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();

        let catalog = model_catalog_for_target(
            "cursor",
            Some(&config_path),
            &json!({
                "includeHistoryModelCatalog": false,
                "enableAgentCliModelLookup": true,
                "cursorCliPath": display_path(executable),
            }),
        );

        let names = catalog["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|model| model["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(names, vec!["composer-2.5"]);
        assert_eq!(catalog["defaultModel"], json!("composer-2.5"));
    }
}

mod kimi_code {
    use super::*;

    #[test]
    fn qualified_history_names_fold_into_official_native_ids() {
        let catalog = model_catalog_for_target(
            "kimi-code",
            None,
            &json!({
                "includeHistoryModelCatalog": false,
                "modelCatalogFixture": {
                    "kimi-code": {
                        "defaultModel": "kimi-code/k3",
                        "models": [
                            "k3",
                            "kimi-code/k3",
                            "k3-256k",
                            "kimi-code/k3-256k",
                            "kimi-for-coding",
                            "kimi-code/kimi-for-coding"
                        ]
                    }
                }
            }),
        );

        let names = catalog["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|model| model["name"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(names, vec!["k3", "k3-256k", "kimi-for-coding"]);
        assert_eq!(catalog["defaultModel"], json!("k3"));
    }
}

mod config_collections {
    use super::*;

    #[test]
    fn model_collection_cache_reads_root_model_array() {
        let dir = temp_test_dir("model-catalog-cache");
        let cache_path = dir.join("models.json");
        fs::write(
            &cache_path,
            json!([
                {
                    "id": "gpt-5.5",
                    "name": "GPT-5.5",
                    "vendor": "OpenAI"
                },
                {
                    "id": "claude-sonnet-4.6",
                    "name": "Claude Sonnet 4.6",
                    "vendor": "Anthropic"
                }
            ])
            .to_string(),
        )
        .unwrap();

        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        let mut diagnostics = Vec::<Value>::new();
        collect_model_catalog_from_model_collection_path(
            &cache_path,
            "model-cache",
            &mut entries,
            &mut diagnostics,
        );

        assert!(diagnostics.is_empty());
        assert!(entries.values().any(|entry| {
            entry.name == "GPT-5.5" && entry.provider.as_deref() == Some("OpenAI")
        }));
        assert!(entries.values().any(|entry| {
            entry.name == "Claude Sonnet 4.6" && entry.provider.as_deref() == Some("Anthropic")
        }));
    }
}

mod kilo {
    use super::*;

    #[test]
    fn kilo_model_catalog_reads_vscode_state_and_local_db() {
        let home = temp_test_dir("kilo-model-catalog");
        let vscode_root = match std::env::consts::OS {
            "windows" => default_app_data_dir(&home).join("Code"),
            "macos" => home
                .join("Library")
                .join("Application Support")
                .join("Code"),
            _ => home.join(".config").join("Code"),
        };
        let vscode_state = vscode_root
            .join("User")
            .join("globalStorage")
            .join("state.vscdb");
        fs::create_dir_all(vscode_state.parent().unwrap()).unwrap();
        let connection = Connection::open(&vscode_state).unwrap();
        connection
            .execute(
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                (
                    "kilocode.kilo-code",
                    json!({
                        "recentModels": [
                            {
                                "providerID": "kilo",
                                "modelID": "anthropic/claude-opus-4.6",
                                "variant": "max"
                            }
                        ],
                        "favoriteModels": [
                            {
                                "providerID": "kilo",
                                "modelID": "~anthropic/claude-opus-latest"
                            }
                        ],
                        "variantSelections": {
                            "agent/code/kilo/anthropic/claude-opus-4.6": "low"
                        }
                    })
                    .to_string(),
                ),
            )
            .unwrap();
        drop(connection);

        let kilo_db = home
            .join(".local")
            .join("share")
            .join("kilo")
            .join("kilo.db");
        fs::create_dir_all(kilo_db.parent().unwrap()).unwrap();
        let connection = Connection::open(&kilo_db).unwrap();
        connection
            .execute(
                "CREATE TABLE session_message (type TEXT, time_created INTEGER, data TEXT)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO session_message (type, time_created, data) VALUES (?1, ?2, ?3)",
                (
                    "model-switched",
                    1_i64,
                    json!({
                        "model": {
                            "providerID": "kilo",
                            "id": "deepseek/deepseek-v4",
                            "variant": "default"
                        }
                    })
                    .to_string(),
                ),
            )
            .unwrap();
        drop(connection);

        let catalog = model_catalog_for_target(
            "kilo-code",
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
            }),
        );
        let models = catalog["models"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["name"] == "anthropic/claude-opus-4.6"
                && model["providerId"] == "kilo"
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("max"))
                && model["reasoningEfforts"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("low"))
        }));
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "~anthropic/claude-opus-latest"
                    && model["providerId"] == "kilo")
        );
        assert!(
            models
                .iter()
                .any(|model| model["name"] == "deepseek/deepseek-v4"
                    && model["providerId"] == "kilo")
        );
    }
}

mod history {
    use super::super::history::history_model_catalog_params;
    use super::*;

    #[test]
    fn history_projection_forwards_only_bounded_discovery_parameters() {
        let ignored_secret = ["must", "not", "forward"].join("-");
        let projected = history_model_catalog_params(
            "codex",
            &json!({
                "homeDir": "/bounded-home",
                "historyRoot": "/bounded-history",
                "historyModelCatalogLimit": 12,
                "historyModelCatalogFileLimit": 7,
                "secret": ignored_secret
            }),
        );

        assert_eq!(projected["agent"], "codex");
        assert_eq!(projected["limit"], 12);
        assert_eq!(projected["historyModelCatalogFileLimit"], 7);
        assert_eq!(projected["historyRoot"], "/bounded-history");
        assert!(projected.get("secret").is_none());
    }
}

mod normalization {
    use super::*;

    #[test]
    fn default_model_projection_reads_explicit_nested_native_state_only() {
        let document = json!({
            "env": {
                "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]"
            },
            "profiles": {
                "review": {
                    "selectedModel": "profile-only-model"
                }
            }
        });

        assert_eq!(
            default_model_name_from_config_document(&document).as_deref(),
            Some("deepseek-v4-pro[1m]")
        );
        assert_eq!(
            default_model_name_from_config_document(&json!({
                "profiles": {
                    "review": {
                        "selectedModel": "profile-only-model"
                    }
                }
            })),
            None
        );
    }

    #[test]
    fn default_model_projection_reads_flagged_catalog_entry() {
        let document = json!({
            "themes": [
                {"name": "dark", "default": true}
            ],
            "models": [
                {"name": "model-a"},
                {"name": "model-b", "isDefault": true}
            ]
        });

        assert_eq!(
            default_model_name_from_config_document(&document).as_deref(),
            Some("model-b")
        );
    }

    #[test]
    fn model_normalization_rejects_unsafe_names_and_canonicalizes_known_families() {
        assert_eq!(canonical_model_display_name("gpt-5.5-mini"), "GPT-5.5-Mini");
        assert_eq!(
            canonical_model_display_name("deepseek-v4-pro"),
            "DeepSeek V4 Pro"
        );
        assert!(sanitize_model_name("https://example.invalid/model").is_none());
        assert!(sanitize_model_name("$MODEL_FROM_ENV").is_none());
        assert!(sanitize_model_name("model-with-api_key").is_none());
    }
}

mod provider {
    use super::*;

    #[test]
    fn provider_projection_uses_canonical_labels_without_inventing_identity() {
        assert_eq!(
            provider_label_from_provider_id("openai").as_deref(),
            Some("OpenAI")
        );
        assert_eq!(
            provider_label_from_provider_id("custom-provider").as_deref(),
            Some("Custom Provider")
        );
        assert!(provider_label_from_provider_id("  ").is_none());
    }
}

mod reasoning {
    use super::*;

    #[test]
    fn reasoning_projection_collects_nested_unique_bounded_options() {
        let efforts = reasoning_efforts_from_value(&json!({
            "reasoning": {
                "supportedReasoningEfforts": ["low", "high", "high"]
            },
                "thinking": {"thinkingLevel": "medium"}
        }));

        assert_eq!(
            efforts.into_iter().collect::<Vec<_>>(),
            vec!["high", "low", "medium"]
        );
    }
}

mod merge {
    use super::*;

    #[test]
    fn model_merge_deduplicates_sources_and_preserves_explicit_provider() {
        let mut entries = BTreeMap::<String, ModelCatalogEntry>::new();
        add_model_catalog_entry_with_provider(
            &mut entries,
            "gpt-5.5",
            Some("GPT-5.5"),
            Some("openai"),
            Some("OpenAI"),
            "config",
            ["high".to_string()].into_iter().collect(),
        );
        add_model_catalog_entry_with_provider(
            &mut entries,
            "gpt-5.5",
            None,
            Some("openai"),
            None,
            "history",
            ["low".to_string()].into_iter().collect(),
        );

        let catalog = build_model_catalog(
            entries,
            ["config".to_string(), "history".to_string()]
                .into_iter()
                .collect(),
            Vec::new(),
            None,
        );
        assert_eq!(catalog["models"].as_array().unwrap().len(), 1);
        assert_eq!(catalog["models"][0]["provider"], "OpenAI");
        assert_eq!(
            catalog["models"][0]["sources"],
            json!(["config", "history"])
        );
        assert_eq!(
            catalog["models"][0]["reasoningEfforts"],
            json!(["high", "low"])
        );
    }
}

mod builtin {
    use super::*;

    fn catalog_with_fixture(target: &str, fixture: Value) -> Value {
        let home = temp_test_dir("builtin-overlay-home");
        model_catalog_for_target(
            target,
            None,
            &json!({
                "homeDir": display_path(home),
                "includeHistoryModelCatalog": false,
                "modelCatalogFixture": { target: fixture }
            }),
        )
    }

    fn model<'a>(catalog: &'a Value, name: &str) -> Option<&'a Value> {
        catalog["models"]
            .as_array()
            .unwrap()
            .iter()
            .find(|model| model["name"] == name)
    }

    #[test]
    fn builtin_catalog_json_is_well_formed() {
        let parsed: Value = serde_json::from_str(include_str!("builtin_catalog.json")).unwrap();
        let agents = parsed["agents"].as_object().unwrap();
        assert!(agents.contains_key("codex"));
        for (agent, rows) in agents {
            let mut names = BTreeSet::new();
            for row in rows["models"].as_array().unwrap() {
                let name = row["name"].as_str().unwrap();
                assert!(!name.trim().is_empty(), "empty model name in {agent}");
                assert!(
                    names.insert(name.to_ascii_lowercase()),
                    "duplicate {name} in {agent}"
                );
                assert!(
                    row["reasoningEfforts"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .all(|effort| effort
                            .as_str()
                            .is_some_and(|value| !value.trim().is_empty())),
                    "blank effort in {agent}/{name}"
                );
            }
        }
    }

    #[test]
    fn builtin_overlay_replaces_efforts_in_table_order_and_marks_sources() {
        let catalog = catalog_with_fixture(
            "codex",
            json!({
                "models": [
                    { "name": "gpt-5.6-sol", "reasoningEfforts": ["max"] },
                    { "name": "deepseek-v4-pro", "reasoningEfforts": ["high"] }
                ]
            }),
        );

        assert_eq!(
            model(&catalog, "gpt-5.6-sol").unwrap()["reasoningEfforts"],
            json!(["low", "medium", "high", "xhigh", "max", "ultra"])
        );
        assert!(
            model(&catalog, "gpt-5.6-sol").unwrap()["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("builtin"))
        );
        assert_eq!(
            model(&catalog, "deepseek-v4-pro").unwrap()["reasoningEfforts"],
            json!(["high"])
        );
        assert!(
            catalog["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("builtin"))
        );
    }

    #[test]
    fn builtin_overlay_never_injects_unscanned_models() {
        let catalog = catalog_with_fixture(
            "codex",
            json!({ "models": [{ "name": "gpt-5.2", "reasoningEfforts": ["high"] }] }),
        );

        assert!(model(&catalog, "gpt-5.6-terra").is_none());
        assert!(model(&catalog, "gpt-5.6-luna").is_none());
    }

    #[test]
    fn builtin_overlay_matches_aliases_and_clears_unsupported_efforts() {
        let catalog = catalog_with_fixture(
            "claude-code",
            json!({
                "models": [
                    { "name": "claude-haiku-4-5-20251001", "reasoningEfforts": ["high"] }
                ]
            }),
        );

        assert_eq!(
            model(&catalog, "claude-haiku-4-5-20251001").unwrap()["reasoningEfforts"],
            json!([])
        );
        assert!(
            catalog["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("builtin"))
        );
    }

    #[test]
    fn antigravity_never_exposes_a_separate_reasoning_effort() {
        let catalog = catalog_with_fixture(
            "antigravity",
            json!({
                "models": [
                    { "name": "gemini-3.5-flash", "reasoningEfforts": ["low", "high"] },
                    { "name": "Claude Opus 4.6 (Thinking)", "reasoningEfforts": ["high"] }
                ]
            }),
        );

        assert!(
            catalog["models"]
                .as_array()
                .unwrap()
                .iter()
                .all(|model| model["reasoningEfforts"].as_array().unwrap().is_empty())
        );
    }

    #[test]
    fn builtin_overlay_matches_provider_prefixed_names() {
        let catalog = catalog_with_fixture(
            "openclaw",
            json!({
                "models": [
                    { "name": "moonshot/kimi-k3", "reasoningEfforts": ["low", "high"] }
                ]
            }),
        );

        assert_eq!(
            model(&catalog, "moonshot/kimi-k3").unwrap()["reasoningEfforts"],
            json!(["max"])
        );
    }

    #[test]
    fn builtin_overlay_leaves_unlisted_agents_untouched() {
        let catalog = catalog_with_fixture(
            "hermes",
            json!({
                "models": [{ "name": "z-ai/glm-5.2", "reasoningEfforts": ["medium"] }]
            }),
        );

        assert_eq!(
            model(&catalog, "z-ai/glm-5.2").unwrap()["reasoningEfforts"],
            json!(["medium"])
        );
        assert!(
            !catalog["sources"]
                .as_array()
                .unwrap()
                .contains(&json!("builtin"))
        );
    }
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn temp_test_dir(name: &str) -> PathBuf {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let dir = std::env::temp_dir().join(format!(
        "lico-target-model-catalog-{name}-{}-{}",
        now.as_secs(),
        now.subsec_nanos(),
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}
