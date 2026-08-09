const freezeLane = (scripts) => Object.freeze([...scripts]);

export const CLIENT_GATE_SCHEMA_VERSION = "licomesh.client-gate-policy.v1";

export const CLIENT_GATE_LANES = Object.freeze({
  source: freezeLane([
    "client:gate:topology",
    "client:gate:self-test",
    "repo:client-boundary",
    "repo:local-info-hygiene:self-test",
    "repo:local-info-hygiene",
    "repo:workspace-cache-boundary",
    "client:artifacts:self-test",
    "client:version:check",
    "client:verify:plan",
    "client:verify:architecture",
    "client:verify:local-data-egress-boundary",
    "client:verify:agent-conversation-parity",
    "client:verify:agent-adapter-standard",
    "client:verify:agent-conversations:product-e2e:self-test",
    "client:verify:agent-usage",
    "client:contracts:test",
    "client:verify:update-release",
    "client:verify:windows-file-security",
    "repo:docs",
  ]),
  flutter: freezeLane([
    "client:get",
    "client:format:check",
    "client:analyze",
    "client:test",
  ]),
  rust: freezeLane([
    "client:native:fmt:check",
    "client:native:clippy",
    "client:native:test",
    "client:native:smoke",
  ]),
  android: freezeLane([
    "client:get",
    "client:test:android:native",
  ]),
  dependencies: freezeLane([
    "client:deps:audit",
  ]),
  "release-policy": freezeLane([
    "client:pr:preflight:self-test",
    "client:verify:release-artifact-io:self-test",
    "client:verify:release-dependency-receipts:self-test",
    "client:verify:source-state-digest:self-test",
    "client:verify:linux-tar-resource-bounds:self-test",
    "client:verify:bounded-child-process:self-test",
    "client:verify:android-apk-zip-facts:self-test",
    "client:verify:android-release-toolchain:self-test",
    "client:verify:consumer-verification-manifest:self-test",
    "client:verify:remote-release-assets:self-test",
    "client:verify:update-manifest:self-test",
    "client:verify:release-workflow-binding:self-test",
    "client:verify:macos-distribution:self-test",
    "client:verify:review-signoff:self-test",
    "client:verify:release-target-evidence:self-test",
    "client:verify:release-report-schema:self-test",
    "client:verify:macos-nested-code-bounds:self-test",
    "client:verify:macos-release-artifact:self-test",
    "client:verify:macos-update-preflight:self-test",
    "client:verify:package-client:self-test",
    "client:native:smoke:policy:self-test",
    "client:verify:closure-producer-writer:self-test",
    "client:verify:android-physical-install-launch:self-test",
    "client:verify:secure-mesh-macos-capabilities:self-test",
    "client:install:macos:identity:self-test",
    "client:verify:secure-mesh-linux-node-matrix:self-test",
    "client:cli:vm:self-test",
    "client:verify:artifact-verification-receipts:self-test",
    "client:verify:secure-mesh-capability-model:self-test",
    "client:verify:secure-mesh-trust-ux:self-test",
    "client:verify:secure-mesh-report-redaction:self-test",
    "client:verify:secure-mesh-e2ee-evidence:contract-binding",
    "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test",
    "client:verify:secure-mesh-e2ee-evidence:readiness-self-test",
    "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test",
    "client:verify:client-release-acceptance:self-test",
  ]),
});

export const CLIENT_RELEASE_TARGETS = Object.freeze({
  "macos-arm64": Object.freeze({
    buildJob: "prepare-macos",
    publishJob: "publish-macos",
    artifactName: "licoup-macos",
    installerArtifact: "LicoUp-macos-arm64.dmg",
    updateArtifact: "LicoUp-macos-arm64-update.zip",
    files: Object.freeze([
      "LicoUp-macos-arm64.dmg",
      "LicoUp-macos-arm64.dmg.sha256",
      "LicoUp-macos-arm64-update.zip",
      "LicoUp-macos-arm64-update.zip.sha256",
    ]),
  }),
  "linux-glibc-arm64": Object.freeze({
    buildJob: "build-linux-arm64",
    publishJob: "publish-linux-arm64",
    artifactName: "licoup-linux-arm64",
    files: Object.freeze([
      "LicoUp-linux-arm64.tar.gz",
      "LicoUp-linux-arm64.tar.gz.sha256",
      "LicoUp-linux-arm64.tar.gz.sig",
      "linux-release-verification-key.pem",
    ]),
  }),
  "android-arm64": Object.freeze({
    buildJob: "build-android-arm64",
    publishJob: "publish-android-arm64",
    artifactName: "licoup-android-arm64",
    files: Object.freeze([
      "LicoUp-android-arm64.apk",
      "LicoUp-android-arm64.apk.sha256",
      "lico-github-artifact.pem",
    ]),
  }),
});

