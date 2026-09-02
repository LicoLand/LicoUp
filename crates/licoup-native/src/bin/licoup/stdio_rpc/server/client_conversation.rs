use super::super::*;
use licoup_native::domain::client_conversation::ConversationService;

pub(super) fn requires_worker(params: &Value) -> bool {
    params.get("action").and_then(Value::as_str) == Some("conversation.message.post")
        && params
            .get("mentionedMembershipIds")
            .and_then(Value::as_array)
            .is_some_and(|memberships| {
                memberships
                    .iter()
                    .any(|membership| membership.as_str().is_some_and(|id| !id.trim().is_empty()))
            })
}

pub(super) fn spawn_execute<W>(
    writer: Arc<Mutex<W>>,
    request_id: String,
    workflow_id: String,
    params: Value,
    service: ConversationService,
    portable_data_dir: Option<PathBuf>,
) -> std::thread::JoinHandle<()>
where
    W: Write + Send + 'static,
{
    std::thread::spawn(move || {
        let _ = execute(
            &writer,
            &request_id,
            &workflow_id,
            params,
            service,
            portable_data_dir,
        );
    })
}

pub(super) fn execute<W: Write>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    params: Value,
    service: ConversationService,
    portable_data_dir: Option<PathBuf>,
) -> Result<()> {
    let execution = catch_unwind(AssertUnwindSafe(|| {
        let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
        service.execute(params)
    }));
    match execution {
        Ok(Ok(result)) => write_stdio_rpc_success_shared(
            writer,
            request_id,
            workflow_id,
            json!({"ok": true, "result": result}),
        )?,
        Ok(Err(error)) => write_stdio_rpc_client_error_shared(
            writer,
            Some(request_id),
            Some(workflow_id),
            &stdio_rpc_command_error(&error),
        )?,
        Err(_) => write_stdio_rpc_error_shared(
            writer,
            Some(request_id),
            Some(workflow_id),
            "command_panicked",
        )?,
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_structured_mentioned_messages_require_a_worker() {
        assert!(requires_worker(&json!({
            "action": "conversation.message.post",
            "mentionedMembershipIds": ["membership:agent"]
        })));
        assert!(!requires_worker(&json!({
            "action": "conversation.message.post",
            "mentionedMembershipIds": []
        })));
        assert!(!requires_worker(&json!({
            "action": "conversation.list",
            "mentionedMembershipIds": ["membership:agent"]
        })));
    }
}
