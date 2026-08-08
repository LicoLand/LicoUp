#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import process from "node:process";
import { pathToFileURL } from "node:url";

const repository = "LicoLand/LicoUp";
const allBranchesRulesetName = "LicoUp commit identity — all branches";
const defaultBranchRulesetName = "LicoUp protected default branch";
const identityStatusContext = "LicoUp / commit identity";
const githubNoreplyHostPattern = ["users", "noreply", "github", "com"].join("\\.");
const canonicalNoreplyPattern = `^[0-9]+\\+[A-Za-z0-9][A-Za-z0-9-]{0,38}@${githubNoreplyHostPattern}$`;
const agentEmailPattern =
  "(?i)(claude|cursor|copilot|codex|chatgpt|gemini|anthropic|openai|(^|[+._-])(agent|bot)([+._-]|@))";
const forbiddenAttributionPattern =
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
        { type: "creation" },
        metadataRule(
          "commit_author_email_pattern",
          "Author must use a canonical GitHub noreply identity",
          canonicalNoreplyPattern,
          false,
        ),
        metadataRule(
          "committer_email_pattern",
          "Committer email must not identify an Agent",
          agentEmailPattern,
          true,
        ),
        metadataRule(
          "commit_message_pattern",
          "Attribution trailers and Agent-shaped identity lines are forbidden",
          forbiddenAttributionPattern,
          true,
        ),
      ],
    },
    {
      name: defaultBranchRulesetName,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {
        ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] },
      },
      rules: [
        { type: "deletion" },
        { type: "non_fast_forward" },
        { type: "required_linear_history" },
        {
          type: "pull_request",
          parameters: {
            allowed_merge_methods: ["rebase"],
            dismiss_stale_reviews_on_push: true,
            require_code_owner_review: false,
            require_last_push_approval: false,
            required_approving_review_count: 0,
            required_review_thread_resolution: true,
          },
        },
        {
          type: "required_status_checks",
          parameters: {
            do_not_enforce_on_create: true,
            required_status_checks: [
              {
                context: identityStatusContext,
                integration_id: actionsIntegrationId,
              },
            ],
            strict_required_status_checks_policy: true,
          },
        },
      ],
    },
  ];
}

function assertAdministration() {
  gh(["auth", "status"], {
    code: "GH_AUTH_REQUIRED",
    message: "GitHub CLI authentication is required.",
  });
  let details;
  try {
    details = JSON.parse(
      gh(["api", `repos/${repository}`], {
        code: "REPOSITORY_UNAVAILABLE",
        message: "The target repository is unavailable.",
      }),
    );
  } catch (error) {
    if (error instanceof RulesetError) throw error;
    reject("REPOSITORY_RESPONSE_INVALID", "The repository metadata response is invalid.");
  }
  if (details.full_name !== repository || details.permissions?.admin !== true) {
    reject(
      "REMOTE_ADMIN_REQUIRED",
      "The authenticated GitHub CLI account needs Administration(write) on the target repository.",
    );
  }
  return details;
}

function actionsIntegrationId() {
  const raw = gh(["api", "/apps/github-actions", "--jq", ".id"], {
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
      gh(["api", `repos/${repository}/rulesets?includes_parents=false`], {
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

function apply() {
  const repositoryDetails = assertAdministration();
  const existing = repositoryRulesets();
  const desired = buildRulesets(actionsIntegrationId());
  for (const payload of desired) {
    const matches = existing.filter((ruleset) => ruleset.name === payload.name);
    if (matches.length > 1) {
      reject("DUPLICATE_RULESET", "More than one managed Ruleset has the same name.");
    }
    applyRuleset(payload, matches[0]);
  }
  const activeNames = new Set(
    repositoryRulesets()
      .filter((ruleset) => ruleset.enforcement === "active")
      .map((ruleset) => ruleset.name),
  );
  if (![allBranchesRulesetName, defaultBranchRulesetName].every((name) => activeNames.has(name))) {
    reject("RULESET_VERIFICATION_FAILED", "The managed repository Rulesets are not active.");
  }
  const legacy = removeLegacyBranchProtection(repositoryDetails.default_branch);
  process.stdout.write(`rulesets=active count=2 legacy_branch_protection=${legacy}\n`);
}

function main() {
  if (process.argv.length !== 2) {
    reject("USAGE", "This command takes no arguments and targets only LicoLand/LicoUp.");
  }
  apply();
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
  defaultBranchRulesetName,
  identityStatusContext,
};
