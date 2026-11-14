import assert from "node:assert/strict";
import test from "node:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  IdentityPolicyError,
  assertCommitMessage,
  assertCommitRecord,
  commandSucceeds,
  isAgentIdentity,
  isMergeInProgress,
  isSupportedDispatcherChain,
  managedPolicyDrift,
  managedPolicyPaths,
  outgoingCommits,
  outgoingObjectChecks,
  parseRawDiffEntries,
  shouldRejectEmptyStagedCandidate,
  stagedObjectChecks,
} from "../../../tools/scripts/repository-identity-policy.mjs";
import {
  SENSITIVE_CONTENT_REASON,
  SENSITIVE_EXTENSION_REASON,
  SensitiveContentScanner,
  classifyPath,
  normalizeSensitivePath,
  sensitiveRulesetExtensions,
  sensitiveExtensions,
} from "../../../tools/scripts/lib/repository-sensitive-file-policy.mjs";

function validRecord(overrides = {}) {
  return {
    authorName: "human-developer",
    authorEmail: "human-developer@example.invalid",
    committerName: "human-developer",
    committerEmail: "human-developer@example.invalid",
    message: "Add repository identity policy",
    ...overrides,
  };
}

function rejectsWithCode(operation, code) {
  assert.throws(
    operation,
    (error) => error instanceof IdentityPolicyError && error.code === code,
  );
}

test("commit history preserves human identities and rejects Agent attribution", () => {
  assert.doesNotThrow(() => assertCommitRecord(validRecord()));
  assert.doesNotThrow(() => assertCommitRecord(validRecord({
    authorName: "Legacy Human",
    authorEmail: "legacy-human@example.invalid",
    committerName: "Another Human",
    committerEmail: "another-human@example.invalid",
  })));
  rejectsWithCode(
    () => assertCommitRecord(validRecord({ authorName: "cursor-agent" })),
    "AGENT_AUTHOR_IDENTITY_FORBIDDEN",
  );
  rejectsWithCode(
    () => assertCommitRecord(validRecord({ committerEmail: "service[bot]@users.noreply.github.com" })),
    "AGENT_COMMITTER_IDENTITY_FORBIDDEN",
  );
  assert.equal(isAgentIdentity("Robotics Maintainer", "human@example.invalid"), false);
  assert.equal(isAgentIdentity("GitHub Actions", "service[bot]@users.noreply.github.com"), true);
});

test("all attribution trailers are rejected, including Agent co-authorship", () => {
  for (const trailer of [
    "Co-authored-by: Cursor Agent <cursor@example.invalid>",
    "Signed-off-by: Claude Code <claude@example.invalid>",
    "Generated-by: automation <bot@example.invalid>",
    "Reviewed-by: Another Person <person@example.invalid>",
  ]) {
    rejectsWithCode(
      () => assertCommitMessage(`Implement feature\n\n${trailer}`),
      "ATTRIBUTION_TRAILER_FORBIDDEN",
    );
  }
});

test("identity-shaped Agent lines are rejected without banning product discussion", () => {
  rejectsWithCode(
    () => assertCommitMessage("Implement feature\n\nCursor Agent <cursor@example.invalid>"),
    "AGENT_IDENTITY_FORBIDDEN",
  );
  assert.doesNotThrow(() =>
    assertCommitMessage("Improve the Cursor and Claude Code conversation adapters"),
  );
});

test("pull request identity workflow requires a User or verified GitHub merge service", () => {
  const workflow = readFileSync(".github/workflows/commit-identity.yml", "utf8");
  assert.doesNotMatch(workflow, /EXPECTED_LOGIN|expected_email/u);
  assert.match(workflow, /\.type \/\/ ""\) == "User"/u);
  assert.match(workflow, /login \/\/ ""\) == "web-flow"/u);
  assert.match(workflow, /\.commit\.verification\.verified == true/u);
  assert.match(workflow, /has_agent_identity/u);
  assert.match(workflow, /has_forbidden_attribution/u);
});

