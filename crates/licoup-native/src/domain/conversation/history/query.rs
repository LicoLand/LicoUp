//! Read-only conversation queries, model discovery, filters, and pagination.

use super::*;

impl HistoryScanConfig {
    pub(crate) fn from_params(params: &Value) -> Self {
        Self {
            archive_mode: param_bool(params, "archiveMode").unwrap_or(false),
            session_ids: string_list_param(params, &["sessionIds", "sessionId"]),
            match_terms: string_list_param(params, &["matchTerms", "matchTerm"]),
            match_project_paths: string_list_param(
                params,
                &["matchProjectPaths", "matchProjectPath"],
            ),
            page: HistoryPageConfig::from_params(params),
        }
    }

    pub(super) fn matches_session(&self, session: &Value) -> bool {
        if !self.session_ids.is_empty() {
            let projected_id = session
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let native_id = session
                .get("nativeSessionId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !self
                .session_ids
                .iter()
                .any(|session_id| session_id == projected_id || session_id == native_id)
            {
                return false;
            }
        }
        if self.match_terms.is_empty() && self.match_project_paths.is_empty() {
            return true;
        }
        let text = history_match_text(session);
        let normalized = normalize_history_match_text(&text);
        let text_matches = self.match_terms.iter().any(|term| {
            let normalized_term = normalize_history_match_text(term);
            !normalized_term.is_empty()
                && normalized_contains_history_term(&normalized, &normalized_term)
        });
        if text_matches {
            return true;
        }
        if self.match_project_paths.is_empty() {
            return false;
        }
        let path_text = history_match_path_text(session);
        let normalized_path = normalize_history_match_text(&path_text);
        self.match_project_paths.iter().any(|term| {
            let normalized_term = normalize_history_match_text(term);
            path_text.contains(term)
                || (!normalized_term.is_empty()
                    && normalized_contains_history_term(&normalized_path, &normalized_term))
        })
    }

    pub(super) fn has_match_filters(&self) -> bool {
        !self.match_terms.is_empty() || !self.match_project_paths.is_empty()
    }

    pub(crate) fn has_single_session_filter(&self) -> bool {
        self.session_ids.len() == 1
    }

    pub(crate) fn discovery_options(&self) -> HistoryDiscoveryOptions {
        HistoryDiscoveryOptions {
            archive_mode: self.archive_mode,
            exact_session_id: self
                .has_single_session_filter()
                .then(|| self.session_ids[0].clone()),
        }
    }

    pub(super) fn matched_terms(&self, session: &Value) -> Vec<String> {
        let text = history_match_text(session);
        let path_text = history_match_path_text(session);
        self.matched_terms_in_text_and_path(&text, &path_text)
    }

    pub(super) fn matched_terms_in_text_and_path(
        &self,
        text: &str,
        path_text: &str,
    ) -> Vec<String> {
        let normalized = normalize_history_match_text(text);
        let normalized_path = normalize_history_match_text(path_text);
        let mut matched = Vec::<String>::new();
        for term in self
            .match_terms
            .iter()
            .chain(self.match_project_paths.iter())
        {
            let normalized_term = normalize_history_match_text(term);
            if normalized_term.is_empty() {
                continue;
            }
            let text_match = normalized_contains_history_term(&normalized, &normalized_term);
            let path_match = path_text.contains(term)
                || normalized_contains_history_term(&normalized_path, &normalized_term);
            if text_match || path_match {
                matched.push(term.clone());
            }
        }
        matched.sort();
        matched.dedup();
        matched
    }

    pub(super) fn compact_session_for_archive_discovery(&self, mut session: Value) -> Value {
        if !self.has_match_filters() || source_path_is_sqlite(&session) {
            return session;
        }
        let matched_terms = self.matched_terms(&session);
        let has_conversation = history_session_has_real_conversation(&session);
        if let Some(object) = session.as_object_mut() {
            object.insert(
                "archiveDiscoveryHasConversation".to_string(),
                json!(has_conversation),
            );
            object.insert(
                "archiveDiscoveryMatchedTerms".to_string(),
                json!(matched_terms),
            );
            if let Some(messages) = object.get("messages").and_then(Value::as_array) {
                let preview = messages
                    .iter()
                    .filter(|message| history_message_is_matchable(message))
                    .take(12)
                    .cloned()
                    .collect::<Vec<_>>();
                object.insert("messages".to_string(), Value::Array(preview));
                object.insert(
                    "messagesTruncatedForArchiveDiscovery".to_string(),
                    json!(true),
                );
            }
        }
        session
    }
}

impl HistoryPageConfig {
    pub(super) fn from_params(params: &Value) -> Self {
        Self {
            offset: number_param(params, "offset").unwrap_or(0) as usize,
            limit: number_param(params, "limit")
                .map(|value| (value as usize).clamp(1, MAX_HISTORY_PAGE_LIMIT)),
        }
    }

