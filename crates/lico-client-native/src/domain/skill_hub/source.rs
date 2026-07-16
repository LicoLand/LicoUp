use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;
use url::Url;
use uuid::Uuid;

const MAX_GITHUB_ARCHIVE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_GITHUB_ARCHIVE_ENTRIES: usize = 4096;
const MAX_GITHUB_ARCHIVE_DEPTH: usize = 32;

#[derive(Clone, Debug)]
pub(super) struct SkillSource {
    url: String,
    pub(super) github: Option<GitHubSource>,
    local_path: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub(super) struct GitHubSource {
    pub(super) owner: String,
    pub(super) repo: String,
    pub(super) ref_name: String,
    pub(super) path: String,
}

#[derive(Debug)]
pub(super) struct ResolvedSkillPackage {
    pub(super) package_dir: PathBuf,
    temp_root: Option<PathBuf>,
}

impl Drop for ResolvedSkillPackage {
    fn drop(&mut self) {
        if let Some(temp_root) = self.temp_root.take() {
            let _ = fs::remove_dir_all(temp_root);
        }
    }
}

impl SkillSource {
    pub(super) fn public_summary(&self) -> Value {
        if let Some(github) = &self.github {
            json!({
                "kind": "github",
                "url": self.url,
                "owner": github.owner,
                "repo": github.repo,
                "ref": github.ref_name,
                "path": github.path
            })
        } else if let Some(local_path) = &self.local_path {
            json!({
                "kind": "local-directory",
                "path": local_path.to_string_lossy()
            })
        } else {
            json!({
                "kind": "unknown",
                "url": self.url
            })
        }
    }
}

impl GitHubSource {
    fn archive_url(&self) -> Result<Url> {
        let mut url = Url::parse("https://api.github.com")
            .map_err(|_| anyhow!("skill_github_archive_url_invalid"))?;
        {
            let mut segments = url
                .path_segments_mut()
                .map_err(|_| anyhow!("skill_github_archive_url_invalid"))?;
            segments.extend(["repos", &self.owner, &self.repo, "tarball", &self.ref_name]);
        }
        Ok(url)
    }
}

pub(super) fn skill_source(params: &Value) -> Result<SkillSource> {
    if let Some(source_path) = text_param(params, &["sourcePath", "localPath"], None) {
        let local_path = PathBuf::from(source_path);
        ensure!(
            local_path.is_absolute(),
            "skill_source_path_must_be_absolute"
        );
        return Ok(SkillSource {
            url: String::new(),
            github: None,
            local_path: Some(local_path),
        });
    }
    let url = text_param(params, &["url", "githubUrl", "sourceUrl"], Some(0))
        .ok_or_else(|| anyhow!("skill_install_github_url_required"))?
        .to_owned();
    let github = parse_github_skill_url(&url, params)?;
    Ok(SkillSource {
        url,
        github: Some(github),
        local_path: None,
    })
}

pub(super) fn resolve_skill_package(source: &SkillSource) -> Result<ResolvedSkillPackage> {
    if let Some(local_path) = &source.local_path {
        return Ok(ResolvedSkillPackage {
            package_dir: local_path.clone(),
            temp_root: None,
        });
    }
    let github = source
        .github
        .as_ref()
        .ok_or_else(|| anyhow!("skill_github_source_missing"))?;
    let temp_root = env::temp_dir().join(format!("lico-skill-install-{}", Uuid::new_v4()));
    crate::platform::file_security::ensure_private_dir(&temp_root)?;
    let result = stage_github_archive(github, &temp_root).map(|package_dir| ResolvedSkillPackage {
        package_dir,
        temp_root: Some(temp_root.clone()),
    });
    if result.is_err() {
        let _ = fs::remove_dir_all(temp_root);
    }
    result
}

fn parse_github_skill_url(url: &str, params: &Value) -> Result<GitHubSource> {
    ensure!(url == url.trim(), "skill_github_url_invalid");
    let lowercase_url = url.to_ascii_lowercase();
    ensure!(
        !url.contains("/../") && !url.contains("/./") && !lowercase_url.contains("%2e"),
        "skill_github_url_invalid"
    );
    let parsed = Url::parse(url).map_err(|_| anyhow!("skill_github_url_invalid"))?;
    ensure!(
        parsed.scheme() == "https"
            && parsed.host_str() == Some("github.com")
            && parsed.username().is_empty()
            && parsed.password().is_none()
            && parsed.port().is_none()
            && parsed.query().is_none()
            && parsed.fragment().is_none(),
        "skill_github_url_invalid"
    );
    let segments = parsed
        .path_segments()
        .ok_or_else(|| anyhow!("skill_github_url_invalid"))?
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    ensure!(segments.len() >= 2, "skill_github_url_invalid");
    let owner = validate_github_segment(segments[0], "skill_github_owner_invalid")?;
    let repo = validate_github_segment(
        segments[1].trim_end_matches(".git"),
        "skill_github_repo_invalid",
    )?;
    let explicit_ref = text_param(params, &["ref", "branch", "tag"], Some(2));
    let explicit_path = text_param(params, &["path", "skillPath"], Some(3));
    let (url_ref, url_path) = match segments.as_slice() {
        [_, _] => (None, None),
        [_, _, kind, ref_name, remainder @ ..] if matches!(*kind, "tree" | "blob") => {
            (Some(*ref_name), Some(remainder.join("/")))
        }
        _ => return Err(anyhow!("skill_github_url_invalid")),
    };
    let ref_name = validate_git_ref(explicit_ref.or(url_ref).unwrap_or("main"))?;
    let path = validate_relative_path(explicit_path.map(str::to_owned).or(url_path))?;
    Ok(GitHubSource {
        owner,
        repo,
        ref_name,
        path,
    })
}

fn stage_github_archive(source: &GitHubSource, temp_root: &Path) -> Result<PathBuf> {
    let archive_root = temp_root.join("archive");
    ensure!(!archive_root.exists(), "skill_github_archive_root_exists");
    let archive_url = source.archive_url()?;
    let response = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(30))
        .timeout_write(Duration::from_secs(10))
        .redirects(3)
        .build()
        .get(archive_url.as_str())
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "LicoArc-Skill-Manager")
        .call()
        .map_err(|_| anyhow!("skill_github_fetch_failed"))?;
    let final_url =
        Url::parse(response.get_url()).map_err(|_| anyhow!("skill_github_redirect_invalid"))?;
    ensure!(
        final_url.scheme() == "https"
            && matches!(
                final_url.host_str(),
                Some("api.github.com" | "github.com" | "codeload.github.com")
            ),
        "skill_github_redirect_invalid"
    );
    let mut archive = Vec::new();
    response
        .into_reader()
        .take(MAX_GITHUB_ARCHIVE_BYTES + 1)
        .read_to_end(&mut archive)
        .map_err(|_| anyhow!("skill_github_archive_read_failed"))?;
    ensure!(
        archive.len() as u64 <= MAX_GITHUB_ARCHIVE_BYTES,
        "skill_github_archive_too_large"
    );
    crate::core::safe_archive::extract_tar_gz_safe(
        &archive,
        &archive_root,
        Some(MAX_GITHUB_ARCHIVE_BYTES),
        Some(MAX_GITHUB_ARCHIVE_ENTRIES),
        Some(MAX_GITHUB_ARCHIVE_DEPTH),
    )?;
    let repository_root = extracted_repository_root(&archive_root)?;
    let package_root = if source.path.is_empty() {
        repository_root
    } else {
        repository_root.join(&source.path)
    };
    let metadata = fs::symlink_metadata(&package_root)
        .map_err(|_| anyhow!("skill_github_package_path_missing"))?;
    ensure!(
        metadata.file_type().is_dir() && !metadata.file_type().is_symlink(),
        "skill_github_package_path_invalid"
    );
    Ok(package_root)
}