test("ignore defense mirrors every canonical sensitive suffix", () => {
  const ignored = new Set(readFileSync(".gitignore", "utf8").split(/\r?\n/u));
  for (const extension of sensitiveExtensions) {
    assert.equal(ignored.has(`*${extension}`), true, extension);
  }
  assert.equal(ignored.has("*.certSigningRequest"), true);
});

const zeroOid = "0000000000000000000000000000000000000000";
const oidA = "a".repeat(40);
const oidB = "b".repeat(40);

function pemCertificate() {
  const boundary = (kind, label) => `${"---" + "--"}${kind} ${label}${"---" + "--"}`;
  return [
    boundary("BEGIN", "CERTIFICATE"),
    "MIIB3zCCAYWgAwIBAgIUQ7kU0x9yqK0kZ8mXzY1nYq7XbA0wDQYJKoZIhvcN",
    "AQELBQAwUjELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExFDAS",
    "BgNVBAcMC1NhbiBGcmFuY2lzY28xGDAWBgNVBAoMD0V4YW1wbGUgQ29ycC4g",
    "MB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowUjELMAkGA1UEBhMC",
    "VVMxEzARBgNVBAgMCkNhbGlmb3JuaWExFDASBgNVBAcMC1NhbiBGcmFuY2lz",
    "Y28xGDAWBgNVBAoMD0V4YW1wbGUgQ29ycC4gMFwwDQYJKoZIhvcNAQEBBQAD",
    "SwAwSAJBAKv4T0X2yfQp6mX9b0vU7n3hJz0Gp0yQ1qW8XmNcRdEe2QfYdN5",
    "kqO6VvH9rTjM8sLc4ZxB7wFg0iC1nZ3eF5gH6jI8kLmNpOqRsTuVwXyZ0a2",
    boundary("END", "CERTIFICATE"),
    "",
  ].join("\n");
}

function pemPrivateKey() {
  const boundary = (kind, label) => `${"---" + "--"}${kind} ${label}${"---" + "--"}`;
  return [
    boundary("BEGIN", "PRIVATE KEY"),
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDo0vQZx2q8",
    "w3nJm4pR7yT5sK9dE1fG2hI6jL8mN0oP2qR4sT6uV8wX0yZ2a4b6c8d0e1f3g5",
    boundary("END", "PRIVATE KEY"),
    "",
  ].join("\n");
}

