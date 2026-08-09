//! Bounded workspace selection for locally executed agent turns.
//!
//! A local agent indexes the directory it is started in. Handing it the user's
//! home directory, an ancestor of the home directory, or a personal media
//! library makes every turn walk the whole personal tree, so the client keeps
//! its own small workspace under the LicoUp state root and uses it whenever the
//! requested directory is one of those unbounded roots.

use crate::platform::file_security::ensure_private_dir;
use crate::platform::paths::portable_data_dir;
use directories::UserDirs;
use std::path::{Component, Path, PathBuf};

/// Single client-owned fallback workspace under the LicoUp state root. Not
/// partitioned by agent — every local turn that needs the fallback shares it.
const AGENT_WORKSPACE_ROOT: &str = "agent-workspace";

/// Personal roots that hold documents, media, and application state rather than
/// a project. Only the root itself is unbounded; a directory the user
/// explicitly selects inside one of them stays usable.
const PERSONAL_LIBRARY_ROOTS: [&str; 12] = [
    "applications",
    "desktop",
    "documents",
    "downloads",
    "icloud drive",
    "library",
    "movies",
    "music",
    "onedrive",
    "pictures",
    "public",
    "videos",
];

/// Media library bundles are directories holding originals, thumbnails, and
/// derivative renders. Nothing inside one is an agent workspace.
const MEDIA_LIBRARY_BUNDLES: [&str; 5] = [
    "photoslibrary",
    "photolibrary",
    "imovielibrary",
    "tvlibrary",
    "theater",
];

/// Effective local workspace for one agent turn. An existing absolute request is
/// kept unless it is an unbounded personal root; anything else falls back to the
/// client-owned default, which keeps a missing directory from failing the turn at
/// process start.
pub(crate) fn resolve_local_agent_workspace(
    agent_id: &str,
    requested: Option<&Path>,
) -> Option<PathBuf> {
    let home = user_home();
    if let Some(requested) = requested
        .filter(|path| path.is_dir() && !is_unbounded_agent_workspace(path, home.as_deref()))
    {
        return Some(requested.to_path_buf());
    }
    default_local_agent_workspace(agent_id)
}

/// Client-owned default workspace, created on demand under the LicoUp state
/// root. [agent_id] is accepted for call-site compatibility and ignored: the
/// fallback is shared across agents.
pub(crate) fn default_local_agent_workspace(_agent_id: &str) -> Option<PathBuf> {
    let workspace = portable_data_dir().ok()?.join(AGENT_WORKSPACE_ROOT);
    ensure_private_dir(&workspace).ok()?;
    Some(workspace)
}

fn user_home() -> Option<PathBuf> {
    UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

pub(crate) fn is_unbounded_agent_workspace(path: &Path, home: Option<&Path>) -> bool {
    let path = lexical_path(path);
    if !path.is_absolute() {
        return true;
    }
    if path.parent().is_none() {
        return true;
    }
    if is_media_library_bundle(&path) {
        return true;
    }
    let Some(home) = home.map(lexical_path) else {
        return false;
    };
    // The home directory and every ancestor of it hold the user's whole
    // personal tree.
    if home.starts_with(&path) {
        return true;
    }
    path.parent() == Some(home.as_path()) && is_personal_library_root(&path)
}

fn is_personal_library_root(path: &Path) -> bool {
    file_name_lowercase(path).is_some_and(|name| PERSONAL_LIBRARY_ROOTS.contains(&name.as_str()))
}

fn is_media_library_bundle(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .is_some_and(|extension| MEDIA_LIBRARY_BUNDLES.contains(&extension.as_str()))
}

fn file_name_lowercase(path: &Path) -> Option<String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
}

/// Drop `.` components and trailing separators so a requested directory is
/// compared in one stable form. Symbolic links stay untouched because the
/// comparison must not depend on filesystem state.
fn lexical_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            other => normalized.push(other.as_os_str()),
        }
    }
    if normalized.as_os_str().is_empty() {
        return path.to_path_buf();
    }
    normalized
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_home() -> PathBuf {
        PathBuf::from("/fixture-root/resident")
    }

    #[test]
    fn personal_tree_roots_are_never_an_agent_workspace() {
        let home = synthetic_home();
        for unbounded in [
            PathBuf::from("/"),
            PathBuf::from("/synthetic"),
            PathBuf::from("/synthetic/home"),
            home.clone(),
            home.join("."),
            home.join("Movies"),
            home.join("Pictures"),
            home.join("Music"),
            home.join("Videos"),
            home.join("Downloads"),
            home.join("Desktop"),
            home.join("Documents"),
            home.join("Library"),
            home.join("Applications"),
            home.join("Pictures/Personal.photoslibrary"),
            PathBuf::from("relative/project"),
        ] {
            assert!(
                is_unbounded_agent_workspace(&unbounded, Some(&home)),
                "expected an unbounded workspace"
            );
        }
    }

    #[test]
    fn explicit_project_directories_stay_usable() {
        let home = synthetic_home();
        for bounded in [
            home.join("projects/alpha"),
            home.join("Documents/projects/alpha"),
            home.join("Desktop/scratch"),
            PathBuf::from("/synthetic/shared/projects/beta"),
        ] {
            assert!(
                !is_unbounded_agent_workspace(&bounded, Some(&home)),
                "expected a bounded workspace"
            );
        }
    }

    #[test]
    fn unknown_home_still_rejects_the_filesystem_root_and_media_bundles() {
        assert!(is_unbounded_agent_workspace(Path::new("/"), None));
        assert!(is_unbounded_agent_workspace(
            Path::new("/synthetic/Personal.photoslibrary"),
            None
        ));
        assert!(!is_unbounded_agent_workspace(
            Path::new("/synthetic/projects/alpha"),
            None
        ));
    }

    #[test]
    fn default_workspace_is_shared_under_the_client_state_root() {
        let root =
            std::env::temp_dir().join(format!("licoup-agent-workspace-{}", uuid::Uuid::new_v4()));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));

        let workspace = default_local_agent_workspace("cursor").unwrap();

        assert_eq!(workspace, root.join(AGENT_WORKSPACE_ROOT));
        assert!(workspace.is_dir());
        assert_eq!(
            default_local_agent_workspace("codex").unwrap(),
            workspace,
            "fallback workspace must not vary by agent"
        );
        assert_eq!(
            resolve_local_agent_workspace("cursor", Some(Path::new("relative"))),
            Some(workspace.clone())
        );
        // A directory that no longer exists must not reach process start.
        assert_eq!(
            resolve_local_agent_workspace("cursor", Some(&root.join("removed-project"))),
            Some(workspace.clone())
        );
        let project = root.join("project-alpha");
        std::fs::create_dir_all(&project).unwrap();
        assert_eq!(
            resolve_local_agent_workspace("cursor", Some(&project)),
            Some(project)
        );
        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }
}