fn extracted_repository_root(archive_root: &Path) -> Result<PathBuf> {
    let entries = fs::read_dir(archive_root)?.collect::<std::io::Result<Vec<_>>>()?;
    ensure!(entries.len() == 1, "skill_github_archive_root_invalid");
    let entry = &entries[0];
    let metadata = fs::symlink_metadata(entry.path())?;
    ensure!(
        metadata.file_type().is_dir() && !metadata.file_type().is_symlink(),
        "skill_github_archive_root_invalid"
    );
    Ok(entry.path())
}

fn validate_github_segment(value: &str, code: &'static str) -> Result<String> {
    ensure!(
        !value.is_empty()
            && value.len() <= 100
            && value != "."
            && value != ".."
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.')),
        code
    );
    Ok(value.to_owned())
}

fn validate_git_ref(value: &str) -> Result<String> {
    ensure!(
        value == value.trim()
            && !value.is_empty()
            && value.len() <= 255
            && !value
                .as_bytes()
                .first()
                .is_some_and(|byte| matches!(*byte, b'-' | b'/' | b'.'))
            && !value
                .as_bytes()
                .last()
                .is_some_and(|byte| matches!(*byte, b'/' | b'.'))
            && !value.ends_with(".lock")
            && !value.contains("..")
            && !value.contains("@{")
            && !value.contains("//")
            && value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'/')
            }),
        "skill_github_ref_invalid"
    );
    Ok(value.to_owned())
}

