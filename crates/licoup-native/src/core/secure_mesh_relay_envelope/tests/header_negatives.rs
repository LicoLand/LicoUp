use chacha20poly1305::{
    ChaCha20Poly1305, Key, KeyInit, Nonce,
    aead::{Aead, Payload as AeadPayload},
};
use zeroize::Zeroizing;

use super::support::*;

#[test]
fn private_header_rejects_pre_migration_chacha20poly1305_layout() {
    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
        &mailbox,
        MIN_PADDING_BUCKET_BYTES,
        [0xb1; DELIVERY_ID_BYTES],
    )
    .unwrap();
    let key = [0xb2u8; RELAY_HEADER_KEY_BYTES];
    let old_nonce = [0xb3u8; 12];
    let old_frame_magic = b"LICO-SECURE-MESH-PRIVATE-RELAY-HEADER-v2";
    let old_frame_bytes =
        SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - old_nonce.len() - RELAY_HEADER_TAG_BYTES;
    let private_header = b"pre-migration-private-header";
    let mut old_frame = Zeroizing::new(vec![0u8; old_frame_bytes]);
    old_frame[..old_frame_magic.len()].copy_from_slice(old_frame_magic);
    let length_start = old_frame_magic.len();
    let payload_start = length_start + RELAY_HEADER_LENGTH_BYTES;
    old_frame[length_start..payload_start]
        .copy_from_slice(&(private_header.len() as u32).to_be_bytes());
    old_frame[payload_start..payload_start + private_header.len()].copy_from_slice(private_header);

    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&old_nonce),
            AeadPayload {
                msg: old_frame.as_slice(),
                aad: &draft.authenticated_outer_data().unwrap(),
            },
        )
        .unwrap();
    assert_eq!(encrypted.len(), old_frame_bytes + RELAY_HEADER_TAG_BYTES);
    let mut old_wire = [0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES];
    old_wire[..old_nonce.len()].copy_from_slice(&old_nonce);
    old_wire[old_nonce.len()..].copy_from_slice(&encrypted);

    let envelope = draft
        .finish(&old_wire, &[0xb4u8; MIN_PADDING_BUCKET_BYTES])
        .unwrap();
    assert!(open_private_relay_header(&envelope, [&key[..]]).is_err());
}

#[test]
fn private_header_frame_rejects_oversize_nonzero_padding_and_wrong_keys() {
    assert!(
        encode_private_relay_header_frame(&vec![0u8; MAX_RELAY_PRIVATE_HEADER_BYTES + 1]).is_err()
    );
    let mut frame = encode_private_relay_header_frame(b"bounded-private-header").unwrap();
    let last = frame.len() - 1;
    frame[last] = 1;
    assert!(decode_private_relay_header_frame(frame).is_err());

    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
        &mailbox,
        MIN_PADDING_BUCKET_BYTES,
        [0x91; DELIVERY_ID_BYTES],
    )
    .unwrap();
    let key = [0x92u8; RELAY_HEADER_KEY_BYTES];
    let header = seal_private_relay_header(&draft, &key, b"header").unwrap();
    let envelope = draft
        .finish(&header, &[0x93u8; MIN_PADDING_BUCKET_BYTES])
        .unwrap();
    assert!(
        open_private_relay_header(
            &envelope,
            [
                &[0x94u8; RELAY_HEADER_KEY_BYTES][..],
                &[0x95u8; RELAY_HEADER_KEY_BYTES - 1][..],
            ],
        )
        .is_err()
    );
}

#[test]
fn private_header_candidate_key_count_is_bounded() {
    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
        &mailbox,
        MIN_PADDING_BUCKET_BYTES,
        [0xc1; DELIVERY_ID_BYTES],
    )
    .unwrap();
    let sealing_key = [0xc2u8; RELAY_HEADER_KEY_BYTES];
    let header = seal_private_relay_header(&draft, &sealing_key, b"bounded-key-search").unwrap();
    let envelope = draft
        .finish(&header, &[0xc3u8; MIN_PADDING_BUCKET_BYTES])
        .unwrap();
    let candidates = vec![[0xc4u8; RELAY_HEADER_KEY_BYTES]; 1_025];
    let error = open_private_relay_header(
        &envelope,
        candidates.iter().map(|candidate| candidate.as_slice()),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("candidate-key limit exceeded"));
}