export const CLIENT_CI_JOBS = Object.freeze([
  "plan",
  "source",
  "flutter",
  "rust",
  "android",
  "dependencies",
  "release-policy",
  "client-required",
]);

const DEPENDENCY_PATHS = new Set([
  "package.json",
  "package-lock.json",
  "Cargo.toml",
  "Cargo.lock",
  "apps/desktop/pubspec.yaml",
  "apps/desktop/pubspec.lock",
]);

const RELEASE_AUTHORITY_PATHS = new Set([
  ".github/workflows/client-release.yml",
  ".github/workflows/branch-flow.yml",
  ".github/workflows/commit-identity.yml",
  ".github/workflows/lico-auditor-gate.yml",
  "tools/client-release-template.json",
  "tools/client-remote-release-strategies.json",
  "tools/client-release-targets.json",
  "tools/client-version.json",
]);

function normalizePath(value) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error("changed path must be a non-empty repository-relative path");
  }
  const portable = value.replaceAll("\\", "/").replace(/^\.\//u, "");
  if (
    portable.startsWith("/") ||
    portable.startsWith("../") ||
    portable.includes("/../") ||
    /^[A-Za-z]:\//u.test(portable) ||
    /[\0\r\n]/u.test(portable)
  ) {
    throw new Error("changed path must stay inside the repository");
  }
  return portable;
}

function isFlutterPath(file) {
  return (
    file.startsWith("apps/desktop/lib/") ||
    file.startsWith("apps/desktop/test/") ||
    file.startsWith("apps/desktop/integration_test/") ||
    file.startsWith("apps/desktop/assets/") ||
    file === "apps/desktop/analysis_options.yaml" ||
    file === "apps/desktop/pubspec.yaml" ||
    file === "apps/desktop/pubspec.lock"
  );
}

function isRustPath(file) {
  return (
    file === "Cargo.toml" ||
    file === "Cargo.lock" ||
    file === "rust-toolchain.toml" ||
    file.startsWith("crates/")
  );
}

function isAndroidPath(file) {
  return (
    file.startsWith("apps/desktop/android/") ||
    file.startsWith("tools/android-") ||
    file.includes("/android-") ||
    file.includes("/android_")
  );
}

function isReleasePolicyPath(file) {
  return (
    RELEASE_AUTHORITY_PATHS.has(file) ||
    file.startsWith("tools/scripts/client-release") ||
    file.startsWith("tools/scripts/client-pr-preflight") ||
    file.startsWith("tools/scripts/client-auditor-preflight") ||
    file.startsWith("tools/scripts/client-github-release") ||
    file.startsWith("tools/scripts/client-consumer-verification") ||
    file.startsWith("tools/scripts/client-artifact-verification") ||
    file.startsWith("tools/scripts/client-review-signoff") ||
    file.startsWith("tools/scripts/client-source-state-digest") ||
    file.startsWith("tools/scripts/client-bounded-child-process") ||
    file.startsWith("tools/scripts/client-linux-tar") ||
    file.startsWith("tools/scripts/client-macos-") ||
    file.startsWith("tools/scripts/client-android-apk") ||
    file.startsWith("apps/desktop/scripts/build-") ||
    file.startsWith("apps/desktop/scripts/archive-") ||
    file.startsWith("apps/desktop/scripts/package-client")
  );
}

export function classifyClientGatePaths(changedPaths) {
  if (!Array.isArray(changedPaths)) {
    throw new Error("changed paths must be an array");
  }
  const normalized = [...new Set(changedPaths.map(normalizePath))].sort();
  const lanes = {
    source: true,
    flutter: false,
    rust: false,
    android: false,
    dependencies: false,
    "release-policy": false,
  };

  for (const file of normalized) {
    if (isFlutterPath(file)) lanes.flutter = true;
    if (isRustPath(file)) lanes.rust = true;
    if (isAndroidPath(file)) lanes.android = true;
    if (DEPENDENCY_PATHS.has(file)) lanes.dependencies = true;
    if (isReleasePolicyPath(file)) lanes["release-policy"] = true;
  }

  return Object.freeze({
    changedCount: normalized.length,
    lanes: Object.freeze(lanes),
  });
}
