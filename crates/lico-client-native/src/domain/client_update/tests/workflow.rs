use super::support::*;

#[test]
fn client_update_check_download_verify_and_plan_share_one_digest_bound_receipt() {
    let fixture = UpdateFixture::new();
    let params = fixture.params(fixture.manifest());
    let checked = check(&params).unwrap();
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
