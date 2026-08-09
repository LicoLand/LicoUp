#!/bin/bash

set -euo pipefail

readonly repository="LicoLand/LicoUp"
readonly latest_release_url="https://github.com/${repository}/releases/latest"
readonly system_root="/"
readonly applications_root="${system_root}Applications"
readonly destination="${applications_root}/LicoUp.app"
readonly candidate="${applications_root}/.LicoUp.install.$$"
readonly backup="${applications_root}/.LicoUp.backup.$$"

fail() {
  printf 'LicoUp installer: %s\n' "$1" >&2
  exit 1
}

run_privileged() {
  if [[ "$needs_sudo" == "true" ]]; then
    /usr/bin/sudo "$@"
  else
    "$@"
  fi
}

main() {
  if [[ "${1:-}" == "--self-test" && "$#" -eq 1 ]]; then
    printf 'macos_github_installer=self_test_passed\n'
    return
  fi
  [[ "$#" -eq 0 ]] || fail "unexpected arguments"
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required"
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Apple silicon (arm64) is required"
  [[ -x /usr/bin/curl && -x /usr/bin/shasum && -x /usr/bin/ditto && -x /usr/bin/codesign ]] ||
    fail "required macOS system tools are unavailable"
  [[ ! -L "$destination" && ! -e "$candidate" && ! -e "$backup" ]] ||
    fail "unsafe or busy installation destination"

  local work_dir
  work_dir="$(/usr/bin/mktemp -d "${system_root}tmp/licoup-install.XXXXXX")"
  case "$work_dir" in
    "${system_root}tmp/licoup-install."*) ;;
    *) fail "temporary directory creation failed" ;;
  esac
  local archive="$work_dir/LicoUp-macos-arm64.zip"
  local checksum="$work_dir/LicoUp-macos-arm64.zip.sha256"
  local archive_list="$work_dir/archive-list.txt"
  local extracted="$work_dir/extracted"
  local release_page=""
  local release_tag=""
  local asset_base=""
  local previous_moved="false"
  local candidate_installed="false"
  local completed="false"
  needs_sudo="false"
  [[ -w "$applications_root" ]] || needs_sudo="true"
  if [[ "$needs_sudo" == "true" && ! -x /usr/bin/sudo ]]; then
    fail "administrator access is required to write to ${applications_root}"
  fi

  cleanup() {
    if [[ -e "$candidate" ]]; then
      run_privileged /bin/rm -rf -- "$candidate" || true
    fi
    if [[ "$completed" != "true" && "$candidate_installed" == "true" && -e "$destination" ]]; then
      run_privileged /bin/rm -rf -- "$destination" || true
    fi
    if [[ "$completed" != "true" && "$previous_moved" == "true" && -e "$backup" ]]; then
      run_privileged /bin/mv -- "$backup" "$destination" || true
    fi
    /bin/rm -rf -- "$work_dir"
  }
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  release_page="$(/usr/bin/curl --proto '=https' --tlsv1.2 --retry 3 \
    --silent --show-error --fail --location --head \
    --output /dev/null --write-out '%{url_effective}' "$latest_release_url")"
  release_tag="${release_page##*/}"
  case "$release_tag" in
    v[0-9]* ) ;;
    * ) fail "GitHub did not resolve a versioned release" ;;
  esac
  case "$release_tag" in
    *[!A-Za-z0-9._+-]* ) fail "GitHub returned an unsafe release tag" ;;
  esac
  asset_base="https://github.com/${repository}/releases/download/${release_tag}"

  /usr/bin/curl --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    --fail --location --output "$archive" "$asset_base/LicoUp-macos-arm64.zip"
  /usr/bin/curl --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    --fail --location --output "$checksum" "$asset_base/LicoUp-macos-arm64.zip.sha256"
  (cd "$work_dir" && /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$checksum")")

  /usr/bin/unzip -Z1 "$archive" > "$archive_list"
  local entry=""
  local entry_count=0
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != /* && "$entry" != *\\* ]] ||
      fail "release archive contains an unsafe path"
    case "/$entry" in
      */../*|*/./*) fail "release archive contains an unsafe path" ;;
    esac
    case "$entry" in
      LicoUp.app|LicoUp.app/*) ;;
      *) fail "release archive contains an unexpected top-level entry" ;;
    esac
    entry_count=$((entry_count + 1))
  done < "$archive_list"
  [[ "$entry_count" -gt 0 ]] || fail "release archive is empty"

  /bin/mkdir "$extracted"
  /usr/bin/ditto -x -k "$archive" "$extracted"
  [[ -d "$extracted/LicoUp.app" && ! -L "$extracted/LicoUp.app" ]] ||
    fail "release archive does not contain LicoUp.app"
  /usr/bin/codesign --verify --deep --strict "$extracted/LicoUp.app" ||
    fail "release code-signature integrity check failed"

  run_privileged /usr/bin/ditto "$extracted/LicoUp.app" "$candidate"
  /usr/bin/codesign --verify --deep --strict "$candidate" ||
    fail "installed candidate integrity check failed"
  if [[ -e "$destination" ]]; then
    run_privileged /bin/mv -- "$destination" "$backup"
    previous_moved="true"
  fi
  run_privileged /bin/mv -- "$candidate" "$destination"
  candidate_installed="true"
  /usr/bin/codesign --verify --deep --strict "$destination" ||
    fail "installed application integrity check failed"
  if [[ "$previous_moved" == "true" ]]; then
    run_privileged /bin/rm -rf -- "$backup"
    previous_moved="false"
  fi
  completed="true"
  printf 'LicoUp %s installed in %s.\n' "$release_tag" "$applications_root"
}

main "$@"
