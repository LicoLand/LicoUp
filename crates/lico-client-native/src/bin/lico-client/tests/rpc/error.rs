use super::*;

#[test]
fn stdio_rpc_classifies_authorization_without_exposing_error_details() {
    let required = anyhow::anyhow!(
        "secure_mesh_authorization_required: private path and opaque detail must stay hidden"
    );
    let failed = anyhow::anyhow!(
        "system authentication failed closed: private path and opaque detail must stay hidden"
    );
    let unrelated = anyhow::anyhow!("private path and opaque detail must stay hidden");

    assert_eq!(
        stdio_rpc_command_error_code(&required),
        "authorization_required"
    );
    assert_eq!(
        stdio_rpc_command_error_code(&failed),
        "authorization_failed"
    );
    assert_eq!(stdio_rpc_command_error_code(&unrelated), "command_failed");
    assert_eq!(
        stdio_rpc_error_message("authorization_required"),
        "user authorization is required"
    );
    assert!(!stdio_rpc_error_message("command_failed").contains("private"));
}
