import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

const productionRoots = Object.freeze([
  ["crates/licoup-native/src", ".rs"],
  ["apps/desktop/lib", ".dart"],
  ["apps/desktop/android/app/src/main", ".kt"],
  ["apps/desktop/ios/Runner", ".swift"],
]);

const networkTokensByExtension = Object.freeze({
  ".rs": ["ureq::", "reqwest::", "TcpStream", "UdpSocket"],
  ".dart": ["HttpClient", "WebSocket.connect", "package:http", "package:dio"],
  ".kt": ["HttpURLConnection", "OkHttpClient", "java.net.URL", "java.net.Socket"],
  ".swift": ["URLSession", "NWConnection", "URLSessionWebSocketTask"],
});

const reviewedEgressFiles = Object.freeze([
  "apps/desktop/lib/src/backend/features/settings/services/client_update_service.dart",
  "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/probe.rs",
  "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/shutdown.rs",
  "crates/licoup-native/src/domain/collaboration_plugin/source.rs",
  "crates/licoup-native/src/domain/lico_agent/transport.rs",
  "crates/licoup-native/src/domain/provider_model_pricing.rs",
  "crates/licoup-native/src/domain/skill_hub/source.rs",
  "crates/licoup-native/src/platform/badtower_station/http_io.rs",
  "crates/licoup-native/src/platform/llm_gateway_server.rs",
  "crates/licoup-native/src/platform/llm_gateway_service.rs",
  "crates/licoup-native/src/platform/llm_gateway_transport.rs",
  "crates/licoup-native/src/platform/local_service/http.rs",
  "crates/licoup-native/src/platform/local_service/sse.rs",
  "crates/licoup-native/src/platform/mcp_streamable_http.rs",
]);

async function sourceFiles(relativeRoot, extension) {
  const discovered = [];
  async function visit(relativeDirectory) {
    const entries = await fs.readdir(path.join(repoRoot, relativeDirectory), {
      withFileTypes: true,
    });
    for (const entry of entries) {
      const relativePath = path.posix.join(relativeDirectory, entry.name);
      if (entry.isDirectory()) {
        await visit(relativePath);
      } else if (entry.isFile() && entry.name.endsWith(extension)) {
        discovered.push(relativePath);
      }
    }
  }
  await visit(relativeRoot);
  return discovered.sort();
}

async function networkCapableSources() {
  const matches = [];
  for (const [relativeRoot, extension] of productionRoots) {
    const tokens = networkTokensByExtension[extension];
    for (const relativePath of await sourceFiles(relativeRoot, extension)) {
      if (relativePath.includes("/tests/")) continue;
      const source = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
      if (tokens.some((token) => source.includes(token))) matches.push(relativePath);
    }
  }
  return matches.sort();
}

test("production network capability stays inside the reviewed client egress boundary", async () => {
  assert.deepEqual(await networkCapableSources(), reviewedEgressFiles);
});

test("GitHub package fetchers are bounded inbound GET-only sources", async () => {
  const githubFetchers = [
    "crates/licoup-native/src/domain/collaboration_plugin/source.rs",
    "crates/licoup-native/src/domain/skill_hub/source.rs",
  ];
  for (const relativePath of githubFetchers) {
    const source = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
    assert.match(source, /Url::parse\("https:\/\/api\.github\.com"\)/u);
    assert.match(source, /\.get\(archive_url\.as_str\(\)\)/u);
    assert.match(source, /api\.github\.com.*github\.com.*codeload\.github\.com/su);
    for (const forbidden of [".post(", ".send_json(", 'set("Authorization"']) {
      assert.equal(source.includes(forbidden), false, `${relativePath} contains ${forbidden}`);
    }
  }
});

