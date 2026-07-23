use super::*;
use lico_client_native::ffi::generated::client_state::{
    ClientStateFailure, ClientStateFailureCode,
};

const ORCHESTRATOR_REQUEST_METHOD: &str = "orchestrator.request";

pub(crate) fn serve_stdio_rpc<R, W, F>(mut reader: R, writer: W, mut execute: F) -> Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
    F: FnMut(
        Vec<String>,
        Option<PathBuf>,
    ) -> Result<lico_client_native::ffi::commands::CliExecution>,
{
    let writer = Arc::new(Mutex::new(writer));
    let mut bound_workflow_id: Option<String> = None;
    loop {
        let line = read_stdio_rpc_line(&mut reader, STDIO_RPC_MAX_REQUEST_BYTES)?;
        let bytes = match line {
            StdioRpcLine::Eof => {
                lico_client_native::platform::shutdown_all_conversations()?;
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

        match request.method {
            StdioRpcMethod::StateGet {
                request: state_request,
                portable_data_dir,
            } => {
                let execution = catch_unwind(AssertUnwindSafe(|| {
                    let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
                    lico_client_native::platform::client_state::state_get(state_request)
                }));
                match execution {
                    Ok(Ok(result)) => write_stdio_rpc_success_shared(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        serde_json::to_value(result)?,
                    )?,
                    Ok(Err(_)) | Err(_) => write_stdio_rpc_client_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        &stdio_rpc_state_failure(ClientStateFailure::new(
                            ClientStateFailureCode::StateOperationFailed,
                        )),
                    )?,
                }
            }
            StdioRpcMethod::StateSet {
                request: state_request,
                portable_data_dir,
            } => {
                let execution = catch_unwind(AssertUnwindSafe(|| {
                    let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
                    lico_client_native::platform::client_state::state_set(state_request)
                }));
                match execution {
                    Ok(Ok(result)) => write_stdio_rpc_success_shared(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        serde_json::to_value(result)?,
                    )?,
                    Ok(Err(_)) | Err(_) => write_stdio_rpc_client_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        &stdio_rpc_state_failure(ClientStateFailure::new(
                            ClientStateFailureCode::StateOperationFailed,
                        )),
                    )?,
                }
            }
            StdioRpcMethod::Orchestrator { params } => {
                debug_assert_eq!(ORCHESTRATOR_REQUEST_METHOD, "orchestrator.request");
                use lico_client_native::platform::{
                    orchestrator_control_plane::build_desktop_orchestrator_request,
                    orchestrator_ipc::OrchestratorIpcClient,
                    orchestrator_service::default_orchestrator_state_root,
                };
                let receipt = match default_orchestrator_state_root() {
                    Ok(root) => match super::orchestrator::desktop_orchestrator_command(
                        &params, &root,
                    )
                    .and_then(build_desktop_orchestrator_request)
                    {
                        Ok(request) => {
                            let timeout = request
                                .params
                                .get("timeoutMs")
                                .and_then(serde_json::Value::as_u64)
                                .map(|millis| {
                                    std::time::Duration::from_millis(
                                        millis.saturating_add(2_000),
                                    )
                                })
                                .unwrap_or(std::time::Duration::from_secs(10));
                            OrchestratorIpcClient::new(root)
                                .with_client_kind("desktop")
                                .with_timeout(timeout)
                                .execute(&request)
                        }
                        Err(_) => lico_client_native::platform::orchestrator_ipc::OrchestratorIpcReceipt::failure(
                            &request.id,
                            "invalid_request",
                        ),
                    },
                    Err(_) => lico_client_native::platform::orchestrator_ipc::OrchestratorIpcReceipt::failure(
                        &request.id,
                        "invalid_request",
                    ),
                };
                write_stdio_rpc_success_shared(
                    &writer,
                    &request.id,
                    &request.workflow_id,
                    serde_json::to_value(receipt)?,
                )?;
            }
            StdioRpcMethod::Shutdown => {
                if let Err(error) = lico_client_native::platform::shutdown_all_conversations() {
                    write_stdio_rpc_client_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        &stdio_rpc_command_error(&error),
                    )?;
                    return recover_stdio_rpc_writer(writer);
                }
                write_stdio_rpc_success_shared(
                    &writer,
                    &request.id,
                    &request.workflow_id,
                    json!({"status": "shutdown"}),
                )?;
                return recover_stdio_rpc_writer(writer);
            }
            StdioRpcMethod::Conversation {
                operation,
                params,
                portable_data_dir,
            } => {
                let sequence = Arc::new(AtomicU64::new(0));
                let event_write_failed = Arc::new(AtomicBool::new(false));
                let stream_guard = (operation == "send").then(|| {
                    let writer = Arc::clone(&writer);
                    let request_id = request.id.clone();
                    let workflow_id = request.workflow_id.clone();
                    let sequence = Arc::clone(&sequence);
                    let event_write_failed = Arc::clone(&event_write_failed);
                    lico_client_native::platform::install_stream_sink(Box::new(move |event| {
                        if event_write_failed.load(Ordering::Acquire) {
                            return;
                        }
                        let next = sequence.load(Ordering::Acquire) + 1;
                        if write_stdio_rpc_event(&writer, &request_id, &workflow_id, next, event)
                            .is_err()
                        {
                            event_write_failed.store(true, Ordering::Release);
                        } else {
                            sequence.store(next, Ordering::Release);
                        }
                    }));
                    lico_client_native::platform::StreamSinkGuard
                });
                let execution = catch_unwind(AssertUnwindSafe(|| {
                    let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
                    lico_client_native::platform::dispatch_lane_operation(&operation, &params)
                        .map(lico_client_native::ffi::commands::CliExecution::Json)
                }));
                drop(stream_guard);
                let terminal_sequence = sequence.fetch_add(1, Ordering::AcqRel) + 1;
                if event_write_failed.load(Ordering::Acquire) {
                    let error = stdio_rpc_client_error("stream_protocol_failed");
                    write_stdio_rpc_terminal_error(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        terminal_sequence,
                        &error,
                    )?;
                    continue;
                }
                match execution {
                    Ok(Ok(lico_client_native::ffi::commands::CliExecution::Json(value))) => {
                        write_stdio_rpc_terminal_success(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            terminal_sequence,
                            value,
                        )?;
                    }
                    Ok(Err(error)) => {
                        let error = error.client_error();
                        write_stdio_rpc_terminal_error(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            terminal_sequence,
                            &error,
                        )?;
                    }
                    Err(_) => {
                        let error = stdio_rpc_client_error("command_panicked");
                        write_stdio_rpc_terminal_error(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            terminal_sequence,
                            &error,
                        )?;
                    }
                    Ok(Ok(_)) => {
                        let error = stdio_rpc_client_error("command_failed");
                        write_stdio_rpc_terminal_error(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            terminal_sequence,
                            &error,
                        )?;
                    }
                }
            }
            StdioRpcMethod::Catalog {
                operation,
                params,
                portable_data_dir,
            } => {
                let execution = catch_unwind(AssertUnwindSafe(|| {
                    let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
                    lico_client_native::domain::catalog_convergence::dispatch(
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
                if rpc_command_reads_external_stdin(&args) {
                    write_stdio_rpc_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        "private_input_transport_required",
                    )?;
                    continue;
                }
                if rpc_command_writes_external_stdout(&args) {
                    write_stdio_rpc_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        "streaming_command_unsupported",
                    )?;
                    continue;
                }
                let execution = catch_unwind(AssertUnwindSafe(|| execute(args, portable_data_dir)));
                match execution {
                    Ok(Ok(lico_client_native::ffi::commands::CliExecution::Json(value))) => {
                        write_stdio_rpc_success_shared(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            value,
                        )?;
                    }
                    Ok(Ok(lico_client_native::ffi::commands::CliExecution::Usage)) => {
                        write_stdio_rpc_error_shared(
                            &writer,
                            Some(&request.id),
                            Some(&request.workflow_id),
                            "command_usage",
                        )?;
                    }
                    Ok(Ok(lico_client_native::ffi::commands::CliExecution::Streamed)) => {
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
    }
}
