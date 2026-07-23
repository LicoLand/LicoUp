// mobile commands: mobile relay config|pairing|pc|commands

use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::Result;

pub(super) fn handle_mobile_relay(command: AdmittedCommand) -> Result<CliExecution> {
    let route = command.path();
    let params = admitted_params(
        &[
            (
                "useCustomGateway",
                command.option_text("use-custom-gateway"),
            ),
            (
                "customGatewayUrl",
                command.option_text("custom-gateway-url"),
            ),
            ("relayEnabled", command.option_text("relay-enabled")),
            ("pairingCode", command.option_text("pairing-code")),
            ("pairingId", command.option_text("pairing-id")),
            ("mobileToken", command.option_text("mobile-token")),
            ("commandId", command.option_text("command-id")),
            ("type", command.option_text("type")),
            ("disposableProof", command.option_text("disposable-proof")),
        ],
        &[("payload", command.option_json("payload"))],
        &[],
    );
    let (noun, action) = match route {
        ["mobile", "relay", noun, action] => (*noun, *action),
        _ => unreachable!("admission only registers concrete mobile relay routes"),
    };
    let result = match (noun, action) {
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
        ("commands", "result") => crate::domain::mobile_relay::command_result(&params)?,
        ("commands", "result-secure") => {
            crate::domain::mobile_relay::command_result_secure(&params)?
        }
        ("commands", "result-replay-proof") => {
            crate::domain::mobile_relay::command_result_replay_proof(&params)?
        }
        ("e2ee", "secret-store-cleanup") => {
            crate::domain::mobile_relay::e2ee_secret_store_cleanup(&params)?
        }
        _ => unreachable!("admission only registers supported mobile relay actions"),
    };
    Ok(CliExecution::Json(result))
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
}
