use super::*;

#[test]
fn endpoint_trust_module_public_projection_redacts_secret_material() {
    let mut config = default_config();
    config["pcToken"] = json!("private-pc-token");
    config["mobileToken"] = json!("private-mobile-token");

    let public = public_config(&config);

    assert_eq!(public["pcToken"], "");
    assert_eq!(public["mobileToken"], "");
    assert_eq!(public["pcTokenPresent"], true);
    assert_eq!(public["mobileTokenPresent"], true);
}
