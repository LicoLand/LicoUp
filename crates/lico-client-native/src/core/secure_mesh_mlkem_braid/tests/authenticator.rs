use super::{
    super::authenticator::RatchetedAuthenticator,
    support::{TEST_SECRET, hex},
};

#[test]
fn authenticator_known_answer() {
    let auth = RatchetedAuthenticator::initialize(1, &TEST_SECRET).unwrap();
    assert_eq!(
        hex(auth.root_key.as_slice()),
        "aec27dcc35663c5a72873280df06f0195496867754eb460b76b5a7c1b85b3955"
    );
    assert_eq!(
        hex(auth.mac_key.as_slice()),
        "b2d0246c8831cc34828fa15e0907e564c6781fc2718f649ea684cf013487a2a5"
    );
    let header = (0u8..64).collect::<Vec<_>>();
    assert_eq!(
        hex(&auth.mac_header(1, &header).unwrap()),
        "bb34450be173a859b7e0ac08124b60fb091d5f59ffd666fde8f8be1a4b1fb92c"
    );
}
