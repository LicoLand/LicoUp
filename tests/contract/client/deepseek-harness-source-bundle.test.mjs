import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The process half of the DeepSeek Harness driver, still composed by the client
// and named as that client-execution remainder.
const driverPath = "crates/licoup-native/src/platform/deepseek_harness_driver.rs";
// The wire half and the session-log reader, owned by the DeepSeek adapter
// package since DEEPSEEK-PACKAGE moved them out of the kernel. One package
// carries one Agent's protocol; the client names the package for its vocabulary
// instead of keeping a second copy.
const packageRoot = "crates/licoup-agent-deepseek/src";
const packageLeaves = Object.freeze([
  "lib.rs",
  "parser.rs",
  "registration.rs",
  "replay.rs",
  "session_store.rs",
  "port/mod.rs",
  "port/usage.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function packageSources() {
  return Object.fromEntries(await Promise.all(
    packageLeaves.map(async (leaf) => [leaf, await read(`${packageRoot}/${leaf}`)]),
  ));
}

test("the client keeps a thin Harness process half and names the package for the protocol", async () => {
  const driver = await read(driverPath);
  // The protocol vocabulary is read from the package rather than declared here:
  // one Agent, one copy.
  assert.ok(driver.includes("licoup_agent_deepseek::parser"));
  for (const implementationToken of [
    "struct FrameParser",
    "struct TurnParser",
    "fn initialize_request",
    "fn prompt_request",
    "fn shutdown_request",
    "fn assistant_response",
    // The protocol and the reader may not be re-declared beside the package
    // that owns them: either would be a second copy.
    "mod deepseek_harness",
    "deepseek_reader.mjs",
    "include_str!",
  ]) {
    assert.equal(driver.includes(implementationToken), false, implementationToken);
  }
});

test("the Harness protocol, its session-log reader, and its registration have single owners", async () => {
  const sources = await packageSources();
  const parser = sources["parser.rs"];
  const reader = sources["session_store.rs"];
  const registration = sources["registration.rs"];

  // Framing, request builders and turn attribution are the package's own.
  assert.ok(parser.includes('AdapterContract::new("deepseek-harness", "lf-jsonl-jsonrpc")'));
  assert.ok(parser.includes("fn parse_line"));
  assert.ok(parser.includes("fn initialize_request"));
  assert.ok(parser.includes("fn prompt_request"));
  assert.ok(parser.includes("fn shutdown_request"));
  assert.ok(parser.includes("fn take_completed_messages"));
  assert.ok(parser.includes("agent/inbox/spliced"));
  assert.ok(parser.includes("session.status"));
  assert.ok(parser.includes("assistant/message"));

  // The registration composition reads is this package's own, and it answers the
  // SDK's declared queries rather than leaving them to a second owner.
  assert.ok(registration.includes('pub const ADAPTER_ID: &str = "deepseek-harness"'));
  assert.ok(registration.includes('pub const FRAMING: &str = "lf-jsonl-jsonrpc"'));
  assert.ok(registration.includes("ParserRegistration::unanswered(CONTRACT)"));

  // The session-log reader implements the generation it declares and refuses any
  // other by name, so an unread generation can never be folded as if it were
  // this one.
  assert.ok(reader.includes("pub const CURRENT_FORMAT_VERSION: u64 = 4"));
  assert.ok(reader.includes("SessionReadError::UnsupportedFormatVersion"));
  assert.ok(reader.includes('"request/header"'));
  assert.ok(reader.includes('"llm/retry-started"'));
  assert.ok(reader.includes('"assistant/message"'));
  assert.ok(reader.includes('"assistant/attempt"'));
  assert.ok(reader.includes("inheritedEventCount"));
  assert.ok(reader.includes("zstd::stream::read::Decoder"));

  // The package owns the protocol and no part of the client: a client path in
  // the package's sources would be the kernel reaching back in through it. The
  // boundary claim a doc comment states may *name* the client crate it refuses;
  // a code path may not cross into it.
  const joined = Object.values(sources)
    .join("\n")
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("//"))
    .join("\n");
  for (const clientPath of ["crate::platform", "licoup_native", "licoup_native::"]) {
    assert.equal(joined.includes(clientPath), false, clientPath);
  }
  // No Node worker is started for the session log any more, and no vendor
  // library is resolved at run time.
  for (const retiredWorker of [
    "Command::new",
    "createRequire",
    "@deepseek-ai/dsh-session-persistence-jsonl",
    "find_binary",
  ]) {
    assert.equal(joined.includes(retiredWorker), false, retiredWorker);
  }
});

test("the package declares its external dependency instead of hiding it", async () => {
  const manifest = JSON.parse(await read("crates/licoup-agent-deepseek/package/manifest.json"));
  const release = JSON.parse(
    await read("crates/licoup-agent-deepseek/package/package-release.json"),
  );
  // The vendor artifact the reader reads is named as an external dependency, and
  // the package states that it owns no persisted data of its own.
  assert.equal(manifest.extensions["org.licoland.adapter.deepseek/persistentData"], "none");
  assert.ok(manifest.extensions["org.licoland.adapter.deepseek/persistentDataReason"]);
  assert.match(
    manifest.extensions["org.licoland.adapter.deepseek/externalDependency"],
    /DeepSeek Harness/,
  );
  // The declared converter is the native entry, so no Node runtime is required
  // to read the vendor artifact.
  assert.equal(release.converter.kind, "native-executable");
  assert.equal(release.converter.entry, manifest.runtime.entry);
  assert.equal(release.converter.entry, "bin/lico-agent-deepseek");
  assert.equal(release.converter.sourceFormat, "deepseek-harness-session-jsonl");
});
