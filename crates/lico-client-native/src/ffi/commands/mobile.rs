// mobile commands: mobile relay config|pairing|pc|commands

use super::{CliExecution, CommandTable, cli_params, parse_json_arg};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["mobile", "relay"],
        handle_mobile_relay,
        "Mobile relay config|pairing|pc|commands|kt",
    );
}

fn handle_mobile_relay(args: &[String]) -> Result<CliExecution> {
    let noun = &args[2];
    let action = &args[3];
    let mut params = cli_params(&args[4..]);
    let result = match (noun.as_str(), action.as_str()) {
        ("config", "get") => crate::domain::mobile_relay::config_get(&params)?,
        ("config", "set") => crate::domain::mobile_relay::config_set(&params)?,
        ("pairing", "create") => crate::domain::mobile_relay::pairing_create(&params)?,
        ("pairing", "claim") => crate::domain::mobile_relay::pairing_claim(&params)?,
        ("pairing", "status") => crate::domain::mobile_relay::pairing_status(&params)?,
        ("pairing", "revoke") => crate::domain::mobile_relay::pairing_revoke(&params)?,
        ("pc", "check-in") => crate::domain::mobile_relay::pc_check_in(&params)?,
        ("commands", "poll") => crate::domain::mobile_relay::commands_poll(&params)?,
        ("commands", "sync") => crate::domain::mobile_relay::commands_sync(&params)?,
        ("commands", "complete") => crate::domain::mobile_relay::command_complete(&params)?,
        ("commands", "create") => crate::domain::mobile_relay::command_create(&params)?,
        ("commands", "create-secure") => {
            crate::domain::mobile_relay::command_create_secure(&params)?
        }
        ("commands", "result") => crate::domain::mobile_relay::command_result(&params)?,
        ("commands", "result-secure") => {
            crate::domain::mobile_relay::command_result_secure(&params)?
        }
        ("commands", "result-replay-proof") => {
            crate::domain::mobile_relay::command_result_replay_proof(&params)?
        }
        ("e2ee", "status") => crate::domain::mobile_relay::e2ee_status(&params)?,
        ("e2ee", "secret-store-self-test") => {
            crate::domain::mobile_relay::e2ee_secret_store_self_test(&params)?
        }
        ("e2ee", "secret-store-cleanup") => {
            crate::domain::mobile_relay::e2ee_secret_store_cleanup(&params)?
        }
        ("kt", "configure-authority") => {
            normalize_kt_cli_json_fields(&mut params);
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.configureAuthority",
                &params,
            )?
        }
        ("kt", "publication-request") => {
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.publicationRequest",
                &params,
            )?
        }
        ("kt", "revocation-request") => {
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.revocationRequest",
                &params,
            )?
        }
        ("kt", "provision") => {
            normalize_kt_cli_json_fields(&mut params);
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.provision",
                &params,
            )?
        }
        ("kt", "gossip") => {
            normalize_kt_cli_json_fields(&mut params);
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.gossip",
                &params,
            )?
        }
        ("kt", "self-monitor") => {
            normalize_kt_cli_json_fields(&mut params);
            crate::domain::mobile_relay::dispatch_key_transparency_action(
                "secure_mesh.kt.selfMonitor",
                &params,
            )?
        }
        ("kt", "status") => crate::domain::mobile_relay::dispatch_key_transparency_action(
            "secure_mesh.kt.status",
            &params,
        )?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn normalize_kt_cli_json_fields(params: &mut serde_json::Value) {
    let Some(object) = params.as_object_mut() else {
        return;
    };
    for key in ["pin", "response", "gossip", "secureEnvelope", "envelope"] {
        let Some(value) = object.get(key).cloned() else {
            continue;
        };
        if let Some(text) = value.as_str() {
            object.insert(key.to_string(), parse_json_arg(text));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::mobile_relay::with_mobile_relay_secret_store_override;
    use crate::platform::paths::set_portable_data_dir_override;
    use crate::platform::secure_mesh_secret_store::{EphemeralSecretStore, SecureMeshSecretStore};
    use std::fs;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn disposable_secret_cleanup_is_wired_to_the_exact_guarded_cli_path() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lico-mobile-relay-cleanup-cli-{}-{nonce}",
            std::process::id()
        ));
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let store = Arc::new(EphemeralSecretStore::new());
        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();

        let execution = with_mobile_relay_secret_store_override(store_override, || {
            crate::ffi::commands::execute_cli(vec![
                "mobile".to_string(),
                "relay".to_string(),
                "e2ee".to_string(),
                "secret-store-cleanup".to_string(),
                "--disposable-proof".to_string(),
                "true".to_string(),
            ])
        })
        .unwrap();
        let CliExecution::Json(output) = execution else {
            panic!("guarded disposable cleanup CLI did not return JSON");
        };
        assert_eq!(output["ok"], true);
        assert_eq!(output["disposableProof"], true);
        assert_eq!(
            output["secretStoreAuthorization"]["allowInteraction"],
            false
        );
        assert_eq!(store.authorization_session_count(), 1);

        set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn secure_mesh_kt_status_cli_reuses_the_canonical_domain_dispatch() {
        let root = std::env::temp_dir().join(format!(
            "lico-mobile-relay-kt-status-cli-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let execution = crate::ffi::commands::execute_cli(vec![
            "mobile".to_string(),
            "relay".to_string(),
            "kt".to_string(),
            "status".to_string(),
        ])
        .unwrap();
        let CliExecution::Json(output) = execution else {
            panic!("Secure Mesh KT status CLI did not return JSON");
        };
        assert_eq!(output["ok"], true);
        assert_eq!(output["configured"], false);

        set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(root);
    }
}
