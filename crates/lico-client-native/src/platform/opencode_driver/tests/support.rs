use super::PathBuf;

pub(super) fn absolute_test_cwd() -> PathBuf {
    std::env::current_dir().expect("test working directory")
}
