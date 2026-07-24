use super::{
    super::authenticator::RatchetedAuthenticator,
    support::{TEST_SECRET, hex},
};

#[test]
fn authenticator_binds_secret_epoch_and_header() {
    let auth = RatchetedAuthenticator::initialize(1, TEST_SECRET.as_slice()).unwrap();
    let same = RatchetedAuthenticator::initialize(1, TEST_SECRET.as_slice()).unwrap();
    assert_eq!(hex(auth.root_key.as_slice()), hex(same.root_key.as_slice()));
    assert_eq!(hex(auth.mac_key.as_slice()), hex(same.mac_key.as_slice()));
    assert_ne!(auth.root_key.as_slice(), auth.mac_key.as_slice());

    let mut other_secret = TEST_SECRET.to_vec();
    other_secret[0] ^= 1;
    let other = RatchetedAuthenticator::initialize(1, &other_secret).unwrap();
    let next_epoch = RatchetedAuthenticator::initialize(2, TEST_SECRET.as_slice()).unwrap();
    assert_ne!(auth.root_key.as_slice(), other.root_key.as_slice());
    assert_ne!(auth.mac_key.as_slice(), other.mac_key.as_slice());
    assert_ne!(auth.root_key.as_slice(), next_epoch.root_key.as_slice());
    assert_ne!(auth.mac_key.as_slice(), next_epoch.mac_key.as_slice());

    let header = (0u8..64).collect::<Vec<_>>();
    let tag = auth.mac_header(1, &header).unwrap();
    assert!(same.verify_header(1, &header, &tag).is_ok());
    let mut altered_header = header.clone();
    altered_header[0] ^= 1;
    assert!(auth.verify_header(1, &altered_header, &tag).is_err());
    assert!(auth.verify_header(2, &header, &tag).is_err());
    assert!(other.verify_header(1, &header, &tag).is_err());
    assert!(next_epoch.verify_header(1, &header, &tag).is_err());
    assert!(auth.verify_ciphertext(1, &header, &tag).is_err());
}
