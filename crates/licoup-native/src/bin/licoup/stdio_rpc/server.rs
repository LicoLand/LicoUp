use super::*;
use licoup_native::domain::client_conversation::ConversationService;
use std::collections::VecDeque;

const MAX_CONVERSATION_SERVICE_ROOTS: usize = 4;

#[derive(Default)]
struct ConversationServices {
    entries: VecDeque<(Option<PathBuf>, ConversationService)>,
}

#[path = "server/client_conversation.rs"]
mod client_conversation;
#[path = "server/conversation.rs"]
mod conversation;
pub(crate) use conversation::PersistentConversationRuntime;
#[path = "server/state.rs"]
mod state;

pub(crate) fn serve_stdio_rpc<R, W, F>(reader: R, writer: W, execute: F) -> Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
    F: FnMut(Vec<String>, Option<PathBuf>) -> Result<licoup_native::ffi::commands::CliExecution>,
{
    serve_stdio_rpc_inner(reader, writer, execute, None)
}

pub(crate) fn serve_stdio_rpc_with_runtime<R, W, F>(
    reader: R,
    writer: W,
    execute: F,
    conversation_runtime: PersistentConversationRuntime,
) -> Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
    F: FnMut(Vec<String>, Option<PathBuf>) -> Result<licoup_native::ffi::commands::CliExecution>,
{
    serve_stdio_rpc_inner(reader, writer, execute, Some(conversation_runtime))
}