    pub(crate) fn end(&self) -> Option<usize> {
        self.limit.map(|limit| self.offset.saturating_add(limit))
    }

    pub(crate) fn has_more(&self, total: usize) -> bool {
        self.end().map(|end| total > end).unwrap_or(false)
    }
}

pub fn conversation_list(params: &Value) -> Result<Value> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    let roots = history_roots(adapter, params);
    let mut sessions = Vec::<Value>::new();
    let discovery = discover_history_files(adapter, &roots, scan_config.discovery_options());
    let mut skipped = discovery.skipped;
    let files_seen = discovery.files_seen;
    let directory_entries_seen = discovery.directory_entries_seen;
    for candidate in discovery.candidates {
        let metadata = match fs::metadata(&candidate.path) {
            Ok(metadata) => metadata,
            Err(error) => {
                skipped.push(json!({
                    "path": display_path(&candidate.path),
                    "reason": "metadata_failed",
                    "error": error.to_string()
                }));
                continue;
            }
        };
        sessions.extend(parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        ));
    }
    if adapter == HistoryAdapter::Codex && !scan_config.has_single_session_filter() {
        apply_codex_session_index_titles(params, &mut sessions);
    }
    let mut sessions = dedupe_history_sessions(finalize_history_sessions(sessions, &scan_config));
    sort_sessions_by_updated_at(&mut sessions);
    let total_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);
    let sessions = paged_history_sessions(sessions, &scan_config.page);
    let returned_sessions = sessions.len();

    Ok(json!({
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "mode": "native-history",
        "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": agent_id,
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sessions": sessions,
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit,
            "returned": returned_sessions,
            "totalSessions": total_sessions,
            "hasMore": has_more
        },
        "sources": {
            "filesSeen": files_seen,
            "directoryEntriesSeen": directory_entries_seen,
            "skipped": skipped
        }
    }))
}

pub fn model_catalog(params: &Value) -> Result<Value> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    let roots = history_roots(adapter, params);
    let discovery = discover_history_files(adapter, &roots, scan_config.discovery_options());
    let mut candidates = discovery.candidates;
    let skipped = discovery.skipped;
    let files_seen = discovery.files_seen;
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.path.cmp(&right.path))
    });
    let file_limit = number_param(params, "historyModelCatalogFileLimit")
        .unwrap_or(80)
        .clamp(1, 500) as usize;
    let mut names = BTreeSet::<String>::new();
    for candidate in candidates.into_iter().take(file_limit) {
        let Ok(metadata) = fs::metadata(&candidate.path) else {
            continue;
        };
        let sessions = parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        );
        for session in sessions {
            collect_history_model_names(&session, &mut names, 0);
        }
    }
    let models = names
        .into_iter()
        .map(|name| {
            json!({
                "name": name,
                "source": "history",
                "sources": ["history"],
                "reasoningEfforts": []
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "ok": true,
        "status": if models.is_empty() { "empty" } else { "available" },
        "source": "history",
        "models": models,
        "sources": {
            "filesSeen": files_seen,
            "skippedCount": skipped.len()
        }
    }))
}

pub fn conversation_stream(params: &Value) -> Result<()> {
    crate::domain::conversation::streaming::conversation_stream(params)
}

pub fn conversation_append(_params: &Value) -> Result<Value> {
    Err(anyhow!(
        "native agent history is read-only; LicoUp does not create synthetic history entries"
    ))
}

pub fn conversation_delete(_params: &Value) -> Result<Value> {
    Err(anyhow!(
        "native agent history is read-only; LicoUp does not delete source-agent history"
    ))
}
