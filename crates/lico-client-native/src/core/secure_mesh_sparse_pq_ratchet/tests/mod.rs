use super::{SPQR_MAX_PERSISTED_STATE_BYTES, SecureMeshSparsePqRatchet, derive_hybrid_message_key};

fn random_test_secret() -> [u8; 32] {
    [
        *uuid::Uuid::new_v4().as_bytes(),
        *uuid::Uuid::new_v4().as_bytes(),
    ]
    .concat()
    .try_into()
    .unwrap()
}

#[test]
fn sparse_pq_ratchet_matches_keys_and_restores_state() {
    let secret = random_test_secret();
    let mut alice = SecureMeshSparsePqRatchet::new_initiator(&secret).unwrap();
    let mut bob = SecureMeshSparsePqRatchet::new_responder(&secret).unwrap();
    for _ in 0..12 {
        let sent = alice.send_key().unwrap();
        let received = bob.receive_key(&sent.header).unwrap();
        assert_eq!(sent.message_key.as_ref(), received.as_ref());

        let reply = bob.send_key().unwrap();
        let opened = alice.receive_key(&reply.header).unwrap();
        assert_eq!(reply.message_key.as_ref(), opened.as_ref());
    }
    let persisted = alice.persist().unwrap();
    let restored = SecureMeshSparsePqRatchet::restore(persisted.as_slice()).unwrap();
    assert_eq!(restored.epoch(), alice.epoch());
    assert_eq!(restored.is_poisoned(), alice.is_poisoned());
}

#[test]
fn sparse_pq_ratchet_supports_bounded_out_of_order_messages() {
    let secret = random_test_secret();
    let mut alice = SecureMeshSparsePqRatchet::new_initiator(&secret).unwrap();
    let mut bob = SecureMeshSparsePqRatchet::new_responder(&secret).unwrap();
    let first = alice.send_key().unwrap();
    let second = alice.send_key().unwrap();
    let third = alice.send_key().unwrap();
    let opened_third = bob.receive_key(&third.header).unwrap();
    assert_eq!(third.message_key.as_ref(), opened_third.as_ref());
    let opened_first = bob.receive_key(&first.header).unwrap();
    assert_eq!(first.message_key.as_ref(), opened_first.as_ref());
    let opened_second = bob.receive_key(&second.header).unwrap();
    assert_eq!(second.message_key.as_ref(), opened_second.as_ref());
}

#[test]
fn sparse_pq_ratchet_opens_retained_previous_epoch_after_new_epoch() {
    let secret = random_test_secret();
    let mut alice = SecureMeshSparsePqRatchet::new_initiator(&secret).unwrap();
    let mut bob = SecureMeshSparsePqRatchet::new_responder(&secret).unwrap();
    let delayed = alice.send_key().unwrap();

    for _ in 0..512 {
        let sent = alice.send_key().unwrap();
        let received = bob.receive_key(&sent.header).unwrap();
        assert_eq!(sent.message_key.as_ref(), received.as_ref());

        let reply = bob.send_key().unwrap();
        let opened = alice.receive_key(&reply.header).unwrap();
        assert_eq!(reply.message_key.as_ref(), opened.as_ref());
        if bob.receiving_epoch > 0 {
            break;
        }
    }

    assert_eq!(bob.receiving_epoch, 1);
    let opened_delayed = bob.receive_key(&delayed.header).unwrap();
    assert_eq!(delayed.message_key.as_ref(), opened_delayed.as_ref());
}

#[test]
fn hybrid_message_key_is_bound_to_both_ratchets_and_session() {
    let ec = random_test_secret();
    let pq = random_test_secret();
    let mut other_ec = ec;
    other_ec[0] ^= 1;
    let mut other_pq = pq;
    other_pq[0] ^= 1;
    let first = derive_hybrid_message_key(&ec, &pq, b"session-a").unwrap();
    let same = derive_hybrid_message_key(&ec, &pq, b"session-a").unwrap();
    let changed_ec = derive_hybrid_message_key(&other_ec, &pq, b"session-a").unwrap();
    let changed_pq = derive_hybrid_message_key(&ec, &other_pq, b"session-a").unwrap();
    let changed_session = derive_hybrid_message_key(&ec, &pq, b"session-b").unwrap();
    assert_eq!(first.as_ref(), same.as_ref());
    assert_ne!(first.as_ref(), changed_ec.as_ref());
    assert_ne!(first.as_ref(), changed_pq.as_ref());
    assert_ne!(first.as_ref(), changed_session.as_ref());
}

#[test]
fn sparse_pq_ratchet_destroy_is_persistent_and_fail_closed() {
    let mut ratchet = SecureMeshSparsePqRatchet::new_initiator(&random_test_secret()).unwrap();
    ratchet.destroy();
    assert!(ratchet.is_poisoned());
    assert!(ratchet.send_key().is_err());
    let persisted = ratchet.persist().unwrap();
    let mut restored = SecureMeshSparsePqRatchet::restore(persisted.as_slice()).unwrap();
    assert!(restored.is_poisoned());
    assert!(restored.send_key().is_err());
}

#[test]
fn sparse_pq_ratchet_rejects_oversized_persisted_state() {
    let oversized = vec![b' '; SPQR_MAX_PERSISTED_STATE_BYTES + 1];
    assert!(SecureMeshSparsePqRatchet::restore(&oversized).is_err());
}