function initFixtureRepo() {
  const dir = mkdtempSync(path.join(tmpdir(), "licoup-guard-"));
  const git = (args, options = {}) =>
    execFileSync("git", args, {
      encoding: "utf8",
      cwd: dir,
      stdio: ["pipe", "pipe", "pipe"],
      input: options.input,
    }).trim();
  git(["init", "-q"]);
  git(["config", "user.name", "Guard Regression"]);
  git(["config", "user.email", "guard-regression@example.invalid"]);
  git(["config", "commit.gpgsign", "false"]);
  // The fixture repository must not inherit the host's global hooks: a shared
  // hooksPath would run the host's checkers inside a directory they do not
  // govern and fail the fixture for reasons outside the test.
  git(["config", "core.hooksPath", path.join(dir, ".git", "hooks")]);
  return { dir, git, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("classifyPath rejects every canonical sensitive suffix with normalization", () => {
  assert.equal(sensitiveExtensions.size, 23);
  const alternateSeparator = String.fromCharCode(92);
  for (const extension of sensitiveExtensions) {
    assert.equal(classifyPath(`config/keys/dev${extension}`).verdict, "reject", extension);
    assert.equal(
      classifyPath(["CONFIG", "KEYS", `DEV${extension.toUpperCase()}`]
        .join(alternateSeparator)).verdict,
      "reject",
      extension,
    );
    assert.equal(classifyPath(`config/keys/dev${extension}`).reason,
      SENSITIVE_EXTENSION_REASON);
  }
  for (const publicSuffix of [".pub", ".asc", ".gpg"]) {
    assert.equal(classifyPath(`keys/public${publicSuffix}`).verdict, "pass", publicSuffix);
  }
  assert.equal(classifyPath("src/main.rs").verdict, "pass");
  assert.equal(normalizeSensitivePath("A\\B.PEM"), "a/b.pem");
});

test("sensitiveRulesetExtensions mirror the frozen set as bare extensions", () => {
  const extensions = sensitiveRulesetExtensions();
  assert.equal(extensions.length, sensitiveExtensions.size);
  assert.deepEqual(extensions, [...sensitiveExtensions].map((extension) => extension.slice(1)));
  assert.ok(extensions.every((extension) => !extension.startsWith(".") && !extension.includes("*")));
});

test("content scanner rejects complete PEM blocks and passes safe controls", () => {
  for (const block of [pemCertificate(), pemPrivateKey()]) {
    const scanner = new SensitiveContentScanner();
    assert.equal(scanner.feed(block).verdict, "reject");
    assert.equal(scanner.finish().reason, SENSITIVE_CONTENT_REASON);
  }
  const boundary = (kind, label) => `${"---" + "--"}${kind} ${label}${"---" + "--"}`;
  const controls = [
    "",
    `${boundary("BEGIN", "CERTIFICATE")}\n${boundary("END", "CERTIFICATE")}\n`,
    `const example = '${boundary("BEGIN", "PRIVATE KEY")}'; // documentation only\n`,
    `${boundary("BEGIN", "CERTIFICATE")}\nnot base64 !!! material\n${boundary("END", "CERTIFICATE")}\n`,
    `${boundary("BEGIN", "CERTIFICATE")}\nMIIB...truncated without an end marker\n`,
  ];
  for (const control of controls) {
    const scanner = new SensitiveContentScanner();
    assert.equal(scanner.feed(control).verdict, "pass", JSON.stringify(control.slice(0, 40)));
  }
});

test("content scanner detects markers split across arbitrary chunk boundaries", () => {
  for (const chunkSize of [1, 2, 3, 7, 16, 64]) {
    const scanner = new SensitiveContentScanner();
    const bytes = Buffer.from(pemCertificate(), "utf8");
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      scanner.feed(bytes.subarray(offset, offset + chunkSize));
      if (scanner.result.verdict === "reject") break;
    }
    assert.equal(scanner.finish().verdict, "reject", `chunk size ${chunkSize}`);
  }
});

test("malformed outer blocks cannot hide a complete nested private-key block", () => {
  const boundary = (kind, label) => `${"---" + "--"}${kind} ${label}${"---" + "--"}`;
  const content = [
    boundary("BEGIN", "CERTIFICATE"),
    "invalid!",
    pemPrivateKey(),
    boundary("END", "CERTIFICATE"),
  ].join("\n");
  for (const chunkSize of [1, 5, 31, 128]) {
    const scanner = new SensitiveContentScanner();
    const bytes = Buffer.from(content);
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      scanner.feed(bytes.subarray(offset, offset + chunkSize));
    }
    assert.equal(scanner.finish().verdict, "reject", `chunk size ${chunkSize}`);
  }
});

test("sensitive-file verdicts expose only stable type codes, never candidates", () => {
  const pathVerdict = classifyPath("certs/Apple-Dev.p8");
  assert.deepEqual(Object.keys(pathVerdict), ["verdict", "reason"]);
  assert.equal(pathVerdict.verdict, "reject");
  assert.equal(pathVerdict.reason, SENSITIVE_EXTENSION_REASON);
  const contentVerdict = new SensitiveContentScanner().feed(pemCertificate());
  assert.deepEqual(Object.keys(contentVerdict), ["verdict", "reason"]);
  assert.equal(contentVerdict.reason, SENSITIVE_CONTENT_REASON);
  assert.ok(!JSON.stringify(contentVerdict).includes("CERTIFICATE"));
});

