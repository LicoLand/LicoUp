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
  boundedIdentityRead,
  canonicalGitHubEmail,
  isAgentIdentity,
  outgoingCommits,
  outgoingObjectChecks,
  parseRawDiffEntries,
  parseGitHubIdentity,
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

test("identity reads retry only their bounded read operation", () => {
  let attempts = 0;
  assert.equal(boundedIdentityRead(() => {
    attempts += 1;
    if (attempts < 2) throw new Error("transient");
    return "ready";
  }), "ready");
  assert.equal(attempts, 2);
});
import {
  allBranchesRulesetName,
  assertReleaseDefaultBranch,
  buildRulesets,
  boundedRead,
  identityStatusContext,
  planRulesetApply,
  promotionRulesetNames,
  promotionRequiredStatusContexts,
  pushRulesetCapability,
  sensitivePublicationRulesetName,
} from "../../../tools/scripts/repository-rulesets.mjs";

test("Ruleset reads retry transient failures without retrying mutations", () => {
  let attempts = 0;
  assert.equal(boundedRead(() => {
    attempts += 1;
    if (attempts < 3) throw new Error("transient");
    return "ready";
  }), "ready");
  assert.equal(attempts, 3);
  assert.throws(() => boundedRead(() => { throw new Error("persistent"); }, 2));
});

const identity = Object.freeze({ login: "human-developer", id: "123456" });

