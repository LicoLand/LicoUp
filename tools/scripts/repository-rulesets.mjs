#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import process from "node:process";
import { pathToFileURL } from "node:url";

const repository = "LicoLand/LicoUp";
const allBranchesRulesetName = "LicoUp commit identity — all branches";
const promotionBranchesRulesetName = "LicoUp protected release flow";
const identityStatusContext = "Commit identity";
const requiredStatusContexts = Object.freeze([
  "Branch flow",
  identityStatusContext,
  "Client required",
  "Auditor",
]);
const githubNoreplyHostPattern = ["users", "noreply", "github", "com"].join("\\.");
const canonicalNoreplyPattern = `^[0-9]+\\+[A-Za-z0-9][A-Za-z0-9-]{0,38}@${githubNoreplyHostPattern}$`;
const canonicalCommitterPattern =
  `(?:${canonicalNoreplyPattern.slice(1, -1)}|noreply@github\\.com)`;
const forbiddenCommitMessagePattern =
  "(?i)(^|\\n)[ \\t]*((co-authored-by|co-committed-by|signed-off-by|authored-by|assisted-by|generated-by|written-by|pair-programmed-by|contributed-by|reviewed-by|suggested-by|reported-by)[ \\t]*:|(claude( code)?|cursor( agent)?|github copilot|copilot|codex|chatgpt|gemini|anthropic|openai|[^\\n<]*(agent|bot))[^\\n]*<[^\\n>]+>)";

class RulesetError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "RulesetError";
    this.code = code;
  }
}

function reject(code, message) {
  throw new RulesetError(code, message);
}

function gh(args, options = {}) {
  try {
    return execFileSync("gh", args, {
      encoding: "utf8",
      stdio: [options.input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
      input: options.input,
    }).trim();
  } catch {
    reject(options.code || "GH_COMMAND_FAILED", options.message || "A GitHub operation failed.");
  }
}

export function boundedRead(operation, attempts = 3) {
  if (typeof operation !== "function" || !Number.isSafeInteger(attempts) || attempts < 1) {
    reject("READ_RETRY_INVALID", "The bounded read retry policy is invalid.");
  }
  let failure;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return operation();
    } catch (error) {
      failure = error;
      if (attempt < attempts) {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, attempt * 250);
      }
    }
  }
  throw failure;
}

function ghRead(args, options = {}) {
  return boundedRead(() => gh(args, options));
}

function ghOptional(args) {
  try {
    return {
      ok: true,
      output: execFileSync("gh", args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }).trim(),
    };
  } catch {
    return { ok: false, output: "" };
  }
}

function metadataRule(type, name, pattern, negate) {
  return {
    type,
    parameters: {
      name,
      negate,
      operator: "regex",
      pattern,
    },
  };
}

function requiredStatusChecksRule(actionsIntegrationId) {
  return {
    type: "required_status_checks",
    parameters: {
      do_not_enforce_on_create: true,
      required_status_checks: requiredStatusContexts.map((context) => ({
        context,
        integration_id: actionsIntegrationId,
      })),
      strict_required_status_checks_policy: true,
    },
  };
}

export function buildRulesets(actionsIntegrationId) {
  if (!Number.isSafeInteger(actionsIntegrationId) || actionsIntegrationId <= 0) {
    reject("ACTIONS_INTEGRATION_INVALID", "The GitHub Actions integration ID is invalid.");
  }
  return [
    {
      name: allBranchesRulesetName,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {
        ref_name: { include: ["~ALL"], exclude: [] },
      },
      rules: [
        metadataRule(
          "commit_author_email_pattern",
          "Author must use a canonical GitHub noreply identity",
          canonicalNoreplyPattern,
          false,
        ),
        metadataRule(
          "committer_email_pattern",
          "Committer must be the developer or GitHub verified merge service",
          `^${canonicalCommitterPattern}$`,
          false,
        ),
        metadataRule(
          "commit_message_pattern",
          "Attribution trailers and Agent-shaped identity lines are forbidden",
          forbiddenCommitMessagePattern,
          true,
        ),
      ],
    },
    {
      name: promotionBranchesRulesetName,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {
        ref_name: {
          include: [
            "refs/heads/nightly",
            "refs/heads/stable",
            "refs/heads/release",
          ],
          exclude: [],
        },
      },
      rules: [
        { type: "deletion" },
        { type: "non_fast_forward" },
        {
          type: "pull_request",
          parameters: {
            allowed_merge_methods: ["merge"],
            dismiss_stale_reviews_on_push: true,
            require_code_owner_review: false,
            require_last_push_approval: false,
            required_approving_review_count: 0,
            required_review_thread_resolution: true,
          },
        },
        requiredStatusChecksRule(actionsIntegrationId),
      ],
    },
  ];
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function rulesetPayloadMatches(actual, expected) {
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return false;
    const consumed = new Set();
    return expected.every((wanted) => {
      const index = actual.findIndex((candidate, candidateIndex) =>
        !consumed.has(candidateIndex) && rulesetPayloadMatches(candidate, wanted));
      if (index < 0) return false;
      consumed.add(index);
      return true;
    });
  }
  if (expected && typeof expected === "object") {
    if (!actual || typeof actual !== "object" || Array.isArray(actual)) return false;
    return Object.entries(expected).every(([key, value]) =>
      Object.hasOwn(actual, key) && rulesetPayloadMatches(actual[key], value));
  }
  return Object.is(actual, expected);
}