fn serve_stdio_rpc_inner<R, W, F>(
    mut reader: R,
    writer: W,
    mut execute: F,
    conversation_runtime: Option<PersistentConversationRuntime>,
) -> Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
    F: FnMut(Vec<String>, Option<PathBuf>) -> Result<licoup_native::ffi::commands::CliExecution>,
{
    let writer = Arc::new(Mutex::new(writer));
    let mut bound_workflow_id: Option<String> = None;
    let mut conversation_workers = Vec::new();
    let mut conversation_services = ConversationServices::default();
    loop {
        conversation::reap_finished(&mut conversation_workers);
        let line = read_stdio_rpc_line(&mut reader, STDIO_RPC_MAX_REQUEST_BYTES)?;
        let bytes = match line {
            StdioRpcLine::Eof => {
                // The observer disappeared; the dispatched work did not. Keep
                // this native host alive until every Agent reaches a terminal
                // state. Only the explicit conversation cancel operation may
                // interrupt a running turn.
                conversation::join_until_completion(&mut conversation_workers);
                return recover_stdio_rpc_writer(writer);
            }
            StdioRpcLine::TooLarge => {
                write_stdio_rpc_error_shared(
                    &writer,
                    None,
                    bound_workflow_id.as_deref(),
                    "request_too_large",
                )?;
                continue;
            }
            StdioRpcLine::Request(bytes) => bytes,
        };
        let request = match parse_stdio_rpc_request(&bytes) {
            Ok(request) => request,
            Err(error) => {
                write_stdio_rpc_error_shared(
                    &writer,
                    error.id.as_deref(),
                    error.workflow_id.as_deref(),
                    error.code,
                )?;
                continue;
            }
        };
        if bound_workflow_id
            .as_deref()
            .is_some_and(|workflow_id| workflow_id != request.workflow_id.as_str())
        {
            write_stdio_rpc_error_shared(
                &writer,
                Some(&request.id),
                Some(&request.workflow_id),
                "workflow_mismatch",
            )?;
            continue;
        }
        if bound_workflow_id.is_none() {
            bound_workflow_id = Some(request.workflow_id.clone());
        }

        // One host-facing boundary: the whole per-request dispatch is
        // unwind-safe. A panic in any arm (including arms without their own
        // catch-unwind guard) becomes a structured error delta and the frame
        // loop keeps serving; only a response-write failure or the explicit
        // shutdown acknowledgment may end the loop.
        let dispatch = catch_unwind(AssertUnwindSafe(|| -> Result<bool> {
            match request.method {
                StdioRpcMethod::StateGet {
                    request: state_request,
                    portable_data_dir,
                } => {
                    state::get(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        state_request,
                        portable_data_dir,
                    )?;
                }
                StdioRpcMethod::StateSet {
                    request: state_request,
                    portable_data_dir,
                } => {
                    state::set(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        state_request,
                        portable_data_dir,
                    )?;
                }
                StdioRpcMethod::Shutdown => {
                    write_stdio_rpc_success_shared(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        json!({"status": "shutdown"}),
                    )?;
                    // Shutdown closes the RPC session, not the Agent turns it has
                    // already accepted. Acknowledge first so the client can leave.
                    conversation::join_until_completion(&mut conversation_workers);
                    return Ok(true);
                }
                StdioRpcMethod::Conversation {
                    operation,
                    params,
                    portable_data_dir,
                } => {
                    let persistent_operation = matches!(
                        operation.as_str(),
                        "send" | "dispatch" | "stream" | "steer" | "cancel" | "active" | "attach"
                    );
                    if persistent_operation && conversation_runtime.is_none() {
                        let rejection = persistent_runtime_rejection();
                        if matches!(operation.as_str(), "send" | "stream" | "attach") {
                            write_stdio_rpc_terminal_success(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                1,
                                rejection,
                            )?;
                        } else {
                            write_stdio_rpc_success_shared(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                rejection,
                            )?;
                        }
                        return Ok(false);
                    }
                    if operation == "dispatch" {
                        let runtime = conversation_runtime
                            .as_ref()
                            .expect("persistent operation validated");
                        match runtime.start_background(&params, portable_data_dir) {
                            Ok(value) => write_stdio_rpc_success_shared(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                value,
                            )?,
                            Err(error) => write_stdio_rpc_client_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                &error.client_error(),
                            )?,
                        }
                    } else if operation == "send" {
                        let runtime = conversation_runtime
                            .as_ref()
                            .expect("persistent operation validated");
                        if !conversation::has_capacity(&conversation_workers) {
                            write_stdio_rpc_terminal_error(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                1,
                                &stdio_rpc_client_error("conversation_capacity_exhausted"),
                            )?;
                            return Ok(false);
                        }
                        match conversation::spawn_send(
                            Arc::clone(&writer),
                            request.id.clone(),
                            request.workflow_id.clone(),
                            params,
                            portable_data_dir,
                            runtime.clone(),
                        ) {
                            Ok(worker) => conversation_workers.push(worker),
                            Err(error) => write_stdio_rpc_terminal_error(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                1,
                                &error,
                            )?,
                        }
                    } else if operation == "attach" {
                        let runtime = conversation_runtime
                            .as_ref()
                            .expect("persistent operation validated");
                        match conversation::spawn_attach(
                            Arc::clone(&writer),
                            request.id.clone(),
                            request.workflow_id.clone(),
                            params,
                            runtime.clone(),
                        ) {
                            Ok(worker) => conversation_workers.push(worker),
                            Err(error) => write_stdio_rpc_terminal_error(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                1,
                                &error,
                            )?,
                        }
                    } else if operation == "active" {
                        let runtime = conversation_runtime
                            .as_ref()
                            .expect("persistent operation validated");
                        write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            runtime.active(&params),
                        )?;
                    } else {
                        let params = if matches!(operation.as_str(), "steer" | "cancel") {
                            let runtime = conversation_runtime
                                .as_ref()
                                .expect("persistent operation validated");
                            match runtime.scoped_control_params(&params) {
                                Ok(params) => params,
                                Err(error) => {
                                    write_stdio_rpc_terminal_error(
                                        &writer,
                                        &request.id,
                                        &request.workflow_id,
                                        1,
                                        &error,
                                    )?;
                                    return Ok(false);
                                }
                            }
                        } else {
                            params
                        };
                        conversation::execute(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            &operation,
                            params,
                            portable_data_dir,
                            false,
                            None,
                        )?;
                    }
                }
                StdioRpcMethod::ClientConversation {
                    params,
                    portable_data_dir,
                } => {
                    if client_conversation::requires_worker(&params)
                        && conversation_runtime.is_none()
                    {
                        write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            persistent_runtime_rejection(),
                        )?;
                        return Ok(false);
                    }
                    let service = match conversation_service(
                        &mut conversation_services,
                        portable_data_dir.clone(),
                        conversation_runtime.as_ref(),
                    ) {
                        Ok(service) => service,
                        Err(error) => {
                            write_stdio_rpc_client_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                &stdio_rpc_command_error(&error),
                            )?;
                            return Ok(false);
                        }
                    };
                    if client_conversation::requires_worker(&params) {
                        if !conversation::has_capacity(&conversation_workers) {
                            write_stdio_rpc_client_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                &stdio_rpc_client_error("conversation_capacity_exhausted"),
                            )?;
                            return Ok(false);
                        }
                        match client_conversation::spawn_execute(
                            Arc::clone(&writer),
                            request.id.clone(),
                            request.workflow_id.clone(),
                            params,
                            service,
                            portable_data_dir,
                        ) {
                            Ok(worker) => conversation_workers.push(worker),
                            Err(_) => write_stdio_rpc_success_shared(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                json!({
                                    "ok": false,
                                    "error": {
                                        "code": "conversation_dispatch_failed",
                                        "stage": "conversation/dispatch",
                                    }
                                }),
                            )?,
                        }
                    } else {
                        client_conversation::execute(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            params,
                            service,
                            portable_data_dir,
                        )?;
                    }
                }
                StdioRpcMethod::StrategyExecute {
                    params,
                    portable_data_dir,
                } => {
                    if strategy_requires_persistent_runtime(&params)
                        && conversation_runtime.is_none()
                    {
                        write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            persistent_runtime_rejection(),
                        )?;
                        return Ok(false);
                    }
                    let runtime = conversation_runtime.clone();
                    let execution = catch_unwind(AssertUnwindSafe(|| {
                        let _guard = PortableDataDirOverrideGuard::set(portable_data_dir.clone());
                        let root = licoup_native::platform::paths::portable_data_dir()?;
                        let service =
                            licoup_native::domain::adaptive_flywheel::StrategyService::open(&root)?;
                        let service = if let Some(runtime) = runtime {
                            service.with_actor_turn_port(conversation::strategy_turn_port(
                                runtime,
                                portable_data_dir.clone(),
                            ))
                        } else {
                            service
                        };
                        service.execute(params)
                    }));
                    match execution {
                        Ok(Ok(value)) => write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            value,
                        )?,
                        Ok(Err(error)) => write_stdio_rpc_client_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            &stdio_rpc_command_error(&error),
                        )?,
                        Err(_) => write_stdio_rpc_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            "command_panicked",
                        )?,
                    }
                }
                StdioRpcMethod::Catalog {
                    operation,
                    params,
                    portable_data_dir,
                } => {
                    let execution = catch_unwind(AssertUnwindSafe(|| {
                        let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
                        licoup_native::domain::catalog_convergence::dispatch(
                            &["catalog".to_string(), operation],
                            &params,
                        )
                    }));
                    match execution {
                        Ok(Ok(value)) => write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            value,
                        )?,
                        Ok(Err(error)) => write_stdio_rpc_client_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            &stdio_rpc_command_error(&error),
                        )?,
                        Err(_) => write_stdio_rpc_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            "command_panicked",
                        )?,
                    }
                }
                StdioRpcMethod::Execute {
                    args,
                    portable_data_dir,
                } => {
                    if rpc_args_dispatch_conversation(&args) {
                        match licoup_native::ffi::commands::admit_cli_command(args) {
                            Ok(_) => write_stdio_rpc_success_shared(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                persistent_runtime_rejection(),
                            )?,
                            Err(error) => write_stdio_rpc_client_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                &stdio_rpc_command_error(&error),
                            )?,
                        }
                        return Ok(false);
                    }
                    if rpc_command_reads_external_stdin(&args) {
                        write_stdio_rpc_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            "private_input_transport_required",
                        )?;
                        return Ok(false);
                    }
                    if rpc_command_writes_external_stdout(&args) {
                        write_stdio_rpc_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            "streaming_command_unsupported",
                        )?;
                        return Ok(false);
                    }
                    let execution =
                        catch_unwind(AssertUnwindSafe(|| execute(args, portable_data_dir)));
                    match execution {
                        Ok(Ok(licoup_native::ffi::commands::CliExecution::Json(value))) => {
                            write_stdio_rpc_success_shared(
                                &writer,
                                &request.id,
                                &request.workflow_id,
                                value,
                            )?;
                        }
                        Ok(Ok(licoup_native::ffi::commands::CliExecution::Usage)) => {
                            write_stdio_rpc_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                "command_usage",
                            )?;
                        }
                        Ok(Ok(licoup_native::ffi::commands::CliExecution::Streamed)) => {
                            write_stdio_rpc_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                "streaming_command_unsupported",
                            )?;
                        }
                        Ok(Err(error)) => {
                            write_stdio_rpc_client_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                &stdio_rpc_command_error(&error),
                            )?;
                        }
                        Err(_) => {
                            write_stdio_rpc_error_shared(
                                &writer,
                                Some(&request.id),
                                Some(&request.workflow_id),
                                "command_panicked",
                            )?;
                        }
                    }
                }
            }
            Ok(false)
        }));
        match dispatch {
            Ok(Ok(true)) => return recover_stdio_rpc_writer(writer),
            Ok(Ok(false)) => {}
            Ok(Err(error)) => return Err(error),
            Err(_) => {
                write_stdio_rpc_error_shared(
                    &writer,
                    Some(&request.id),
                    Some(&request.workflow_id),
                    "command_panicked",
                )?;
                continue;
            }
        }
    }
}