test("staged checks reject sensitive paths before reading and deduplicate objects", () => {
  assert.deepEqual(
    stagedObjectChecks([{ path: "gone.key", status: "D", srcOid: oidA, dstOid: zeroOid }]),
    { status: "pass", readOids: [] },
  );
  const rejected = stagedObjectChecks([
    { path: "config/Apple.p8", status: "A", srcOid: zeroOid, dstOid: oidA },
  ]);
  assert.equal(rejected.status, "reject");
  assert.equal(rejected.code, "SENSITIVE_PATH_STAGED");
  assert.deepEqual(rejected.readOids, []);
  const passed = stagedObjectChecks([
    { path: "src/lib.rs", status: "A", srcOid: zeroOid, dstOid: oidA },
    { path: "src/lib.rs", status: "M", srcOid: oidA, dstOid: oidA },
    { path: "tests/fixture.bin", status: "A", srcOid: zeroOid, dstOid: oidA },
  ]);
  assert.equal(passed.status, "pass");
  assert.deepEqual(passed.readOids, [oidA]);
});

test("outgoing checks reject add-rename-delete history even when the tip is clean", () => {
  const secretPathGraph = [
    { commit: "c1", entries: [
      { path: "config/secrets.pem", status: "A", srcOid: zeroOid, dstOid: oidA },
    ] },
    { commit: "c2", entries: [
      { path: "config/notes.txt", status: "R", srcOid: oidA, dstOid: oidA },
    ] },
    { commit: "c3", entries: [
      { path: "config/notes.txt", status: "D", srcOid: oidA, dstOid: zeroOid },
    ] },
  ];
  const rejected = outgoingObjectChecks(secretPathGraph);
  assert.equal(rejected.status, "reject");
  assert.equal(rejected.code, "SENSITIVE_PATH_OUTGOING");
  assert.deepEqual(rejected.readOids, []);

  const secretContentGraph = [
    { commit: "c1", entries: [
      { path: "blob.bin", status: "A", srcOid: zeroOid, dstOid: oidA },
    ] },
    { commit: "c2", entries: [
      { path: "blob-renamed.bin", status: "R", srcOid: oidA, dstOid: oidA },
    ] },
    { commit: "c3", entries: [
      { path: "blob-renamed.bin", status: "D", srcOid: oidA, dstOid: zeroOid },
    ] },
  ];
  const contentCheck = outgoingObjectChecks(secretContentGraph);
  assert.equal(contentCheck.status, "pass");
  assert.deepEqual(contentCheck.readOids, [oidA]);
  const scanner = new SensitiveContentScanner();
  assert.equal(scanner.feed(pemCertificate()).verdict, "reject");
});

test("outgoing checks pass a clean multi-ref graph and read each object once", () => {
  const result = outgoingObjectChecks([
    { commit: "ref1-1", entries: [
      { path: "a.txt", status: "A", srcOid: zeroOid, dstOid: oidA },
    ] },
    { commit: "ref1-2", entries: [
      { path: "a.txt", status: "M", srcOid: oidA, dstOid: oidB },
    ] },
    { commit: "ref2-1", entries: [
      { path: "b.txt", status: "A", srcOid: zeroOid, dstOid: oidB },
    ] },
  ]);
  assert.equal(result.status, "pass");
  assert.deepEqual(result.readOids, [oidA, oidB]);
});