function assertRepositoryAccess({ requireAdmin }) {
  ghRead(["api", "user", "--jq", ".login"], {
    code: "GH_AUTH_REQUIRED",
    message: "GitHub CLI authentication is required.",
  });
  let details;
  try {
    details = JSON.parse(
      ghRead(["api", `repos/${repository}`], {
        code: "REPOSITORY_UNAVAILABLE",
        message: "The target repository is unavailable.",
      }),
    );
  } catch (error) {
    if (error instanceof RulesetError) throw error;
    reject("REPOSITORY_RESPONSE_INVALID", "The repository metadata response is invalid.");
  }
  if (details.full_name !== repository) {
    reject("REPOSITORY_RESPONSE_INVALID", "The repository identity does not match policy.");
  }
  if (requireAdmin && details.permissions?.admin !== true) {
    reject(
      "REMOTE_ADMIN_REQUIRED",
      "The authenticated GitHub CLI account needs Administration(write) on the target repository.",
    );
  }
  return details;
}

function actionsIntegrationId() {
  const raw = ghRead(["api", "/apps/github-actions", "--jq", ".id"], {
    code: "ACTIONS_INTEGRATION_UNAVAILABLE",
    message: "The GitHub Actions integration identity could not be resolved.",
  });
  const id = Number(raw);
  if (!Number.isSafeInteger(id) || id <= 0) {
    reject("ACTIONS_INTEGRATION_INVALID", "The GitHub Actions integration ID is invalid.");
  }
  return id;
}

function repositoryRulesets() {
  try {
    const value = JSON.parse(
      ghRead(["api", `repos/${repository}/rulesets?includes_parents=false`], {
        code: "RULESETS_UNAVAILABLE",
        message: "Repository Rulesets could not be listed.",
      }),
    );
    if (!Array.isArray(value)) throw new Error("not an array");
    return value;
  } catch (error) {
    if (error instanceof RulesetError) throw error;
    reject("RULESETS_RESPONSE_INVALID", "The repository Rulesets response is invalid.");
  }
}

function repositoryRuleset(id) {
  if (!Number.isSafeInteger(id) || id <= 0) {
    reject("RULESET_RESPONSE_INVALID", "A repository Ruleset identifier is invalid.");
  }
  try {
    const value = JSON.parse(ghRead(["api", `repos/${repository}/rulesets/${id}`], {
      code: "RULESETS_UNAVAILABLE",
      message: "A repository Ruleset could not be read.",
    }));
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("invalid Ruleset response");
    }
    return value;
  } catch (error) {
    if (error instanceof RulesetError) throw error;
    reject("RULESETS_RESPONSE_INVALID", "A repository Ruleset response is invalid.");
  }
}

function applyRuleset(payload, existing) {
  const endpoint = existing
    ? `repos/${repository}/rulesets/${existing.id}`
    : `repos/${repository}/rulesets`;
  const method = existing ? "PUT" : "POST";
  let result;
  try {
    result = JSON.parse(
      gh(["api", "-X", method, endpoint, "--input", "-"], {
        input: JSON.stringify(payload),
        code: "RULESET_APPLY_FAILED",
        message: "A repository Ruleset could not be applied.",
      }),
    );
  } catch (error) {
    if (error instanceof RulesetError) throw error;
    reject("RULESET_RESPONSE_INVALID", "A Ruleset response is invalid.");
  }
  if (result.name !== payload.name || result.enforcement !== "active") {
    reject("RULESET_VERIFICATION_FAILED", "A repository Ruleset is not active.");
  }
}

