use super::support::*;

#[test]
fn client_update_selects_the_highest_valid_semver_for_channel_and_target() {
    let fixture = UpdateFixture::new();
    let manifest = fixture.sign_manifest(fixture.unsigned_manifest(json!([
        release("999.0.2", fixture.artifact(TARGET_ID)),
        release("999.0.1", fixture.artifact(TARGET_ID)),
        release("1000.0.0-alpha.1", fixture.artifact("other-target")),
    ])));
    let result = check(&fixture.params(manifest)).unwrap();
    assert_eq!(result["availableVersion"], "999.0.2");
    assert_eq!(result["artifact"]["targetId"], TARGET_ID);
}

#[test]
fn client_update_rejects_malformed_release_instead_of_reporting_up_to_date() {
    let fixture = UpdateFixture::new();
    let manifest = fixture.sign_manifest(fixture.unsigned_manifest(json!([release(
        "not-a-version",
        fixture.artifact(TARGET_ID)
    ),])));
    assert!(
        check(&fixture.params(manifest))
            .unwrap_err()
            .to_string()
            .contains("semantic versioning")
    );
}

#[test]
fn client_update_rejects_manifest_channel_mismatch() {
    let fixture = UpdateFixture::new();
    let mut manifest =
        fixture.unsigned_manifest(json!([release("999.0.0", fixture.artifact(TARGET_ID),)]));
    manifest["channel"] = json!("nightly");
    let manifest = fixture.sign_manifest(manifest);
    assert!(
        check(&fixture.params(manifest))
            .unwrap_err()
            .to_string()
            .contains("channel does not match")
    );
}