test("staged gate inspects index objects, not worktree files", () => {
  const fixture = initFixtureRepo();
  try {
    writeFileSync(path.join(fixture.dir, "payload.txt"), pemCertificate());
    fixture.git(["add", "payload.txt"]);
    const indexOid = fixture.git(["rev-parse", ":payload.txt"]);
    assert.match(indexOid, /^[0-9a-f]{40}$/u);
    writeFileSync(path.join(fixture.dir, "payload.txt"), "harmless worktree text\n");
    const raw = fixture.git(
      ["diff", "--cached", "--raw", "-z", "--abbrev=40", "--diff-filter=ACMRTUXB"]);
    const checks = stagedObjectChecks(parseRawDiffEntries(raw));
    assert.equal(checks.status, "pass");
    assert.deepEqual(checks.readOids, [indexOid]);
    const scanner = new SensitiveContentScanner();
    assert.equal(scanner.feed(fixture.git(["cat-file", "blob", indexOid])).verdict, "reject");

    mkdirSync(path.join(fixture.dir, "keys"), { recursive: true });
    writeFileSync(path.join(fixture.dir, "keys", "apple.p8"), "not a real key\n");
    fixture.git(["add", "keys/apple.p8"]);
    const pathCheck = stagedObjectChecks(parseRawDiffEntries(
      fixture.git(["diff", "--cached", "--raw", "-z", "--abbrev=40", "--diff-filter=ACMRTUXB"])));
    assert.equal(pathCheck.status, "reject");
    assert.equal(pathCheck.code, "SENSITIVE_PATH_STAGED");
  } finally {
    fixture.cleanup();
  }
});

test("empty staged candidate is rejected only outside an in-progress merge commit", () => {
  assert.equal(shouldRejectEmptyStagedCandidate(false, false), true);
  assert.equal(shouldRejectEmptyStagedCandidate(false, true), false);
  assert.equal(shouldRejectEmptyStagedCandidate(true, false), false);
  assert.equal(shouldRejectEmptyStagedCandidate(true, true), false);
  const fixture = initFixtureRepo();
  try {
    fixture.git(["commit", "-q", "--allow-empty", "-m", "base"]);
    fixture.git(["checkout", "-q", "-b", "side"]);
    fixture.git(["commit", "-q", "--allow-empty", "-m", "side"]);
    fixture.git(["checkout", "-q", "-"]);
    fixture.git(["merge", "--no-commit", "--no-ff", "-s", "ours", "side"]);
    assert.equal(isMergeInProgress(fixture.dir), true);
    fixture.git(["merge", "--abort"]);
    assert.equal(isMergeInProgress(fixture.dir), false);
  } finally {
    fixture.cleanup();
  }
});

test("outgoing history scan recovers add-rename-delete and rejects the hidden blob", () => {
  const fixture = initFixtureRepo();
  try {
    writeFileSync(path.join(fixture.dir, "data.txt"), pemCertificate());
    fixture.git(["add", "data.txt"]);
    fixture.git(["commit", "-q", "-m", "add payload"]);
    const addCommit = fixture.git(["rev-parse", "HEAD"]);
    fixture.git(["mv", "data.txt", "notes.md"]);
    fixture.git(["commit", "-q", "-m", "rename payload"]);
    const renameCommit = fixture.git(["rev-parse", "HEAD"]);
    fixture.git(["rm", "-q", "notes.md"]);
    fixture.git(["commit", "-q", "-m", "delete payload"]);
    const deleteCommit = fixture.git(["rev-parse", "HEAD"]);
    assert.equal(fixture.git(["ls-files"]), "", "the pushed tip must be clean");
    const records = [addCommit, renameCommit, deleteCommit].map((commit) => ({
      commit,
      entries: parseRawDiffEntries(
        fixture.git(
          ["diff-tree", "-r", "--root", "-m", "-z", "--abbrev=40", "--no-commit-id", commit])),
    }));
    const checks = outgoingObjectChecks(records);
    assert.equal(checks.status, "pass");
    assert.equal(checks.readOids.length, 1, "the introduced blob is read exactly once");
    const scanner = new SensitiveContentScanner();
    assert.equal(
      scanner.feed(fixture.git(["cat-file", "blob", checks.readOids[0]])).verdict,
      "reject",
    );
  } finally {
    fixture.cleanup();
  }
});

