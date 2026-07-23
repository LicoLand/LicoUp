use super::*;
use lico_client_native::ffi::generated::client_error::ClientError;

// RPC frames preserve ClientError.code, stage, component, retryable, recovery,
// and presentationArgs by serializing the generated value directly.
pub(crate) fn recover_stdio_rpc_writer<W>(writer: Arc<Mutex<W>>) -> Result<W> {
    Arc::try_unwrap(writer)
        .map_err(|_| anyhow::anyhow!("stdio RPC writer is still in use"))?
        .into_inner()
        .map_err(|_| anyhow::anyhow!("stdio RPC writer lock failed"))
}

fn with_stdio_rpc_writer<W, T>(
    writer: &Arc<Mutex<W>>,
    operation: impl FnOnce(&mut W) -> io::Result<T>,
) -> io::Result<T>
where
    W: Write,
{
    let mut writer = writer
        .lock()
        .map_err(|_| io::Error::other("stdio RPC writer lock failed"))?;
    operation(&mut writer)
}

pub(crate) fn write_stdio_rpc_success_shared<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: &str,
    workflow_id: &str,
    result: Value,
) -> io::Result<()> {
    with_stdio_rpc_writer(writer, |writer| {
        write_stdio_rpc_success(writer, id, workflow_id, result)
    })
}

pub(crate) fn write_stdio_rpc_error_shared<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: Option<&str>,
    workflow_id: Option<&str>,
    code: &'static str,
) -> io::Result<()> {
    let error = stdio_rpc_client_error(code);
    with_stdio_rpc_writer(writer, |writer| {
        write_stdio_rpc_error(writer, id, workflow_id, &error)
    })
}

pub(crate) fn write_stdio_rpc_client_error_shared<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: Option<&str>,
    workflow_id: Option<&str>,
    error: &ClientError,
) -> io::Result<()> {
    with_stdio_rpc_writer(writer, |writer| {
        write_stdio_rpc_error(writer, id, workflow_id, error)
    })
}

pub(crate) fn write_stdio_rpc_event<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: &str,
    workflow_id: &str,
    sequence: u64,
    event: Value,
) -> io::Result<()> {
    let session_id = event.get("sessionId").and_then(Value::as_str);
    let turn_id = event.get("turnId").and_then(Value::as_str);
    let event_name = event.get("event").and_then(Value::as_str);
    if session_id.is_none_or(str::is_empty)
        || turn_id.is_none_or(str::is_empty)
        || event_name.is_none_or(str::is_empty)
    {
        return Err(io::Error::other("invalid stdio RPC stream event"));
    }
    let frame = json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "kind": "event",
        "sequence": sequence,
        "event": event,
    });
    with_stdio_rpc_writer(writer, |writer| {
        if try_write_stdio_rpc_response(writer, &frame, STDIO_RPC_MAX_RESPONSE_BYTES)? {
            Ok(())
        } else {
            Err(io::Error::other("stdio RPC event exceeds limit"))
        }
    })
}

pub(crate) fn write_stdio_rpc_terminal_success<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: &str,
    workflow_id: &str,
    sequence: u64,
    result: Value,
) -> io::Result<()> {
    let frame = json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "kind": "terminal",
        "sequence": sequence,
        "ok": true,
        "result": result,
    });
    with_stdio_rpc_writer(writer, |writer| {
        if try_write_stdio_rpc_response(writer, &frame, STDIO_RPC_MAX_RESPONSE_BYTES)? {
            Ok(())
        } else {
            let error = stdio_rpc_client_error("response_too_large");
            let bounded_error = json!({
                "protocol": STDIO_RPC_PROTOCOL,
                "id": id,
                "workflowId": workflow_id,
                "kind": "terminal",
                "sequence": sequence,
                "ok": false,
                "error": error,
            });
            if try_write_stdio_rpc_response(writer, &bounded_error, STDIO_RPC_MAX_RESPONSE_BYTES)? {
                Ok(())
            } else {
                Err(io::Error::other("stdio RPC terminal exceeds limit"))
            }
        }
    })
}

pub(crate) fn write_stdio_rpc_terminal_error<W: Write>(
    writer: &Arc<Mutex<W>>,
    id: &str,
    workflow_id: &str,
    sequence: u64,
    error: &ClientError,
) -> io::Result<()> {
    let frame = json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "kind": "terminal",
        "sequence": sequence,
        "ok": false,
        "error": error,
    });
    with_stdio_rpc_writer(writer, |writer| {
        if try_write_stdio_rpc_response(writer, &frame, STDIO_RPC_MAX_RESPONSE_BYTES)? {
            Ok(())
        } else {
            Err(io::Error::other("stdio RPC terminal exceeds limit"))
        }
    })
}

pub(crate) fn write_stdio_rpc_success(
    writer: &mut impl Write,
    id: &str,
    workflow_id: &str,
    result: Value,
) -> io::Result<()> {
    write_stdio_rpc_success_with_limit(
        writer,
        id,
        workflow_id,
        result,
        STDIO_RPC_MAX_RESPONSE_BYTES,
    )
}

pub(crate) fn write_stdio_rpc_success_with_limit(
    writer: &mut impl Write,
    id: &str,
    workflow_id: &str,
    result: Value,
    max_response_bytes: usize,
) -> io::Result<()> {
    let response = json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "ok": true,
        "result": result,
    });
    if try_write_stdio_rpc_response(writer, &response, max_response_bytes)? {
        return Ok(());
    }
    let error = stdio_rpc_client_error("response_too_large");
    write_stdio_rpc_error(writer, Some(id), Some(workflow_id), &error)
}

pub(crate) fn write_stdio_rpc_error(
    writer: &mut impl Write,
    id: Option<&str>,
    workflow_id: Option<&str>,
    error: &ClientError,
) -> io::Result<()> {
    let response = json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "ok": false,
        "error": error,
    });
    if try_write_stdio_rpc_response(writer, &response, STDIO_RPC_MAX_RESPONSE_BYTES)? {
        Ok(())
    } else {
        Err(io::Error::other("stdio RPC error response exceeds limit"))
    }
}

// Serialize before touching stdout so every response is one bounded, atomic JSON line.
pub(crate) fn try_write_stdio_rpc_response(
    writer: &mut impl Write,
    response: &Value,
    max_response_bytes: usize,
) -> io::Result<bool> {
    let encoded = serde_json::to_vec(response).map_err(io::Error::other)?;
    if encoded.len().saturating_add(1) > max_response_bytes {
        return Ok(false);
    }
    writer.write_all(&encoded)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(true)
}