function removeLegacyBranchProtection(defaultBranch) {
  const endpoint = `repos/${repository}/branches/${encodeURIComponent(defaultBranch)}/protection`;
  if (!ghOptional(["api", endpoint, "--silent"]).ok) return "absent";
  gh(["api", "-X", "DELETE", endpoint, "--silent"], {
    code: "LEGACY_PROTECTION_REMOVE_FAILED",
    message: "Legacy Branch Protection could not be removed after Ruleset activation.",
  });
  return "removed";
}

function assertLegacyBranchProtectionAbsent(defaultBranch) {
  const endpoint = `repos/${repository}/branches/${encodeURIComponent(defaultBranch)}/protection`;
  if (ghOptional(["api", endpoint, "--silent"]).ok) {
    reject("LEGACY_PROTECTION_PRESENT",
      "Legacy Branch Protection conflicts with the managed Ruleset contract.");
  }
}

function rulesetDigest(desired) {
  return createHash("sha256").update(canonicalJson(desired)).digest("hex");
}

function verify({ repositoryDetails, desired } = {}) {
  const details = repositoryDetails || assertRepositoryAccess({ requireAdmin: false });
  const expected = desired || buildRulesets(actionsIntegrationId());
  const summaries = repositoryRulesets();
  const activeBranchNames = summaries
    .filter((ruleset) => ruleset.target === "branch" && ruleset.enforcement === "active")
    .map((ruleset) => ruleset.name).sort();
  const expectedNames = expected.map((ruleset) => ruleset.name).sort();
  if (JSON.stringify(activeBranchNames) !== JSON.stringify(expectedNames)) {
    reject("RULESET_AUTHORITY_CONFLICT",
      "Active branch Rulesets do not exactly match the two managed authorities.");
  }
  for (const payload of expected) {
    const matches = summaries.filter((ruleset) => ruleset.name === payload.name);
    if (matches.length !== 1) {
      reject(matches.length > 1 ? "DUPLICATE_RULESET" : "RULESET_MISSING",
        "The managed repository Ruleset set does not exactly match local policy.");
    }
    if (!rulesetPayloadMatches(repositoryRuleset(matches[0].id), payload)) {
      reject("RULESET_PARITY_FAILED", "A managed Ruleset differs from local policy.");
    }
  }
  assertLegacyBranchProtectionAbsent(details.default_branch);
  process.stdout.write(`rulesets=verified count=${expected.length} policy_digest=${rulesetDigest(expected)}\n`);
}

function apply() {
  const repositoryDetails = assertRepositoryAccess({ requireAdmin: true });
  const existing = repositoryRulesets();
  const desired = buildRulesets(actionsIntegrationId());
  for (const payload of desired) {
    const matches = existing.filter((ruleset) => ruleset.name === payload.name);
    if (matches.length > 1) {
      reject("DUPLICATE_RULESET", "More than one managed Ruleset has the same name.");
    }
    applyRuleset(payload, matches[0]);
  }
  const legacy = removeLegacyBranchProtection(repositoryDetails.default_branch);
  verify({ repositoryDetails, desired });
  process.stdout.write(`rulesets=applied count=${desired.length} legacy_branch_protection=${legacy}\n`);
}

function main() {
  const [mode, ...extra] = process.argv.slice(2);
  if (extra.length > 0 || !["apply", "verify"].includes(mode)) {
    reject("USAGE", "Use apply or verify; the command targets only LicoLand/LicoUp.");
  }
  if (mode === "apply") apply();
  else verify();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    const code = error instanceof RulesetError ? error.code : "UNEXPECTED_FAILURE";
    const message =
      error instanceof RulesetError ? error.message : "The Ruleset operation failed closed.";
    process.stderr.write(`LicoUp Ruleset gate: ${code}: ${message}\n`);
    process.exitCode = 1;
  }
}

export {
  allBranchesRulesetName,
  promotionBranchesRulesetName,
  identityStatusContext,
  requiredStatusContexts,
};