test("a new remote ref scans only history not already reachable from that remote", () => {
  const fixture = initFixtureRepo();
  try {
    writeFileSync(path.join(fixture.dir, "old.txt"), "old reachable content\n");
    fixture.git(["add", "old.txt"]);
    fixture.git(["commit", "-q", "-m", "old commit"]);
    const oldCommit = fixture.git(["rev-parse", "HEAD"]);
    fixture.git(["update-ref", "refs/remotes/origin/existing", oldCommit]);
    writeFileSync(path.join(fixture.dir, "new.txt"), "new content\n");
    fixture.git(["add", "new.txt"]);
    fixture.git(["commit", "-q", "-m", "new commit"]);
    const localTip = fixture.git(["rev-parse", "HEAD"]);
    const input = `refs/heads/new ${localTip} refs/heads/new ${zeroOid}\n`;
    const commits = outgoingCommits(input, "origin", (_command, args) => fixture.git(args));
    assert.ok(!commits.includes(oldCommit));
    assert.ok(commits.includes(localTip));
  } finally {
    fixture.cleanup();
  }
});

// The managed-policy check compares each file with the committed revision at HEAD. It must
// never compare with a digest recorded when the policy was installed: that made the gate
// satisfiable only while the checkout stayed on the install-time revision, so a branch
// switch, merge, rebase or pull left the checkout unable to commit anything at all.
// These cases are the guard against reintroducing that behaviour.
test("managed policy drift is read from HEAD, so advancing the revision is not drift", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-identity-drift-"));
  try {
    for (const relativePath of managedPolicyPaths) {
      const absolute = path.join(root, relativePath);
      mkdirSync(path.dirname(absolute), { recursive: true });
      writeFileSync(absolute, "policy revision one\n", { mode: 0o755 });
    }
    const git = (...args) => execFileSync("git", args, { cwd: root, stdio: "pipe" });
    git("init", "-q");
    git("config", "user.name", "policy-fixture");
    git("config", "user.email", "policy-fixture@example.invalid");
    git("config", "commit.gpgsign", "false");
    git("config", "core.hooksPath", path.join(root, ".git", "hooks"));
    git("add", "-A");
    git("commit", "-q", "-m", "policy revision one");
    assert.deepEqual(managedPolicyDrift(root), []);

    // A commit that changes a managed file is a new revision, not local drift.
    for (const relativePath of managedPolicyPaths) {
      writeFileSync(path.join(root, relativePath), "policy revision two\n", { mode: 0o755 });
    }
    git("add", "-A");
    git("commit", "-q", "-m", "policy revision two");
    assert.deepEqual(managedPolicyDrift(root), []);

    // Only an uncommitted local edit to the gate's own tooling is reported.
    writeFileSync(path.join(root, managedPolicyPaths[0]), "locally edited\n", { mode: 0o755 });
    assert.deepEqual(managedPolicyDrift(root), [managedPolicyPaths[0]]);

    // A removed or replaced policy file is reported as well.
    rmSync(path.join(root, managedPolicyPaths[0]));
    writeFileSync(path.join(root, managedPolicyPaths[1]), "another local edit\n", { mode: 0o755 });
    assert.deepEqual(managedPolicyDrift(root), [managedPolicyPaths[0], managedPolicyPaths[1]].sort());
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a supported chain is decided by the verifier's exit status, not its output", () => {
  // The contract is the process result: a silent success is still a pass,
  // and a noisy failure is still a refusal.
  assert.equal(commandSucceeds(process.execPath, ["-e", "process.exit(0)"]), true);
  assert.equal(commandSucceeds(process.execPath, ["-e", "process.exit(1)"]), false);
  assert.equal(commandSucceeds("definitely-not-a-real-command", []), false);
});

test("an unsupported or absent dispatcher chain is never treated as the repository's hooks", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-dispatcher-"));
  try {
    // An inert directory with hook-named entries is not a chain: only the
    // dispatcher's owner can attest the contract, and it does not.
    const inert = path.join(root, "inert");
    mkdirSync(inert, { recursive: true });
    for (const entry of ["_dispatch", "pre-commit", "commit-msg", "pre-push"]) {
      writeFileSync(path.join(inert, entry), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    }
    assert.equal(isSupportedDispatcherChain(inert), false);

    // A hooksPath that does not exist at all is not a chain either.
    assert.equal(isSupportedDispatcherChain(path.join(root, "absent")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
