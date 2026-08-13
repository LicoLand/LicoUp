use super::*;

#[path = "server/conversation.rs"]
mod conversation;
#[path = "server/state.rs"]
mod state;

pub(crate) fn serve_stdio_rpc<R, W, F>(mut reader: R, writer: W, mut execute: F) -> Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
    F: FnMut(Vec<String>, Option<PathBuf>) -> Result<licoup_native::ffi::commands::CliExecution>,
{
    let writer = Arc::new(Mutex::new(writer));
    let mut bound_workflow_id: Option<String> = None;
    let mut conversation_workers = Vec::new();
    loop {
        conversation::reap_finished(&mut conversation_workers);
        let line = read_stdio_rpc_line(&mut reader, STDIO_RPC_MAX_REQUEST_BYTES)?;
        let bytes = match line {
            StdioRpcLine::Eof => {
                licoup_native::platform::shutdown_all_conversations()?;
                if !conversation::join_until_shutdown(&mut conversation_workers) {
                    return Err(anyhow::anyhow!("conversation_shutdown_timeout"));
                }
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
                if let Err(error) = licoup_native::platform::shutdown_all_conversations() {
                    write_stdio_rpc_client_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        &stdio_rpc_command_error(&error),
                    )?;
                    return recover_stdio_rpc_writer(writer);
                }
                if !conversation::join_until_shutdown(&mut conversation_workers) {
                    write_stdio_rpc_client_error_shared(
                        &writer,
                        Some(&request.id),
                        Some(&request.workflow_id),
                        &stdio_rpc_client_error("conversation_shutdown_timeout"),
                    )?;
                    return Err(anyhow::anyhow!("conversation_shutdown_timeout"));
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
                if operation == "send" {
                    if !conversation::has_capacity(&conversation_workers) {
                        write_stdio_rpc_terminal_error(
                            &writer,
                            &request.id,
                            &request.workflow_id,
                            1,
                            &stdio_rpc_client_error("conversation_capacity_exhausted"),
                        )?;
                        continue;
                    }
                    conversation_workers.push(conversation::spawn_send(
                        Arc::clone(&writer),
                        request.id,
                        request.workflow_id,
                        params,
                        portable_data_dir,
                    ));
                } else {
                    conversation::execute(
                        &writer,
                        &request.id,
                        &request.workflow_id,
                        &operation,
                        params,
                        portable_data_dir,
                        false,
                    )?;
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
    }
}
