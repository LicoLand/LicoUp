import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  IdentityPolicyError,
  assertCommitMessage,
  assertCommitRecord,
  canonicalGitHubEmail,
  parseGitHubIdentity,
} from "../../../tools/scripts/repository-identity-policy.mjs";
import {
  allBranchesRulesetName,
  assertReleaseDefaultBranch,
  buildRulesets,
  identityStatusContext,
  promotionRulesetNames,
  promotionRequiredStatusContexts,
} from "../../../tools/scripts/repository-rulesets.mjs";

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

test("commit identity must match the authenticated developer exactly", () => {
  assert.doesNotThrow(() => assertCommitRecord(validRecord(), identity));
  rejectsWithCode(
    () => assertCommitRecord(validRecord({ authorName: "cursor-agent" }), identity),
    "AUTHOR_IDENTITY_MISMATCH",
  );
  rejectsWithCode(
    () => assertCommitRecord(validRecord({ committerEmail: "bot@example.invalid" }), identity),
    "COMMITTER_IDENTITY_MISMATCH",
  );
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

test("release remains the required default branch", () => {
  assert.doesNotThrow(() => assertReleaseDefaultBranch({ default_branch: "release" }));
  assert.throws(() => assertReleaseDefaultBranch({ default_branch: "nightly" }),
    (error) => error?.code === "DEFAULT_BRANCH_INVALID");
  const source = readFileSync(path.resolve("tools/scripts/repository-rulesets.mjs"), "utf8");
  assert.doesNotMatch(source, /default_branch=/u);
  assert.doesNotMatch(source, /--default-branch/u);
  assert.doesNotMatch(source, /["']PATCH["']/u);
});

test("branch-scoped Rulesets cover identity and each promotion gate without bypass", () => {
  const integrationId = 15368;
  const rulesets = buildRulesets(integrationId);
  const releaseTemplate = JSON.parse(readFileSync(
    path.resolve("tools/client-release-template.json"),
    "utf8",
  ));
  assert.deepEqual(releaseTemplate.requiredPullRequestChecks,
    promotionRequiredStatusContexts);
  assert.equal(rulesets.length, 4);
  assert.deepEqual(
    rulesets.map(({ name }) => name),
    [allBranchesRulesetName, ...Object.values(promotionRulesetNames)],
  );
  for (const ruleset of rulesets) {
    assert.equal(ruleset.enforcement, "active");
    assert.deepEqual(ruleset.bypass_actors, []);
  }

  const [identityRuleset, ...promotionRulesets] = rulesets;
  assert.deepEqual(identityRuleset.conditions.ref_name.include, ["~ALL"]);
  assert.ok(identityRuleset.rules.some(({ type }) => type === "commit_author_email_pattern"));
  const committerRule = identityRuleset.rules.find(
    ({ type }) => type === "committer_email_pattern",
  );
  const committerPattern = new RegExp(committerRule.parameters.pattern);
  assert.equal(committerPattern.test("123+developer@users.noreply.github.com"), true);
  assert.equal(committerPattern.test("noreply@github.com"), true);
  assert.equal(committerPattern.test("bot@example.invalid"), false);
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
});
