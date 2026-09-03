use super::support::*;

#[test]
fn client_update_check_download_verify_and_plan_share_one_digest_bound_receipt() {
    let fixture = UpdateFixture::new();
    let check_params = fixture.params(fixture.manifest());
    let checked = check(&check_params).unwrap();
    let mut params = check_params;
    params.as_object_mut().unwrap().remove("targetReleaseTrack");
    let downloaded = download(&params).unwrap();
    let verified = verify(&params).unwrap();
    let planned = apply(&params).unwrap();
    let receipt_id = checked["artifactReceipt"]["receiptId"].clone();
    assert_eq!(
        checked["artifactReceipt"]["schemaVersion"],
        CLIENT_UPDATE_ARTIFACT_RECEIPT_SCHEMA
    );
    assert_eq!(downloaded["artifactReceipt"]["receiptId"], receipt_id);
    assert_eq!(verified["artifactReceipt"]["receiptId"], receipt_id);
    assert_eq!(planned["artifactReceipt"]["receiptId"], receipt_id);
    assert_eq!(planned["phase"], "applyPlanned");
    assert_eq!(planned["executed"], false);
    for value in [&checked, &downloaded, &verified, &planned] {
        assert_eq!(value["runningVersion"], checked["runningVersion"]);
        assert_eq!(value["runningReleaseTrack"], checked["runningReleaseTrack"]);
        assert_eq!(value["targetReleaseTrack"], checked["targetReleaseTrack"]);
        assert_redacted(value, &fixture.root);
    }
}

#[test]
fn client_update_status_and_dispatch_do_not_project_local_file_names_or_paths() {
    let fixture = UpdateFixture::new();
    fs::create_dir_all(&fixture.staging).unwrap();
    fs::write(fixture.staging.join("private-local-name.bin"), b"private").unwrap();
    let result = status(&json!({"stagingRoot": fixture.staging})).unwrap();
    assert_eq!(result["stagedArtifactCount"], 1);
    assert!(!result.to_string().contains("private-local-name.bin"));
    assert_redacted(&result, &fixture.root);
    assert!(
        dispatch(&["update".into(), "unknown".into()], &json!({}))
            .unwrap_err()
            .to_string()
            .contains("unsupported")
    );
}

#[test]
fn client_update_later_phases_require_the_exact_signed_check_receipt() {
    let fixture = UpdateFixture::new();
    let mut unchecked = fixture.params(fixture.manifest());
    unchecked
        .as_object_mut()
        .unwrap()
        .remove("targetReleaseTrack");
    assert!(
        download(&unchecked)
            .unwrap_err()
            .to_string()
            .contains("check receipt is required")
    );

    let checked = fixture.checked_params(fixture.manifest());
    let replacement = fixture.sign_manifest(
        fixture.unsigned_manifest(json!([release("998.0.0", fixture.artifact(TARGET_ID),)])),
    );
    let mut substituted = checked;
    substituted["manifestJson"] = replacement;
    assert!(
        download(&substituted)
            .unwrap_err()
            .to_string()
            .contains("does not match the signed check receipt")
    );
}