fn persistent_runtime_rejection() -> Value {
    json!({
        "ok": false,
        "error": {
            "code": licoup_native::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED,
            "stage": "conversation/dispatch",
        }
    })
}

fn rpc_args_dispatch_conversation(args: &[String]) -> bool {
    matches!(
        args,
        [domain, conversation, operation, ..]
            if domain == "agent"
                && conversation == "conversation"
                && matches!(operation.as_str(), "send" | "stream" | "steer" | "cancel")
    ) || matches!(
        args,
        [conversation, execute, ..]
            if conversation == "conversation" && execute == "execute"
    ) || matches!(
        args,
        [strategy, execute, ..] if strategy == "strategy" && execute == "execute"
    )
}

pub(crate) fn strategy_requires_persistent_runtime(params: &Value) -> bool {
    params
        .get("action")
        .and_then(Value::as_str)
        .is_some_and(|action| {
            matches!(
                action,
                "strategy.run.start"
                    | "strategy.run.resume"
                    | "strategy.run.retry"
                    | "strategy.assistant.workflow.execute"
            )
        })
}

/// Open (once per portable data dir) the process-owned Conversation service.
/// The returned handle is cloned for every request and spawned worker, so all
/// sessions reuse one bounded SQLite pool instead of opening per-call
/// connections. The override guard resolves the root exactly like the legacy
/// per-request open did.
fn conversation_service(
    services: &mut ConversationServices,
    portable_data_dir: Option<PathBuf>,
    runtime: Option<&PersistentConversationRuntime>,
) -> Result<ConversationService> {
    if let Some(position) = services
        .entries
        .iter()
        .position(|(root, _)| root == &portable_data_dir)
    {
        let entry = services
            .entries
            .remove(position)
            .expect("conversation service position exists");
        let service = entry.1.clone();
        services.entries.push_back(entry);
        return Ok(service);
    }
    let _guard = PortableDataDirOverrideGuard::set(portable_data_dir.clone());
    let root = licoup_native::platform::paths::portable_data_dir()?;
    let mut service = ConversationService::open(&root)?;
    if let Some(runtime) = runtime {
        let send_runtime = runtime.clone();
        let send_dir = portable_data_dir.clone();
        let active_runtime = runtime.clone();
        let steer_runtime = runtime.clone();
        let actor_runtime = runtime.clone();
        let actor_dir = portable_data_dir.clone();
        let strategy_root = root.clone();
        service = service
            .with_native_turn_sender(move |params| {
                send_runtime.start_background(params, send_dir.clone())
            })
            .with_active_turns(move |conversation_id| {
                active_runtime.active(&json!({ "conversationId": conversation_id }))
            })
            .with_steer_turn(move |params| steer_runtime.steer_sync(params))
            .with_strategy_execute(move |request| {
                let port =
                    conversation::strategy_turn_port(actor_runtime.clone(), actor_dir.clone());
                licoup_native::domain::adaptive_flywheel::StrategyService::open(&strategy_root)?
                    .with_actor_turn_port(port)
                    .execute(request)
            });
    }
    if services.entries.len() == MAX_CONVERSATION_SERVICE_ROOTS {
        services.entries.pop_front();
    }
    services
        .entries
        .push_back((portable_data_dir, service.clone()));
    Ok(service)
}
