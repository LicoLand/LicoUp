use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use crate::domain::client_conversation::ConversationService;
use crate::platform::paths::portable_data_dir;

const MAX_CONVERSATION_SERVICE_ROOTS: usize = 4;
static CONVERSATION_SERVICES: OnceLock<Mutex<VecDeque<(PathBuf, ConversationService)>>> =
    OnceLock::new();

pub(super) fn handle_conversation_execute(mut command: AdmittedCommand) -> Result<CliExecution> {
    let input = match command.take_option_json("stdin-json") {
        Some(Value::Object(input)) => Value::Object(input),
        Some(_) => return Err(anyhow!("conversation_request_invalid")),
        None => return Err(anyhow!("conversation_request_required")),
    };
    let root = portable_data_dir()?;
    let service = conversation_service(&root)?;
    Ok(CliExecution::Json(serde_json::json!({
        "ok": true,
        "result": service.execute(input)?,
    })))
}

fn conversation_service(root: &Path) -> Result<ConversationService> {
    let services = CONVERSATION_SERVICES.get_or_init(|| Mutex::new(VecDeque::new()));
    let mut services = services
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(position) = services.iter().position(|(candidate, _)| candidate == root) {
        let entry = services
            .remove(position)
            .expect("conversation service position exists");
        let service = entry.1.clone();
        services.push_back(entry);
        return Ok(service);
    }
    let service = ConversationService::open(root)?;
    if services.len() == MAX_CONVERSATION_SERVICE_ROOTS {
        services.pop_front();
    }
    services.push_back((root.to_owned(), service.clone()));
    Ok(service)
}
