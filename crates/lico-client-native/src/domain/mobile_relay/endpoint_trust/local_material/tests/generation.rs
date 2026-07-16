use super::super::identity_generation::{
    derive_identity_public, generate_identity_material, signing_material,
};

#[test]
fn identity_and_signing_generation_round_trip_without_config_mutation() {
    let identity = generate_identity_material();
    let (_, public_key, fingerprint) = derive_identity_public(&identity.private_key).unwrap();
    assert_eq!(public_key, identity.public_key);
    assert_eq!(fingerprint, identity.fingerprint);

    let signing = signing_material(None).unwrap();
    let restored = signing_material(Some(&signing.private_key)).unwrap();
    assert_eq!(restored.public_key, signing.public_key);
}
