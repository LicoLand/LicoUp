import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

export const BETTER_PLAN_EVIDENCE_LEDGER_SCHEMA =
  "licolite.client.better-plan-evidence-ledger-report";
export const DEFAULT_BETTER_PLAN_MANIFEST_REF = "docs/plan/Manifest.json";

const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const UUID_PATTERN =
  /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/u;
const RFC3339_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|([+-])(\d{2}):(\d{2}))$/u;
const FILE_REF_FIELDS = new Set(["type", "path", "sha256", "recorded_at"]);
const COMMAND_REF_FIELDS = new Set(["type", "command", "exit_code", "recorded_at"]);
const DOCUMENT_BY_ROLE = new Map([
  ["product_requirements", "Requirements.md"],
  ["evidence", "Evidence.md"],
  ["validation_matrix", "Validation.md"],
  ["architecture_scaffold", "Architecture.md"]
]);

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function safeUuid(value, fallback) {
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : fallback;
}

export function isSafeRepositoryRelativePath(value) {
  if (typeof value !== "string" || value.length === 0 || value.trim() !== value) {
    return false;
  }
  if (
    value.includes("\\") ||
    value.includes("\0") ||
    value.startsWith("/") ||
    value.startsWith("~") ||
    /^[A-Za-z]:/u.test(value) ||
    /^[a-z][a-z0-9+.-]*:/iu.test(value)
  ) {
    return false;
  }
  const segments = value.split("/");
  return (
    segments.every((segment) => segment.length > 0 && segment !== "." && segment !== "..") &&
    path.posix.normalize(value) === value
  );
}

export function isValidEvidenceTimestamp(value) {
  if (typeof value !== "string") {
    return false;
  }
  const match = RFC3339_PATTERN.exec(value);
  if (!match) {
    return false;
  }
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, zone, , offsetHourText, offsetMinuteText] =
    match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  if (
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > new Date(Date.UTC(year, month, 0)).getUTCDate() ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  ) {
    return false;
  }
  if (zone !== "Z") {
    const offsetHour = Number(offsetHourText);
    const offsetMinute = Number(offsetMinuteText);
    if (offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)) {
      return false;
    }
  }
  return Number.isFinite(Date.parse(value));
}