fn validate_relative_path(value: Option<String>) -> Result<String> {
    let Some(value) = value else {
        return Ok(String::new());
    };
    ensure!(value == value.trim(), "skill_github_path_invalid");
    let value = value.trim_matches('/');
    if value.is_empty() {
        return Ok(String::new());
    }
    let path = Path::new(value);
    ensure!(
        !path.is_absolute()
            && !path.components().any(|part| {
                matches!(
                    part,
                    Component::ParentDir | Component::Prefix(_) | Component::RootDir
                )
            })
            && !value.contains('\\'),
        "skill_github_path_invalid"
    );
    Ok(value.to_owned())
}

fn text_param<'a>(
    params: &'a Value,
    keys: &[&str],
    positional_index: Option<usize>,
) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .or_else(|| {
            positional_index.and_then(|index| {
                params
                    .get("positionals")
                    .and_then(Value::as_array)
                    .and_then(|items| items.get(index))
                    .and_then(Value::as_str)
            })
        })
        .filter(|value| !value.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn github_source_accepts_https_repo_and_bounded_tree_path() {
        let source = skill_source(&json!({
            "url": "https://github.com/example/tools/tree/release/skills/review-helper"
        }))
        .unwrap();
        let github = source.github.unwrap();
        assert_eq!(github.owner, "example");
        assert_eq!(github.repo, "tools");
        assert_eq!(github.ref_name, "release");
        assert_eq!(github.path, "skills/review-helper");
        let archive_url = github.archive_url().unwrap();
        assert_eq!(archive_url.host_str(), Some("api.github.com"));
    }

    #[test]
    fn github_source_rejects_non_https_credentials_query_and_traversal() {
        for url in [
            "http://github.com/example/tools",
            "https://github.com/example/tools?ref=main",
            "https://github.com/example/tools/tree/main/../private",
        ] {
            assert!(skill_source(&json!({"url": url})).is_err(), "{url}");
        }
        let credential_url = ["https://", "credential", "@github.com/example/tools"].concat();
        assert!(skill_source(&json!({"url": credential_url})).is_err());
    }

    #[test]
    fn local_mirror_requires_an_explicit_absolute_directory() {
        assert!(skill_source(&json!({"sourcePath": "relative/skills"})).is_err());
    }
}
