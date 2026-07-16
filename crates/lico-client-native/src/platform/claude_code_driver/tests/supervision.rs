use super::*;

#[test]
fn unknown_session_never_spawns_or_accepts_control() {
    let session = "claude-code-test-session-that-is-not-registered";
    assert!(!has_live_session(session));
    assert_eq!(cancel(session), ControlDisposition::SessionUnavailable);
    assert_eq!(
        cleanup_session(session),
        ControlDisposition::SessionUnavailable
    );
}
