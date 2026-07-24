use super::super::http::{self, HttpFailure};

#[test]
fn http_policy_allows_loopback_plaintext_and_remote_tls_only() {
    assert!(http::validate_url("http://127.0.0.1:24173/session").is_ok());
    assert!(http::validate_url("http://localhost:4097/session").is_ok());
    assert!(http::validate_url("http://[::1]:4097/session").is_ok());
    assert!(http::validate_url("https://agent.example/session").is_ok());
    assert_eq!(
        http::validate_url("http://agent.example/session").unwrap_err(),
        HttpFailure::InvalidUrl
    );
    assert_eq!(
        http::validate_url("https://token@agent.example/session").unwrap_err(),
        HttpFailure::InvalidUrl
    );
}