test("client updates are bounded to the signed LicoUp GitHub release channel", async () => {
  const relativePath =
    "apps/desktop/lib/src/backend/features/settings/services/client_update_service.dart";
  const source = await fs.readFile(path.join(repoRoot, relativePath), "utf8");

  assert.match(
    source,
    /https:\/\/github\.com\/LicoLand\/LicoUp\/releases\/latest\/download\/LicoUp-update-stable\.json/u,
  );
  assert.match(source, /static const _maxMetadataBytes = 1024 \* 1024;/u);
  assert.match(source, /static const _maxArtifactBytes = 1024 \* 1024 \* 1024;/u);
  assert.match(source, /http\.Request\('GET', uri\)/u);
  assert.match(source, /_requireGitHubReleaseAsset\(uri\)/u);
  assert.match(source, /uri\.host != 'github\.com'/u);
  assert.match(source, /\/LicoLand\/LicoUp\/releases\/download\//u);
  assert.match(source, /LicoUp-macos-arm64-update\.tar\.gz/u);
  for (const forbidden of ["http.post", "http.put", "http.patch", "'Authorization'"]) {
    assert.equal(source.includes(forbidden), false, `${relativePath} contains ${forbidden}`);
  }
});

test("local assembly runtime networking is synthetic loopback inspection only", async () => {
  const applyPath =
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/apply.rs";
  const probePath =
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/probe.rs";
  const shutdownPath =
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/shutdown.rs";
  const sandboxPath =
    "crates/licoup-native/src/platform/process_sandbox/seatbelt.rs";
  const [apply, probe, shutdown, sandbox] = await Promise.all(
    [applyPath, probePath, shutdownPath, sandboxPath].map((relativePath) =>
      fs.readFile(path.join(repoRoot, relativePath), "utf8"),
    ),
  );

  assert.match(apply, /TcpListener::bind\(\("127\.0\.0\.1", 0\)\)/u);
  assert.match(apply, /TcpListener::bind\(\("127\.0\.0\.1", port\)\)/u);
  assert.match(apply, /"runtimeCapability": super::runtime::SANDBOX_CAPABILITY/u);

  assert.match(probe, /get_json\(record\.port, "\/health"\)/u);
  assert.match(probe, /get_json\(record\.port, "\/v1\/capabilities"\)/u);
  assert.match(probe, /SocketAddr::from\(\(\[127, 0, 0, 1\], port\)\)/u);
  assert.match(probe, /GET \{path\} HTTP\/1\.1/u);
  assert.match(probe, /"assemblyManifestDigestSha256"/u);
  assert.match(probe, /"runtimePid"/u);

  assert.match(shutdown, /SocketAddr::from\(\(\[127, 0, 0, 1\], record\.port\)\)/u);
  assert.match(shutdown, /POST \/v1\/shutdown HTTP\/1\.1/u);
  assert.match(shutdown, /"assemblyManifestDigestSha256"/u);
  assert.match(shutdown, /TcpListener::bind\(\("127\.0\.0\.1", 0\)\)/u);

  assert.match(sandbox, /"platform-loopback-isolated-runtime-v1"/u);
  assert.match(sandbox, /allow network-bind \(local tcp \\"localhost:\{port\}\\"\)/u);
  assert.match(sandbox, /allow network-inbound \(local tcp \\"localhost:\{port\}\\"\)/u);
  const runtimeLeaves = [
    [applyPath, apply],
    [probePath, probe],
    [shutdownPath, shutdown],
    [sandboxPath, sandbox],
  ];
  for (const forbidden of [
    'params.get("url")',
    'params.get("remoteAddress")',
    'params.get("upload")',
    'TcpListener::bind(("0.0.0.0"',
    "Url::parse",
    "reqwest::",
    "ureq::",
    "UdpSocket",
    ".post(",
    "upload_file",
  ]) {
    for (const [relativePath, source] of runtimeLeaves) {
      assert.equal(source.includes(forbidden), false, `${relativePath} contains ${forbidden}`);
    }
  }
});

test("MCP HTTP egress is reachable only through an exact one-shot direct approval", async () => {
  const approval = await fs.readFile(
    path.join(repoRoot, "crates/licoup-native/src/domain/mcp_adapter/approval.rs"),
    "utf8",
  );
  const execution = await fs.readFile(
    path.join(repoRoot, "crates/licoup-native/src/domain/mcp_adapter/execution.rs"),
    "utf8",
  );
  const command = await fs.readFile(
    path.join(repoRoot, "crates/licoup-native/src/ffi/commands/mcp.rs"),
    "utf8",
  );
  const transport = await fs.readFile(
    path.join(repoRoot, "crates/licoup-native/src/platform/mcp_streamable_http.rs"),
    "utf8",
  );

  assert.match(approval, /Some\("direct-user"\)/u);
  assert.match(approval, /Some\(true\)/u);
  assert.match(approval, /supplied\.eq_ignore_ascii_case\(&scope\.approval_digest\)/u);
  assert.match(execution, /require_direct_confirmation\(params, &scope\)\?/u);
  assert.match(execution, /let planned_digest = plans\.claim\(plan_id\)\?/u);
  assert.match(execution, /planned_digest == scope\.approval_digest/u);
  assert.match(command, /execute_http_transfer\(&params, &plans/u);
  assert.match(command, /mcp_streamable_http::exchange\(packet, session_id\)/u);
  assert.equal(transport.includes("direct-user"), false);
  assert.equal(transport.includes("approvalDigest"), false);
});
