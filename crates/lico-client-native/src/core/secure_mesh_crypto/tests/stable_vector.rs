use super::test_support::*;

#[test]
fn secure_mesh_content_crypto_has_stable_vectors_for_all_payload_kinds() {
    let context = context_fixture();
    #[allow(dead_code)]
    struct ContentCryptoStableVector {
        label: &'static str,
        payload: SecureMeshPlaintext,
        nonce: [u8; CONTENT_NONCE_LEN],
        encrypted_header: &'static str,
        ciphertext: &'static str,
        ciphertext_sha256: &'static str,
        ciphertext_size: usize,
    }
    let vectors = [
        ContentCryptoStableVector {
            label: "command",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::Command,
                br#"{"op":"agent.message.send"}"#,
            ),
            nonce: [11u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxCwsLCwsLCwsLCwsLid3eN_56h7EgoDu-Ulym2ksRx-BHS3P-AC50baYelyA",
            ciphertext: "-ar9u2Fl3ad9Jlu8ULlk-1qFuHQ1ADwOy6-NmMCE-bSMpoHNZ1QUhKDhoj7kNyrT1Ovw1vZWl2VpnKSPy8d2UJp6WdPiGeljxpjAWNopTCzcSeA-TmtzunzIGpwuW2zV21VngG1U11eFEBAMhqhp1Z6NDag4ejnvsQ",
            ciphertext_sha256: "sha256:983d480be6b74416ef6a7541a35ef60be70ce0e7a577f25b904e85748a2b070f",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "result",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::ResultPayload,
                br#"{"ok":true}"#,
            ),
            nonce: [12u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxDAwMDAwMDAwMDAwMYPPp34_d3xprNFxTlCSpHUUnP108t7RF7We85N-56g8",
            ciphertext: "1rFim7RvXCwMI9sriRbvIbQv9WFIl4oGmJ1gna2PPRCGkoHNKBAi9mEvzhWqft-pJjoPz41mTONOrZj5fLn3t5KyBFyGk-j7KQBTJZfJdMROBU-bLr4dBS2-PHuuzYi85J_j8A",
            ciphertext_sha256: "sha256:742fb6d16cccd1406fad32f6bf1e1c3b2fefc5cd87ee0a6987822a1122608c12",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "error",
            payload: SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"permission denied"),
            nonce: [13u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxDQ0NDQ0NDQ0NDQ0NTM3hz_h9gz7umBrAv64Q42VAuyJwbYq0MiztVSDFohM",
            ciphertext: "wQLaYL3c7UeoiE5DNukuq-Dj_piq8PtcunwOZZYWHQ8AJcYYYIk4OC_NP8lhCt5nYK2rO_G72kuhFu3O6WHAEk5xJRoabmn0MQA_0vJ4dBeSlybZanmN1WmVhVl3uOZY6CJBGBEcrMtBuA",
            ciphertext_sha256: "sha256:ab06fc5c61f70d8b81d28c63ec5596d732091a31ef8fd11e0c2aec0d31e7768d",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "file_chunk",
            payload: SecureMeshPlaintext::new(SecureMeshPayloadKind::FileChunk, b"file-bytes")
                .with_content_type("application/octet-stream"),
            nonce: [14u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxDg4ODg4ODg4ODg4OrLHXwrpVMiFxxPyvZCaUbnc6swlTk0Srs--TuX0whPw",
            ciphertext: "UzCiIRVjxbR-EeYrzWLeo1KcpsSvnu_xMcEpZkMVv0bkX8TRcYH0q5gDMYL5sx-vuEvl_qhXhf7LaDnNxptEKR_JVoAwDYS3ojf6poMeEza08p3qxDo6iysCzs5sutdPeh-R1r8JX9qjFP6PQny5sSx3AssTqCDTC5u07Ojy9Q",
            ciphertext_sha256: "sha256:bd8573b353f26c81d7eef7d977a9d4f64c31502b34d75ed7cc884917794507be",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "file_manifest",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::FileManifest,
                br#"{"name":"redacted.bin","chunks":1}"#,
            )
            .with_content_type("application/json"),
            nonce: [15u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxDw8PDw8PDw8PDw8PpbBbxYXu43WrnvCLzac4z_01omjap3M79dpBifCudkY",
            ciphertext: "p5Fc0jS1RBf7QsOt3EFGZ8-ycm_J9XBv4-93a_JfJnR5gNVStZe6azbGF8z5HRefwEg0K3EIV4ACwtJvn-5PrJulOb-e2HV4Jdo6DeVxeK8eT5Be6h8STi3Tf9ErMeY_QSjeB7CVlmY97DqAIxuAWT7chvW0SRVCgsNUb1xdGMYHa6RfB3WpNmDmuxfbFNE",
            ciphertext_sha256: "sha256:c77c2dfb5656a364aece995e4ad82dc47864d547c3168dba57341929addd26fa",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "service_action",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::ServiceAction,
                br#"{"actionKind":"message_delete","messageHash":"sha256:redacted"}"#,
            )
            .with_content_type("application/json"),
            nonce: [16u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxEBAQEBAQEBAQEBAQ-YksT7y5m8lw5V9wzRjWksh3jdF1fmqM8P-1BcabJrU",
            ciphertext: "lsXkoS6g6VIdBbuWcqE_cX21dd2YVLQZlZDDFc4Rp-75DeqoqPJZkIqfjub6cJjpV0ags0gAG7yyJV6LmE99C-D0kRcnR3_kPszFL1xBcoBLejNRUR3wk-NQ5oM2drUamnCHZoJyy3l0bdArmbC8kK1FnMfylJl7KncpSCvZ5k3lFMWHU0SjpssXnjfEm0oiX206_rhW_suQLrt9brF6r5WYt6Amk8JPP7CQ8g",
            ciphertext_sha256: "sha256:ed83f2fc9c2a33f92658699484dbb2e831dad2301a29fb6ed69659d84557f86e",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "typing_indicator",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::TypingIndicator,
                br#"{"typingState":"started"}"#,
            )
            .with_content_type("application/json"),
            nonce: [17u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxERERERERERERERERvDL66dT4cAEssRk094Qb7SVC0sOCqPeOdnhkucEQ_ms",
            ciphertext: "FYxeYCydlCadYK6SlgAP6oTjlPzPmOD8PaS3e5Z76Ai0nTDk61Qt9eHNFfDO3noCbzpBw4eBvpi4pwt3bg96nodSxzptRNleo9OWj7mTovpOyRP-5AmSXBi9VVc2Jj9PiKIvUIflPwsms2i2b8gekmObUNZYoRzSq_XpCoEyZTgk5h6A3Fk",
            ciphertext_sha256: "sha256:278c4a852a80b7a3cb6580157cc3cb053fcbd1e738dde2a8663f93814e4efad3",
            ciphertext_size: 256,
        },
        ContentCryptoStableVector {
            label: "read_receipt",
            payload: SecureMeshPlaintext::new(
                SecureMeshPayloadKind::ReadReceipt,
                br#"{"readUpToMessageDigest":"sha256:redacted"}"#,
            )
            .with_content_type("application/json"),
            nonce: [18u8; CONTENT_NONCE_LEN],
            encrypted_header: "TENPU00tSERSLXYxEhISEhISEhISEhIS57RIYPytMnMQMMfoFaiQnHQpJ0bln5Yz-UHapPLyfmI",
            ciphertext: "XYzZ45FRETlpANS-Rwfh3-pcmvIaxXepYScebTtgIzMi9xiQTByWXc0786CCI_qbdJi3TKeGaxB0HoYWaZpZGXjAdFBCNTCIOXiezxdm-7lY8e9blANraywaO5kjzsbr9VK2sWUswWgxB4LdE9nsrBKfITfQRRv9an_nuWoTDVtx1fIQRdJyo0JDNIJPcwKab_TKcOrxw1k",
            ciphertext_sha256: "sha256:fb972e87169b043a22f7aa16fb21c01f35546178a9accb0146adbaefe1b0079e",
            ciphertext_size: 256,
        },
    ];
    assert_eq!(vectors.len(), 8);
    for vector in vectors {
        let candidate =
            seal_payload_with_nonce(&key_fixture(42), &context, &vector.payload, vector.nonce)
                .unwrap();
        assert_eq!(
            candidate.encrypted_header, vector.encrypted_header,
            "{} encrypted header vector changed",
            vector.label
        );
        let candidate_ciphertext_sha256 = format!(
            "sha256:{}",
            Sha256::digest(candidate.ciphertext.as_bytes())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
        );
        assert_eq!(
            candidate_ciphertext_sha256, vector.ciphertext_sha256,
            "{} ciphertext digest vector changed",
            vector.label
        );
        assert_eq!(
            candidate.ciphertext_size, vector.ciphertext_size,
            "{} ciphertext size vector changed",
            vector.label
        );
        let opened =
            open_payload(&key_fixture(42), &context, &candidate, vector.payload.kind).unwrap();
        assert_eq!(opened.kind, vector.payload.kind, "{} kind", vector.label);
        assert_eq!(opened.body, vector.payload.body, "{} body", vector.label);
        assert_eq!(
            opened.content_type, vector.payload.content_type,
            "{} content type",
            vector.label
        );
    }
}