function privacyRuleIds(value) {
  if (typeof value !== "string" || value.length === 0) {
    return [];
  }
  const rules = [
    ["private-home-path", /(?:\/Users\/[^/\s"']+|\/home\/[^/\s"']+|[A-Za-z]:\\Users\\[^\\\s"']+)/iu],
    ["private-temp-path", /(?:\/private\/var\/folders\/|\/var\/folders\/|\/tmp\/[^\s"']+)/iu],
    [
      "machine-absolute-path",
      /(?:^|[\s=])(?:~\/|\/(?!dev\/null(?:\s|$)|usr\/bin\/env(?:\s|$)|bin\/(?:sh|bash)(?:\s|$))[A-Za-z0-9._-]+\/|[A-Za-z]:[\\/])/iu
    ],
    ["private-key-material", /-----BEGIN\s+(?:OPENSSH|RSA|EC|DSA|PRIVATE)\s+PRIVATE KEY-----/iu],
    ["bearer-credential", /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/iu],
    ["credential-token-shape", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}/iu],
    [
      "literal-sensitive-assignment",
      /\b(?:ACCESS_TOKEN|API_KEY|AUTH_TOKEN|CLIENT_SECRET|PASSWORD|PRIVATE_KEY|REFRESH_TOKEN|SECRET|TOKEN)\s*=\s*(?!\$|%)["']?[^\s"']{4,}/iu
    ],
    [
      "literal-sensitive-option",
      /(?:--|[?&])(?:api[-_]?key|password|secret|token)=(?!\$|%)[^\s&]{4,}/iu
    ],
    ["credential-url", /[a-z][a-z0-9+.-]*:\/\/[^\s/@:]+:[^\s/@]+@/iu],
    ["device-serial-selection", /(?:\badb\b[^\r\n]*\s-s\s+(?!\$)[^\s]+|\bANDROID_SERIAL\s*=\s*(?!\$)[^\s]+)/iu],
    ["personal-email", /\b(?![^@\s]+@example\.(?:com|org|invalid)\b)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/iu]
  ];
  return rules.filter(([, pattern]) => pattern.test(value)).map(([id]) => id);
}

function issueContext({ checkpointRef, planId, nodeId, criterionIndex, refIndex } = {}) {
  const context = {};
  if (checkpointRef) {
    context.checkpoint = checkpointRef;
  }
  if (planId) {
    context.planId = planId;
  }
  if (nodeId) {
    context.nodeId = nodeId;
  }
  if (Number.isInteger(criterionIndex)) {
    context.criterionIndex = criterionIndex;
  }
  if (Number.isInteger(refIndex)) {
    context.refIndex = refIndex;
  }
  return context;
}

function addIssue(state, code, context = {}, detail = {}) {
  state.issues.push({
    code,
    ...issueContext(context),
    ...detail
  });
}

async function sha256File(filePath) {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) {
    digest.update(chunk);
  }
  return digest.digest("hex");
}

async function existingRegularFile(repoRoot, repositoryRef) {
  if (!isSafeRepositoryRelativePath(repositoryRef)) {
    return false;
  }
  const absolutePath = path.resolve(repoRoot, ...repositoryRef.split("/"));
  try {
    const canonicalRepoRoot = await fs.realpath(repoRoot);
    const realPath = await fs.realpath(absolutePath);
    const relativeRealPath = path.relative(canonicalRepoRoot, realPath);
    if (
      relativeRealPath === "" ||
      relativeRealPath.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relativeRealPath)
    ) {
      return false;
    }
    return (await fs.stat(realPath)).isFile();
  } catch {
    return false;
  }
}

function extractBacktickValues(text) {
  if (typeof text !== "string") {
    return [];
  }
  return [...text.matchAll(/`([^`\r\n]+)`/gu)].map((match) => match[1].trim()).filter(Boolean);
}

function commandLooksExecutable(value) {
  return /^(?:!\s+)?(?:npm\s+run|node\s+|cargo\s+|flutter\s+|dart\s+|python3?\s+|bash\s+|sh\s+|cd\s+|env\s+)/u.test(
    value
  );
}

async function suggestedEvidence({ repoRoot, packageScripts, planDirectoryRef, node, criterion }) {
  const suggestions = [];
  const seen = new Set();
  const add = (suggestion) => {
    const key = `${suggestion.type}:${suggestion.path || suggestion.command}`;
    if (!seen.has(key)) {
      seen.add(key);
      suggestions.push(suggestion);
    }
  };
  const text = [criterion?.text, criterion?.evidence].filter((value) => typeof value === "string").join(" ");
  const backtickValues = extractBacktickValues(text);

  for (const value of backtickValues) {
    if (commandLooksExecutable(value)) {
      if (privacyRuleIds(value).length === 0) {
        add({ type: "command", command: value, confidence: "criterion_exact" });
      }
      continue;
    }
    const candidates = [];
    if (isSafeRepositoryRelativePath(value)) {
      candidates.push(value);
      if (planDirectoryRef) {
        candidates.push(path.posix.join(planDirectoryRef, value));
      }
    }
    for (const candidate of candidates) {
      if (privacyRuleIds(candidate).length === 0 && await existingRegularFile(repoRoot, candidate)) {
        add({ type: "file", path: candidate, confidence: "criterion_exact" });
        break;
      }
    }
  }

  const roleDocument = DOCUMENT_BY_ROLE.get(node?.role);
  if (roleDocument && planDirectoryRef) {
    const documentRef = path.posix.join(planDirectoryRef, roleDocument);
    if (await existingRegularFile(repoRoot, documentRef)) {
      add({ type: "file", path: documentRef, confidence: "role_contract" });
    }
  }

  const lowerText = text.toLowerCase();
  const addPackageCommand = (scriptName) => {
    if (packageScripts.has(scriptName)) {
      add({ type: "command", command: `npm run ${scriptName}`, confidence: "capability_default" });
    }
  };
  if (/(?:flutter|dart|widget|controller|mobile ui|desktop ui)/u.test(lowerText)) {
    addPackageCommand("client:test");
  }
  if (/(?:flutter analyze|dart analyze|analy[sz]e)/u.test(lowerText)) {
    addPackageCommand("client:analyze");
  }
  if (/(?:rust|cargo|native test)/u.test(lowerText)) {
    addPackageCommand("client:native:test");
  }
  if (/(?:architecture|module ownership|parallel flattened)/u.test(lowerText)) {
    addPackageCommand("client:verify:architecture");
  }
  if (/(?:android|apk|gradle)/u.test(lowerText)) {
    addPackageCommand("client:build:android:debug");
  }

  if (suggestions.length === 0 && planDirectoryRef) {
    const planRef = path.posix.join(planDirectoryRef, "Plan.md");
    if (await existingRegularFile(repoRoot, planRef) && node?.role !== "implementation") {
      add({ type: "file", path: planRef, confidence: "plan_contract_fallback" });
    }
  }
  if (suggestions.length === 0) {
    if (planDirectoryRef?.includes("mobile-provider-account-system")) {
      addPackageCommand("client:test");
    } else if (planDirectoryRef?.includes("agent-conversation-semantic-archive-renderer")) {
      addPackageCommand("client:native:test");
      addPackageCommand("client:test");
    } else if (planDirectoryRef?.includes("agent-conversation-dispatch")) {
      addPackageCommand("client:verify:agent-conversation-parity");
    } else if (planDirectoryRef?.includes("client-release")) {
      addPackageCommand("client:verify:plan");
    }
  }

  return suggestions.slice(0, 4);
}

async function readJson(repositoryRoot, repositoryRef) {
  const absolutePath = path.resolve(repositoryRoot, ...repositoryRef.split("/"));
  const source = await fs.readFile(absolutePath, "utf8");
  return JSON.parse(source);
}

function evidenceRefFingerprint(ref) {
  if (ref?.type === "file") {
    return `file:${String(ref.path || "")}:${String(ref.sha256 || "")}`;
  }
  if (ref?.type === "command") {
    return `command:${String(ref.command || "").trim()}`;
  }
  return null;
}

async function validateEvidenceRef({ state, repoRoot, ref, context, seenRefs }) {
  state.counts.evidenceRefCount += 1;
  if (!isPlainObject(ref)) {
    addIssue(state, "evidence_ref_not_object", context);
    return;
  }

  const expectedFields = ref.type === "file" ? FILE_REF_FIELDS : ref.type === "command" ? COMMAND_REF_FIELDS : null;
  if (!expectedFields) {
    addIssue(state, "unknown_evidence_ref_type", context);
    return;
  }
  for (const field of expectedFields) {
    if (!Object.hasOwn(ref, field)) {
      addIssue(state, "evidence_ref_missing_field", context, { field });
    }
  }
  for (const field of Object.keys(ref)) {
    if (!expectedFields.has(field)) {
      addIssue(state, "evidence_ref_unknown_field", context, { field });
    }
  }
  if (!isValidEvidenceTimestamp(ref.recorded_at)) {
    addIssue(state, "invalid_evidence_timestamp", context);
  }

  const fingerprint = evidenceRefFingerprint(ref);
  if (fingerprint) {
    if (seenRefs.has(fingerprint)) {
      addIssue(state, "duplicate_evidence_ref", context);
    } else {
      seenRefs.add(fingerprint);
    }
  }

  if (ref.type === "command") {
    if (typeof ref.command !== "string" || ref.command.trim().length === 0) {
      addIssue(state, "empty_evidence_command", context);
    } else {
      for (const ruleId of privacyRuleIds(ref.command)) {
        addIssue(state, "privacy_leak", context, { field: "command", ruleId });
      }
    }
    if (!Number.isInteger(ref.exit_code) || ref.exit_code !== 0) {
      addIssue(state, "evidence_command_failed", context);
    }
    return;
  }

  if (!isSafeRepositoryRelativePath(ref.path)) {
    addIssue(state, "unsafe_evidence_file_path", context);
    return;
  }
  for (const ruleId of privacyRuleIds(ref.path)) {
    addIssue(state, "privacy_leak", context, { field: "path", ruleId });
  }
  if (!SHA256_PATTERN.test(String(ref.sha256 || ""))) {
    addIssue(state, "invalid_evidence_file_digest", context);
  }
  const absolutePath = path.resolve(repoRoot, ...ref.path.split("/"));
  let realPath;
  try {
    realPath = await fs.realpath(absolutePath);
  } catch {
    addIssue(state, "dangling_evidence_file_ref", context, { file: ref.path });
    return;
  }
  const canonicalRepoRoot = await fs.realpath(repoRoot);
  const realRelativePath = path.relative(canonicalRepoRoot, realPath);
  if (
    realRelativePath === "" ||
    realRelativePath.startsWith(`..${path.sep}`) ||
    path.isAbsolute(realRelativePath)
  ) {
    addIssue(state, "unsafe_evidence_file_path", context);
    return;
  }
  try {
    if (!(await fs.stat(realPath)).isFile()) {
      addIssue(state, "evidence_file_not_regular", context, { file: ref.path });
      return;
    }
    const actualDigest = await sha256File(realPath);
    if (SHA256_PATTERN.test(String(ref.sha256 || "")) && actualDigest !== ref.sha256) {
      addIssue(state, "evidence_file_digest_mismatch", context, { file: ref.path });
    }
  } catch {
    addIssue(state, "evidence_file_unreadable", context, { file: ref.path });
  }
}

function sortIssues(issues) {
  return issues.sort((left, right) => {
    const leftKey = [
      left.checkpoint || "",
      left.nodeId || "",
      String(left.criterionIndex ?? -1).padStart(6, "0"),
      String(left.refIndex ?? -1).padStart(6, "0"),
      left.code,
      left.field || ""
    ].join("\0");
    const rightKey = [
      right.checkpoint || "",
      right.nodeId || "",
      String(right.criterionIndex ?? -1).padStart(6, "0"),
      String(right.refIndex ?? -1).padStart(6, "0"),
      right.code,
      right.field || ""
    ].join("\0");
    return leftKey.localeCompare(rightKey);
  });
}

export async function evaluateBetterPlanEvidenceLedger({
  repoRoot,
  manifestRef = DEFAULT_BETTER_PLAN_MANIFEST_REF
}) {
  if (!path.isAbsolute(repoRoot)) {
    throw new TypeError("repoRoot must be an absolute path");
  }
  const state = {
    issues: [],
    counts: {
      planCount: 0,
      checkpointCount: 0,
      nodeCount: 0,
      completedNodeCount: 0,
      completedCriterionCount: 0,
      evidenceRefCount: 0
    }
  };
  if (!isSafeRepositoryRelativePath(manifestRef)) {
    addIssue(state, "unsafe_manifest_ref");
    return buildReport(state);
  }

  let manifest;
  try {
    manifest = await readJson(repoRoot, manifestRef);
  } catch (error) {
    addIssue(state, error?.code === "ENOENT" ? "manifest_missing" : "manifest_unreadable_or_invalid");
    return buildReport(state);
  }
  if (!Array.isArray(manifest)) {
    addIssue(state, "manifest_not_array");
    return buildReport(state);
  }

  let packageScripts = new Set();
  try {
    const packageJson = await readJson(repoRoot, "package.json");
    packageScripts = new Set(Object.keys(isPlainObject(packageJson?.scripts) ? packageJson.scripts : {}));
  } catch {
    addIssue(state, "package_scripts_unavailable");
  }

  const workspaceRef = path.posix.dirname(manifestRef);
  const planIds = new Set();
  const checkpointRefs = new Set();
  const nodeIds = new Set();

  for (const [planIndex, plan] of manifest.entries()) {
    state.counts.planCount += 1;
    if (!isPlainObject(plan)) {
      addIssue(state, "plan_not_object");
      continue;
    }
    const planId = safeUuid(plan.id, `<invalid-plan-id-${planIndex}>`);
    if (planIds.has(planId)) {
      addIssue(state, "duplicate_plan_id", { planId });
    }
    planIds.add(planId);

    const planDirectoryRef =
      isSafeRepositoryRelativePath(plan.directory) ? path.posix.join(workspaceRef, plan.directory) : null;
    const checkpointLocalRef = plan.checkpoints;
    if (!isSafeRepositoryRelativePath(checkpointLocalRef)) {
      addIssue(state, "unsafe_checkpoint_ref", { planId });
      continue;
    }
    const checkpointRef = path.posix.join(workspaceRef, checkpointLocalRef);
    if (!isSafeRepositoryRelativePath(checkpointRef)) {
      addIssue(state, "unsafe_checkpoint_ref", { planId });
      continue;
    }
    if (checkpointRefs.has(checkpointRef)) {
      addIssue(state, "duplicate_checkpoint_ref", { checkpointRef, planId });
      continue;
    }
    checkpointRefs.add(checkpointRef);

    let nodes;
    try {
      nodes = await readJson(repoRoot, checkpointRef);
    } catch (error) {
      addIssue(
        state,
        error?.code === "ENOENT" ? "dangling_checkpoint_ref" : "checkpoint_unreadable_or_invalid",
        { checkpointRef, planId }
      );
      continue;
    }
    state.counts.checkpointCount += 1;
    if (!Array.isArray(nodes)) {
      addIssue(state, "checkpoint_not_array", { checkpointRef, planId });
      continue;
    }

    for (const [nodeIndex, node] of nodes.entries()) {
      state.counts.nodeCount += 1;
      if (!isPlainObject(node)) {
        addIssue(state, "node_not_object", { checkpointRef, planId });
        continue;
      }
      const nodeId = safeUuid(node.id, `<invalid-node-id-${nodeIndex}>`);
      if (nodeIds.has(nodeId)) {
        addIssue(state, "duplicate_node_id", { checkpointRef, planId, nodeId });
      }
      nodeIds.add(nodeId);
      const completed = node.status === "completed";
      if (completed) {
        state.counts.completedNodeCount += 1;
      }
      if (!Array.isArray(node.acceptance_criteria) || node.acceptance_criteria.length === 0) {
        if (completed) {
          addIssue(state, "completed_node_without_criteria", { checkpointRef, planId, nodeId });
        }
        continue;
      }

      for (const [criterionIndex, criterion] of node.acceptance_criteria.entries()) {
        const context = { checkpointRef, planId, nodeId, criterionIndex };
        if (!isPlainObject(criterion)) {
          if (completed) {
            addIssue(state, "completed_criterion_not_object", context);
          }
          continue;
        }
        if (typeof criterion.evidence === "string") {
          for (const ruleId of privacyRuleIds(criterion.evidence)) {
            addIssue(state, "privacy_leak", context, { field: "evidence", ruleId });
          }
        }
        if (completed) {
          state.counts.completedCriterionCount += 1;
          if (criterion.checked !== true) {
            addIssue(state, "completed_criterion_unchecked", context);
          }
          if (
            !Object.hasOwn(criterion, "evidence_refs") ||
            (Array.isArray(criterion.evidence_refs) && criterion.evidence_refs.length === 0)
          ) {
            const recommendation = await suggestedEvidence({
              repoRoot,
              packageScripts,
              planDirectoryRef,
              node,
              criterion
            });
            addIssue(
              state,
              typeof criterion.evidence === "string" && criterion.evidence.trim().length > 0
                ? "free_text_only_evidence"
                : "missing_evidence_refs",
              context,
              { recommendation }
            );
          }
        }
        if (!Object.hasOwn(criterion, "evidence_refs")) {
          continue;
        }
        if (!Array.isArray(criterion.evidence_refs)) {
          addIssue(state, "evidence_refs_not_array", context);
          continue;
        }
        const seenRefs = new Set();
        for (const [refIndex, ref] of criterion.evidence_refs.entries()) {
          await validateEvidenceRef({
            state,
            repoRoot,
            ref,
            context: { ...context, refIndex },
            seenRefs
          });
        }
      }
    }
  }

  return buildReport(state);
}

function buildReport(state) {
  const issues = sortIssues(state.issues);
  const issuesByCode = {};
  for (const issue of issues) {
    issuesByCode[issue.code] = (issuesByCode[issue.code] || 0) + 1;
  }
  const completionGapCount = issues.filter((issue) =>
    [
      "completed_criterion_not_object",
      "completed_criterion_unchecked",
      "completed_node_without_criteria",
      "evidence_refs_not_array",
      "free_text_only_evidence",
      "missing_evidence_refs"
    ].includes(issue.code)
  ).length;
  return {
    schema: BETTER_PLAN_EVIDENCE_LEDGER_SCHEMA,
    generatedBy: "tools/scripts/client-better-plan-evidence-ledger.mjs",
    redacted: true,
    ready: issues.length === 0,
    summary: {
      ...state.counts,
      completionGapCount,
      failureCount: issues.length,
      issuesByCode
    },
    issues
  };
}
