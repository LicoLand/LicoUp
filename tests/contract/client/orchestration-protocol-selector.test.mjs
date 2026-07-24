import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const paths = {
  selector:
    "crates/licoup-native/src/platform/runtime_adapters/protocol_selector.rs",
  adapters: "crates/licoup-native/src/platform/runtime_adapters.rs",
  lane: "crates/licoup-native/src/platform/conversation_lane.rs",
  authRun: "tools/scripts/client-agent-auth-status/run.mjs",
  authProbe: "tools/scripts/client-agent-auth-status/probe.mjs",
  rustAcceptance:
    "crates/licoup-native/src/platform/runtime_adapters/tests/protocol_selector.rs",
  rustRegistration:
    "crates/licoup-native/src/platform/runtime_adapters/tests/mod.rs",
};

const fileBytes = Object.fromEntries(
  await Promise.all(
    Object.entries(paths).map(async ([name, path]) => [name, await readFile(path)]),
  ),
);
const source = Object.fromEntries(
  Object.entries(fileBytes).map(([name, bytes]) => [name, bytes.toString("utf8")]),
);

function rustLexicalTokens(input) {
  const tokens = [];
  let index = 0;
  const skipQuoted = (quoteIndex) => {
    let cursor = quoteIndex + 1;
    while (cursor < input.length) {
      if (input[cursor] === "\\") cursor += 2;
      else if (input[cursor] === '"') return cursor + 1;
      else cursor += 1;
    }
    throw new Error("unterminated_rust_string");
  };

  while (index < input.length) {
    if (/\s/u.test(input[index])) {
      index += 1;
      continue;
    }
    if (input.startsWith("//", index)) {
      const newline = input.indexOf("\n", index + 2);
      index = newline === -1 ? input.length : newline + 1;
      continue;
    }
    if (input.startsWith("/*", index)) {
      let depth = 1;
      index += 2;
      while (index < input.length && depth > 0) {
        if (input.startsWith("/*", index)) {
          depth += 1;
          index += 2;
        } else if (input.startsWith("*/", index)) {
          depth -= 1;
          index += 2;
        } else index += 1;
      }
      if (depth !== 0) throw new Error("unterminated_rust_block_comment");
      continue;
    }

    const raw = input.slice(index).match(/^(?:br|r)(#{0,255})"/u);
    if (raw) {
      const terminator = `"${raw[1]}`;
      const end = input.indexOf(terminator, index + raw[0].length);
      if (end === -1) throw new Error("unterminated_rust_raw_string");
      index = end + terminator.length;
      continue;
    }
    if (input[index] === '"' || (input[index] === "b" && input[index + 1] === '"')) {
      index = skipQuoted(input[index] === '"' ? index : index + 1);
      continue;
    }
    if (input[index] === "'") {
      const character = input.slice(index).match(/^'(?:\\.|[^\\'\n])'/u);
      if (character) {
        index += character[0].length;
        continue;
      }
    }

    const identifier = input.slice(index).match(/^[A-Za-z_][A-Za-z0-9_]*/u);
    if (identifier) {
      tokens.push(identifier[0]);
      index += identifier[0].length;
      continue;
    }
    tokens.push(input[index]);
    index += 1;
  }
  return tokens;
}

function topLevelSequenceStarts(tokens, expected) {
  const starts = [];
  let braces = 0;
  let parentheses = 0;
  let brackets = 0;
  for (let index = 0; index < tokens.length; index += 1) {
    const topLevel = braces === 0 && parentheses === 0 && brackets === 0;
    if (
      topLevel
      && expected.every((token, offset) => tokens[index + offset] === token)
    ) starts.push(index);
    if (tokens[index] === "{") braces += 1;
    else if (tokens[index] === "}") braces -= 1;
    else if (tokens[index] === "(") parentheses += 1;
    else if (tokens[index] === ")") parentheses -= 1;
    else if (tokens[index] === "[") brackets += 1;
    else if (tokens[index] === "]") brackets -= 1;
    assert.ok(braces >= 0 && parentheses >= 0 && brackets >= 0, "invalid Rust delimiter nesting");
  }
  assert.equal(braces, 0);
  assert.equal(parentheses, 0);
  assert.equal(brackets, 0);
  return starts;
}

function hasExactActiveTestModuleRegistration(input) {
  const tokens = rustLexicalTokens(input);
  const innerAttributes = topLevelSequenceStarts(tokens, ["#", "!", "["]);
  const declarationStarts = topLevelSequenceStarts(tokens, ["mod", "tests", ";"]);
  const exactStarts = topLevelSequenceStarts(
    tokens,
    ["#", "[", "cfg", "(", "test", ")", "]", "mod", "tests", ";"],
  ).filter((index) => index === 0 || [";", "}"].includes(tokens[index - 1]));
  return innerAttributes.length === 0
    && declarationStarts.length === 1
    && exactStarts.length === 1;
}

test("the complete frozen Rust behavioral oracle and registration are byte-pinned", () => {
  const expected = {
    rustAcceptance:
      "e508cae13006f1f02a4048e3e60ae8b5bad5a8e3d7f0098d1263b0625e1cd7a4",
    rustRegistration:
      "cd3b7113c6599b1488379d4cbf7ad804ae6103b59dbdf43c215010105639b2d3",
  };
  for (const [name, digest] of Object.entries(expected)) {
    const actual = createHash("sha256").update(fileBytes[name]).digest("hex");
    assert.equal(actual, digest, `${name} frozen acceptance bytes changed`);
  }
});

test("the Rust lexical registration scanner rejects every inactive or decoy escape", () => {
  assert.equal(hasExactActiveTestModuleRegistration("#[cfg(test)] mod tests;"), true);
  assert.equal(
    hasExactActiveTestModuleRegistration(
      'const S: &str = r#"#[cfg(test)] mod tests;"#; /* #[cfg(test)] mod tests; */\n#[cfg(test)] mod tests;',
    ),
    true,
  );
  for (const decoy of [
    "// #[cfg(test)] mod tests;",
    'const S: &str = "#[cfg(test)] mod tests;";',
    'const S: &str = r###"#[cfg(test)] mod tests;"###;',
    "#[cfg(any())] mod tests;",
    "#[cfg(any(test))] mod tests;",
    "#[cfg_attr(test, path = \"tests.rs\")] mod tests;",
    "#[cfg(unix)] #[cfg(test)] mod tests;",
    "#![cfg(any())]\n#[cfg(test)] mod tests;",
    "mod tests;",
    "#[cfg(test)] mod tests {}",
    "macro_rules! decoy { () => { #[cfg(test)] mod tests; } }",
    "#[cfg(test)] mod tests; #[cfg(test)] mod tests;",
  ]) {
    assert.equal(hasExactActiveTestModuleRegistration(decoy), false, decoy);
  }
});

test("runtime adapters actively register all byte-pinned protocol selector tests", () => {
  assert.equal(hasExactActiveTestModuleRegistration(source.adapters), true);
  const acceptanceTokens = rustLexicalTokens(source.rustAcceptance);
  const activeTests = topLevelSequenceStarts(
    acceptanceTokens,
    ["#", "[", "test", "]", "fn"],
  );
  assert.equal(activeTests.length, 16);
  assert.match(source.rustRegistration, /^mod protocol_selector;$/mu);
});

function isolatedGovernedLane() {
  const startMarker = "// lico-governed-orchestration:start";
  const endMarker = "// lico-governed-orchestration:end";
  assert.equal(source.lane.split(startMarker).length - 1, 1);
  assert.equal(source.lane.split(endMarker).length - 1, 1);
  const start = source.lane.indexOf(startMarker) + startMarker.length;
  const end = source.lane.indexOf(endMarker);
  assert.ok(start > startMarker.length && end > start);
  return source.lane.slice(start, end);
}

test("the protocol selector is capability-only and cannot execute an adapter", () => {
  for (const symbol of [
    "AuthenticationEvidence",
    "AuthenticationStatus",
    "CapabilityEvidence",
    "CapabilityEvidenceUpdate",
    "CapabilitySnapshot",
    "ProtocolPolicy",
    "PinnedProtocol",
    "project_authentication_evidence",
    "reduce_capability_evidence",
    "select_pinned_protocol",
  ]) {
    assert.match(source.selector, new RegExp(`\\b${symbol}\\b`));
  }

  for (const forbidden of [
    /std::process/i,
    /Command::new/i,
    /_driver::execute/i,
    /send_message\s*\(/i,
    /kimi/i,
    /claude/i,
    /codex/i,
    /frontend/i,
    /backend/i,
    /planner/i,
    /verifier/i,
  ]) {
    assert.doesNotMatch(source.selector, forbidden);
  }
});

test("reduced evidence and its canonical revision cannot be forged through public fields", () => {
  for (const type of ["CapabilityEvidence", "CapabilitySnapshot"]) {
    const match = source.selector.match(
      new RegExp(String.raw`struct\s+${type}\s*\{(.*?)\n\}`, "s"),
    );
    assert.ok(match, `missing closed ${type} definition`);
    assert.doesNotMatch(match[1], /\bpub(?:\([^)]*\))?\s+/);
  }
  for (const symbol of ["mint", "advance", "persisted", "restore"]) {
    assert.match(source.selector, new RegExp(`\\b${symbol}\\b`));
  }
});

test("authentication evidence stays bound to the canonical bounded receipt contract", () => {
  assert.match(source.authRun, /lico\.agent-auth-status\.v1/);
  for (const field of [
    "agentId",
    "probeSupported",
    "authenticationStatus",
    "reasonCode",
  ]) {
    assert.match(source.authProbe, new RegExp(`\\b${field}\\b`));
  }
  assert.match(source.authProbe, /authenticationStatus:\s*"skipped"/);
  assert.match(source.authProbe, /probeSupported:\s*false/);
});

test("the real conversation lane owns pinned dispatch and exact lifecycle controls", () => {
  const governedLane = isolatedGovernedLane();
  for (const symbol of [
    "GovernedConversationAdapter",
    "GovernedConversationRequest",
    "GovernedCoordinatorRequest",
    "dispatch_pinned_attempt",
    "coordinate_governed_attempt",
    "resume_pinned_attempt",
    "cancel_pinned_attempt",
    "cleanup_pinned_attempt",
    "PinnedBindingMismatch",
    "UnknownOutcome",
    "InvalidSemanticEvents",
    "EventLimitExceeded",
  ]) {
    assert.match(governedLane, new RegExp(`\\b${symbol}\\b`));
  }

  assert.match(source.adapters, /mod protocol_selector;/);
  assert.doesNotMatch(source.selector, /nativeSessionId|sessionId|threadId/);
});

test("the isolated governed lane has no vendor, model, role, or direct-driver routing branch", () => {
  const governedLane = isolatedGovernedLane();
  for (const forbidden of [
    /kimi/i,
    /claude/i,
    /codex/i,
    /deepseek/i,
    /frontend/i,
    /backend/i,
    /planner/i,
    /verifier/i,
    /RuntimeAdapter::/,
    /_driver::/,
    /send_message\s*\(/,
    /std::process/,
    /Command::new/,
  ]) {
    assert.doesNotMatch(governedLane, forbidden);
  }
});

test("frozen Rust acceptance proves readiness separation, configurability, and no fallback", () => {
  for (const oracle of [
    "CapabilityEvidenceUpdate::Installed(false)",
    "CapabilityEvidenceUpdate::Executable(false)",
    "AuthenticationEvidence::Supported(false)",
    "AuthenticationEvidence::Unsupported",
    "AuthenticationStatus::Skipped",
    "InvalidAuthenticationProjection",
    "allow_skipped_authentication",
    "native_only_policy.allow_acp = false",
    "CapabilityEvidenceUpdate::ProtocolCapable(false)",
    "CapabilityEvidenceUpdate::SendReady(false)",
    "fallback.dispatches, 0",
    "adapter.dispatches, 0",
    "different-session",
    "different-driver",
    "different-revision",
    "different-executable",
    "InvalidOpaqueBinding",
    "CapabilityRevisionMismatch",
    "sha256:forged-caller-revision",
    "coordinate_governed_attempt",
    "secondary.dispatches, 0",
    "DispatchDisposition::Unknown",
    "ResumeCapabilityContext",
    "current_policy: &changed_policy",
    "rejected_adapter.dispatches, 0",
    "SensitiveEvidenceRejected",
    "raw-provider-output-canary",
    "native-session-id-canary",
    "max_events: 2",
  ]) {
    assert.ok(
      source.rustAcceptance.includes(oracle),
      `missing frozen behavioral oracle: ${oracle}`,
    );
  }

  // Vendor examples are deliberately confined to synthetic acceptance data.
  assert.match(source.rustAcceptance, /"kimi-code"/);
  assert.match(source.rustAcceptance, /"claude-code"/);
  assert.match(source.rustAcceptance, /"alternate-agent"/);
});

test("governed dispatch contracts expose opaque evidence, never raw content fields", () => {
  const governedSource = `${source.selector}\n${source.lane}`;
  for (const required of [
    "artifact_handle",
    "digest",
    "driver_id",
    "executable_binding",
    "capability_revision",
  ]) {
    assert.match(governedSource, new RegExp(`\\b${required}\\b`));
  }

  for (const forbidden of [
    /\braw_prompt\s*:/i,
    /\braw_output\s*:/i,
    /\bcredential\s*:/i,
    /\baccount_id\s*:/i,
    /\bprivate_path\s*:/i,
  ]) {
    assert.doesNotMatch(governedSource, forbidden);
  }
});
