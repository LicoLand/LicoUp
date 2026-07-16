use super::*;

#[test]
fn archive_home_uses_windows_userprofile_when_home_is_missing() {
    let resolved = home_dir_from_env(|name| match name {
        "USERPROFILE" => Some(OsString::from(r"C:\Profile\LicoLite")),
        _ => None,
    });

    assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
}

#[test]
fn archive_home_uses_windows_drive_and_homepath_fallback() {
    let resolved = home_dir_from_env(|name| match name {
        "HOMEDRIVE" => Some(OsString::from("C:")),
        "HOMEPATH" => Some(OsString::from(r"\Profile\LicoLite")),
        _ => None,
    });

    assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
}

#[test]
fn archive_expand_home_accepts_windows_style_tilde_paths() {
    let expanded = expand_home_from(r"~\.codex\sessions", || {
        PathBuf::from(r"C:\Profile\LicoLite")
    });

    assert_eq!(
        expanded,
        PathBuf::from(r"C:\Profile\LicoLite").join(r".codex\sessions")
    );
}