function validRecord(overrides = {}) {
  return {
    authorName: identity.login,
    authorEmail: canonicalGitHubEmail(identity),
    committerName: identity.login,
    committerEmail: canonicalGitHubEmail(identity),
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

test("GitHub identity parser accepts only a canonical login and numeric account ID", () => {
  assert.deepEqual(parseGitHubIdentity("human-developer\t123456"), identity);
  rejectsWithCode(() => parseGitHubIdentity("Agent Name\tnot-numeric"), "GH_IDENTITY_INVALID");
});

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

test("branch-scoped Rulesets cover identity, every promotion edge, and push publication", () => {
  const integrationId = 15368;
  const rulesets = buildRulesets(integrationId);
  assert.equal(rulesets.length, 5);
  assert.deepEqual(
    rulesets.map(({ name }) => name),
    [
      allBranchesRulesetName,
      ...Object.values(promotionRulesetNames),
      sensitivePublicationRulesetName,
    ],
  );
  for (const ruleset of rulesets) {
    assert.equal(ruleset.enforcement, "active");
    assert.deepEqual(ruleset.bypass_actors, []);
  }

  const [identityRuleset, ...rest] = rulesets;
  const promotionRulesets = rest.slice(0, 3);
  const pushRuleset = rest.at(-1);
  assert.deepEqual(identityRuleset.conditions.ref_name.include, ["~ALL"]);
  assert.ok(identityRuleset.rules.some(({ type }) => type === "commit_author_email_pattern"));
  const authorRule = identityRuleset.rules.find(
    ({ type }) => type === "commit_author_email_pattern",
  );
  const committerRule = identityRuleset.rules.find(
    ({ type }) => type === "committer_email_pattern",
  );
  for (const rule of [authorRule, committerRule]) {
    assert.equal(rule.parameters.negate, true);
    const pattern = new RegExp(rule.parameters.pattern.replace(/^\(\?i\)/u, ""), "iu");
    assert.equal(pattern.test("123+developer@users.noreply.github.com"), false);
    assert.equal(pattern.test("legacy-human@example.invalid"), false);
    assert.equal(pattern.test("cursor-agent@example.invalid"), true);
    assert.equal(pattern.test("service[bot]@users.noreply.github.com"), true);
  }
  assert.equal(
    identityRuleset.rules.filter(({ type }) => type === "commit_message_pattern").length,
    1,
  );
  const messageRule = identityRuleset.rules.find(
    ({ type }) => type === "commit_message_pattern",
  );
  assert.match(messageRule.parameters.pattern, /co-authored-by/u);
  assert.match(messageRule.parameters.pattern, /cursor/u);

  assert.equal(identityStatusContext, "Commit identity");
  for (const [index, branch] of ["nightly", "stable", "release"].entries()) {
    const promotionRuleset = promotionRulesets[index];
    for (const requiredType of [
      "deletion", "non_fast_forward", "pull_request", "required_status_checks",
    ]) {
      assert.ok(promotionRuleset.rules.some(({ type }) => type === requiredType));
    }
    const statusRule = promotionRuleset.rules.find(
      ({ type }) => type === "required_status_checks",
    );
    assert.deepEqual(statusRule.parameters.required_status_checks,
      promotionRequiredStatusContexts[branch]
        .map((context) => ({ context, integration_id: integrationId })));
    assert.deepEqual(promotionRuleset.conditions.ref_name.include,
      [`refs/heads/${branch}`]);
  }

  assert.equal(pushRuleset.target, "push");
  assert.equal(Object.hasOwn(pushRuleset, "conditions"), false);
  const extensionRule = pushRuleset.rules.find(
    ({ type }) => type === "file_extension_restriction",
  );
  assert.ok(extensionRule);
  assert.deepEqual(extensionRule.parameters, {
    restricted_file_extensions: sensitiveRulesetExtensions(),
  });
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

test("push Ruleset capability requires an internal/private Team or Enterprise repository", () => {
  assert.equal(pushRulesetCapability({ visibility: "public", plan: { name: "free" } }), false);
  assert.equal(pushRulesetCapability({ visibility: "private", plan: { name: "free" } }), false);
  assert.equal(pushRulesetCapability({ visibility: "private", plan: { name: "team" } }), true);
  assert.equal(pushRulesetCapability({ visibility: "private", plan: { name: "enterprise" } }), true);
  assert.equal(pushRulesetCapability({ visibility: "internal", plan: { name: "Team" } }), true);
  assert.equal(pushRulesetCapability({ visibility: "private" }), false);
  assert.equal(pushRulesetCapability(null), false);
});

test("unsupported public push target still plans branch authorities", () => {
  const plan = planRulesetApply({ visibility: "public", plan: { name: "free" } }, 15368);
  assert.equal(plan.status, "branch-only");
  assert.equal(plan.code, "PUSH_RULESET_UNSUPPORTED");
  assert.deepEqual(plan.desired.map(({ name }) => name),
    [allBranchesRulesetName, ...Object.values(promotionRulesetNames)]);
  assert.ok(plan.desired.every(({ target }) => target === "branch"));
});

test("supported push target plans all five Rulesets in deterministic order", () => {
  const calls = [];
  const recorder = { apply(payload) { calls.push(payload.name); } };
  for (const planName of ["team", "enterprise"]) {
    const plan = planRulesetApply({ visibility: "private", plan: { name: planName } }, 15368);
    assert.equal(plan.status, "supported");
    assert.deepEqual(plan.desired.map(({ name }) => name),
      [
        allBranchesRulesetName,
        ...Object.values(promotionRulesetNames),
        sensitivePublicationRulesetName,
      ]);
    assert.deepEqual(plan.desired.slice(0, 4).map(({ target }) => target),
      ["branch", "branch", "branch", "branch"]);
    assert.equal(plan.desired[4].target, "push");
    assert.deepEqual(plan.desired[4].bypass_actors, []);
    for (const payload of plan.desired) recorder.apply(payload);
  }
  assert.equal(calls.length, 10);
});

test("release remains the required default branch", () => {
  assert.doesNotThrow(() => assertReleaseDefaultBranch({ default_branch: "release" }));
  assert.throws(() => assertReleaseDefaultBranch({ default_branch: "nightly" }),
    (error) => error?.code === "DEFAULT_BRANCH_INVALID");
  const source = readFileSync(path.resolve("tools/scripts/repository-rulesets.mjs"), "utf8");
  assert.doesNotMatch(source, /default_branch=/u);
  assert.doesNotMatch(source, /--default-branch/u);
  assert.doesNotMatch(source, /["']PATCH["']/u);
});
