#!/usr/bin/env node

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const exec = promisify(execFile);
export const SHANGHAI_OFFSET_MS = 8 * 60 * 60 * 1000;
export const WEEKLY_PLANNED_HOUR = 12;
export const CUTOFF_PREFIX = "nightly-cutoff/";
export const RELEASE_ENABLED_VARIABLE = "LICOUP_RELEASE_AUTOMATION_ENABLED";
export const REQUIRED_PLATFORM_ASSETS = Object.freeze([
  "LicoUp-macos-arm64.dmg",
  "LicoUp-macos-arm64.dmg.sha256",
  "LicoUp-macos-arm64-update.zip",
  "LicoUp-macos-arm64-update.zip.sha256",
  "LicoUp-update-manifest.json",
]);
export const PROJECT_FIELD_SCHEMA = Object.freeze({
  "Release track": Object.freeze({ type: "ProjectV2SingleSelectField", options: Object.freeze(["Nightly", "Stable"]) }),
  "Planned release": Object.freeze({ type: "ProjectV2Field" }),
  "Actual release": Object.freeze({ type: "ProjectV2Field" }),
  "Release state": Object.freeze({ type: "ProjectV2SingleSelectField", options: Object.freeze(["Planned", "Waiting cloud", "Published", "Observing", "Mature", "Blocked", "Abandoned"]) }),
});

export class WeeklyReleaseError extends Error {
  constructor(code) { super(code); this.name = "WeeklyReleaseError"; this.code = code; }
}
const reject = code => { throw new WeeklyReleaseError(code); };
const sha = value => typeof value === "string" && /^[a-f0-9]{40}$/u.test(value);
const instant = value => {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) reject("weekly_time_invalid");
  return parsed;
};
const dateKey = value => {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value || "")) reject("weekly_slot_invalid");
  const local = new Date(`${value}T00:00:00.000Z`);
  if (local.toISOString().slice(0, 10) !== value || local.getUTCDay() !== 6) reject("weekly_slot_invalid");
  return value;
};

export function weeklySlot(slot) {
  const key = dateKey(slot);
  const cutoffMs = Date.parse(`${key}T00:00:00.000Z`) - SHANGHAI_OFFSET_MS;
  return Object.freeze({
    slot: key,
    month: key.slice(0, 7),
    cutoff: new Date(cutoffMs).toISOString(),
    plannedAt: new Date(cutoffMs + WEEKLY_PLANNED_HOUR * 60 * 60 * 1000).toISOString(),
    ref: `${CUTOFF_PREFIX}${key}`,
  });
}

export function slotForRun(now) {
  const shifted = new Date(instant(now) + SHANGHAI_OFFSET_MS);
  const midnight = Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate());
  const saturday = midnight - ((shifted.getUTCDay() + 1) % 7) * 86400000;
  return weeklySlot(new Date(saturday).toISOString().slice(0, 10));
}

export function selectCutoffSource(firstParentMerges, cutoff) {
  if (!Array.isArray(firstParentMerges) || firstParentMerges.length === 0) reject("weekly_merge_evidence_absent");
  const boundary = instant(cutoff);
  const verified = firstParentMerges.map((entry, index) => {
    if (!sha(entry?.sha) || !Number.isInteger(entry?.pullRequest?.number) || entry.pullRequest.number < 1 ||
        entry.pullRequest.baseRef !== "nightly" || entry.parents !== 2) reject("weekly_merge_evidence_invalid");
    const committedAt = instant(entry.committedAt);
    const mergedAt = instant(entry.pullRequest.mergedAt);
    return { ...entry, committedAt, mergedAt, index };
  });
  for (let i = 1; i < verified.length; i += 1) {
    if (verified[i - 1].committedAt < verified[i].committedAt) reject("weekly_merge_order_invalid");
  }
  const selected = verified.find(entry => entry.committedAt < boundary && entry.mergedAt < boundary);
  if (!selected) reject("weekly_cutoff_source_absent");
  const includedPullRequests = verified
    .filter(entry => entry.index >= selected.index && entry.committedAt < boundary && entry.mergedAt < boundary)
    .map(entry => entry.pullRequest.number);
  return Object.freeze({ revision: selected.sha, includedPullRequests: Object.freeze(includedPullRequests) });
}

export function idempotencyKey({ slot, revision, includedPullRequests }) {
  if (!sha(revision) || !Array.isArray(includedPullRequests)) reject("weekly_operation_invalid");
  return `weekly:${dateKey(slot)}`;
}

export function operationRecord({ slot, source, runAt, state = "Planned" }) {
  const timing = weeklySlot(slot);
  const key = idempotencyKey({ slot, ...source });
  return Object.freeze({ schema: 1, ...timing, sourceRevision: source.revision,
    includedPullRequests: [...source.includedPullRequests], state, status: "pending",
    handoff: Object.freeze({ kind: "publish-nightly", callback: "client-release-result", serialized: true }),
    delayed: instant(runAt) > instant(timing.plannedAt), idempotencyKey: key });
}

export function candidateMaturity(publishedAt) {
  const source = new Date(instant(publishedAt) + SHANGHAI_OFFSET_MS);
  const year = source.getUTCFullYear(), month = source.getUTCMonth(), day = source.getUTCDate();
  const destination = new Date(Date.UTC(year, month + 2, 0)).getUTCDate();
  const local = Date.UTC(year, month + 1, Math.min(day, destination), source.getUTCHours(),
    source.getUTCMinutes(), source.getUTCSeconds(), source.getUTCMilliseconds());
  return new Date(local - SHANGHAI_OFFSET_MS).toISOString();
}

export function electMonthlyWinner(records, month) {
  if (!/^\d{4}-\d{2}$/u.test(month || "") || !Array.isArray(records)) reject("monthly_election_invalid");
  const slots = records.filter(record => record?.status === "pending" || record?.publicationMonth === month)
    .sort((a, b) => a.slot.localeCompare(b.slot));
  const seen = new Set();
  for (let index = 0; index < slots.length; index += 1) {
    const record = slots[index];
    dateKey(record.slot);
    if (seen.has(record.slot)) reject("monthly_slot_conflict");
    seen.add(record.slot);
    if (record.status === "pending") return Object.freeze({ status: "waiting-earlier-slot", slot: record.slot });
    if (record.status === "published") {
      if (!sha(record.revision) || record.ref !== `${CUTOFF_PREFIX}${record.slot}`) reject("monthly_publication_invalid");
      // The marker is written after the spread: the record's own status is
      // "published", and letting it win would hide the election from callers.
      return Object.freeze({ ...record, status: "selected", maturityAt: candidateMaturity(record.publishedAt) });
    }
    if (record.status !== "failed" && record.status !== "abandoned") reject("monthly_slot_status_invalid");
  }
  return Object.freeze({ status: "waiting-publication" });
}

export function verifyRelease(release, { tag, revision, assets = REQUIRED_PLATFORM_ASSETS, prerelease = true } = {}) {
  if (!release || release.draft !== false || release.prerelease !== prerelease || release.tag_name !== tag ||
      !release.published_at) reject("weekly_release_evidence_invalid");
  const names = release.assets?.map(asset => asset?.name);
  if (!Array.isArray(names) || names.length !== assets.length || new Set(names).size !== names.length ||
      assets.some(name => !names.includes(name))) reject("weekly_release_assets_invalid");
  for (const asset of release.assets) {
    if (!/^[a-f0-9]{64}$/u.test(asset.digest?.replace(/^sha256:/u, "") || "")) reject("weekly_release_digest_invalid");
  }
  return Object.freeze({ revision, publishedAt: new Date(instant(release.published_at)).toISOString() });
}

export function verifyAppCheck(checks, { name, revision, appId }) {
  const matches = (checks || []).filter(check => check?.name === name && check?.head_sha === revision);
  if (matches.length !== 1 || matches[0].conclusion !== "success" || matches[0].app?.id !== appId) reject("weekly_app_check_invalid");
  return true;
}

export function activationPlan({ enabled, automationAppId, appleAppId, rollingRelease, immutableReleases }) {
  if (enabled !== true) return Object.freeze({ state: "Disabled", mutations: [] });
  if (!Number.isInteger(automationAppId) || !Number.isInteger(appleAppId)) return Object.freeze({ state: "Blocked", reason: "apps-missing", mutations: [] });
  if (!rollingRelease) return Object.freeze({ state: "Waiting cloud", reason: "rolling-nightly-missing", mutations: [] });
  verifyRelease(rollingRelease, { tag: "nightly", revision: rollingRelease.target_commitish });
  if (immutableReleases !== true) return Object.freeze({ state: "Activate immutability", mutations: ["enable-release-immutability"] });
  return Object.freeze({ state: "Ready", mutations: [] });
}

export function reconcileCutoffRef(existingRevision, record) {
  if (existingRevision && existingRevision !== record.sourceRevision) reject("weekly_cutoff_ref_conflict");
  return existingRevision ? Object.freeze([]) : Object.freeze([{ type: "create-ref", ref: record.ref, revision: record.sourceRevision }]);
}

export function promotionSource({ ref, revision, maturityAt, now, readinessChecks, appleAppId }) {
  if (!ref?.startsWith(CUTOFF_PREFIX) || weeklySlot(ref.slice(CUTOFF_PREFIX.length)).ref !== ref || !sha(revision)) reject("candidate_ref_invalid");
  if (instant(now) < instant(maturityAt)) reject("candidate_immature");
  verifyAppCheck(readinessChecks, { name: "Apple Release ready", revision, appId: appleAppId });
  return Object.freeze({ head: ref, base: "stable", revision, aggregate: "Stable client", requiredChecks:
    Object.freeze(["Branch flow", "Commit identity", "Auditor", "Stable client", "Apple Release ready"]) });
}

export function promotionTreeMatches({ cutoffTree, stableMergeTree, releaseMergeTree }) {
  if (!sha(cutoffTree) || stableMergeTree !== cutoffTree || releaseMergeTree !== cutoffTree) reject("candidate_tree_mismatch");
  return true;
}

export function validateProjectFields(fields) {
  if (!Array.isArray(fields)) reject("weekly_project_fields_invalid");
  const result = {};
  for (const [name, expected] of Object.entries(PROJECT_FIELD_SCHEMA)) {
    const matches = fields.filter(field => field?.name === name);
    if (matches.length !== 1 || matches[0].dataType !== expected.type) reject("weekly_project_fields_invalid");
    if (expected.options && JSON.stringify(matches[0].options?.map(option => option.name)) !== JSON.stringify(expected.options)) reject("weekly_project_fields_invalid");
    result[name] = matches[0];
  }
  return Object.freeze(result);
}

export function parseCoordinatorEvent(eventName, event) {
  if (eventName === "schedule") return event?.schedule === "17 0 * * *"
    ? Object.freeze({ type: "maturity" })
    : Object.freeze({ type: "weekly", slot: slotForRun(event?.now || new Date().toISOString()).slot });
  if (eventName === "workflow_dispatch") return Object.freeze({ type: event?.inputs?.operation || "reconcile", slot: event?.inputs?.slot || "" });
  if (eventName === "repository_dispatch" && event?.action === "client-release-result" && typeof event?.sender?.login === "string")
    return Object.freeze({ type: "callback", senderLogin: event.sender.login, payload: event.client_payload });
  reject("weekly_event_rejected");
}

async function command(program, args, { allowNotFound = false } = {}) {
  try {
    const result = await exec(program, args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
    return result.stdout.trim();
  } catch (error) {
    if (allowNotFound && /\(HTTP 404\)/u.test(String(error?.stderr || ""))) return "";
    reject("weekly_github_command_failed");
  }
}

function parseJson(value, code) { try { return JSON.parse(value); } catch { reject(code); } }

export class GitHubReleaseAdapter {
  constructor({ repository, run = command } = {}) {
    if (!repository) reject("weekly_repository_absent");
    this.repository = repository; this.run = run;
  }
  async api(args, options) { const value = await this.run("gh", ["api", ...args], options); return value === "" ? null : parseJson(value, "weekly_github_response_invalid"); }
  async mergeHistory() {
    const revisions = (await this.run("git", ["rev-list", "--first-parent", "origin/nightly"])).split(/\s+/u).filter(Boolean);
    if (revisions.length === 0) reject("weekly_merge_evidence_absent");
    const merges = [];
    for (const revision of revisions) {
      const parents = (await this.run("git", ["show", "-s", "--format=%P", revision])).split(/\s+/u).filter(Boolean);
      if (parents.length !== 2) continue;
      const pulls = await this.api([`repos/${this.repository}/commits/${revision}/pulls?per_page=100`]);
      const pull = pulls?.filter(item => item?.merged_at && item?.base?.ref === "nightly");
      if (pull?.length !== 1) reject("weekly_merge_evidence_invalid");
      merges.push({ sha: revision, committedAt: await this.run("git", ["show", "-s", "--format=%cI", revision]), parents: 2,
        pullRequest: { number: pull[0].number, mergedAt: pull[0].merged_at, baseRef: pull[0].base.ref } });
    }
    return merges;
  }
  async ref(name) {
    return (await this.api([`repos/${this.repository}/git/ref/heads/${name}`], { allowNotFound: true }))?.object?.sha || null;
  }
  async createRef(name, revision) {
    await this.api(["--method", "POST", `repos/${this.repository}/git/refs`, "-f", `ref=refs/heads/${name}`, "-f", `sha=${revision}`]);
  }
  async operationIssue(slot) {
    const issues = await this.api([`repos/${this.repository}/issues?state=all&labels=release-train&per_page=100`]);
    return issues.find(issue => issue.title === `Weekly release ${slot}`) || null;
  }
  async writeOperation(record, existing) {
    const body = `<!-- licoup-weekly-release:v1 -->\n\n\`\`\`json\n${JSON.stringify(record, null, 2)}\n\`\`\``;
    if (existing) {
      const match = existing.body?.match(/```json\n([\s\S]+)\n```/u);
      if (!match) reject("weekly_issue_conflict");
      const prior = JSON.parse(match[1]);
      if (prior.idempotencyKey !== record.idempotencyKey || prior.sourceRevision !== record.sourceRevision ||
          JSON.stringify(prior.includedPullRequests) !== JSON.stringify(record.includedPullRequests)) reject("weekly_issue_conflict");
      return existing;
    }
    return this.api(["--method", "POST", `repos/${this.repository}/issues`, "-f", `title=Weekly release ${record.slot}`, "-f", `body=${body}`, "-f", "labels[]=release-train"]);
  }
  parseOperation(issue) {
    const match = issue?.body?.match(/```json\n([\s\S]+)\n```/u);
    if (!match) reject("weekly_issue_conflict");
    try { return JSON.parse(match[1]); } catch { reject("weekly_issue_conflict"); }
  }
  async updateOperation(issue, record) {
    const prior = this.parseOperation(issue);
    if (prior.slot !== record.slot || prior.sourceRevision !== record.sourceRevision ||
        JSON.stringify(prior.includedPullRequests) !== JSON.stringify(record.includedPullRequests)) reject("weekly_issue_conflict");
    const body = `<!-- licoup-weekly-release:v1 -->\n\n\`\`\`json\n${JSON.stringify(record, null, 2)}\n\`\`\``;
    return this.api(["--method", "PATCH", `repos/${this.repository}/issues/${issue.number}`, "-f", `body=${body}`]);
  }
  async operations(month) {
    const issues = await this.api([`repos/${this.repository}/issues?state=all&labels=release-train&per_page=100`]);
    return issues.filter(issue => issue.title?.startsWith("Weekly release ")).map(issue => this.parseOperation(issue));
  }
  async tagRevision(tag) {
    const ref = await this.api([`repos/${this.repository}/git/ref/tags/${tag}`]);
    return ref?.object?.sha;
  }
  async release(tag) { return this.api([`repos/${this.repository}/releases/tags/${tag}`]); }
  async optionalRelease(tag) {
    return this.api([`repos/${this.repository}/releases/tags/${tag}`], { allowNotFound: true });
  }
  async checks(revision) { return (await this.api([`repos/${this.repository}/commits/${revision}/check-runs`]))?.check_runs || []; }
  async projectInventory() {
    if (this.project) return this.project;
    const [project, graph] = await Promise.all([
      this.run("gh", ["project", "view", "4", "--owner", "LicoLand", "--format", "json"]).then(value => parseJson(value, "weekly_project_invalid")),
      this.run("gh", ["api", "graphql", "-f", "query=query { organization(login: \"LicoLand\") { projectV2(number: 4) { fields(first: 100) { nodes { ... on ProjectV2FieldCommon { id name dataType } ... on ProjectV2SingleSelectField { options { id name } } } } } } }"]).then(value => parseJson(value, "weekly_project_fields_invalid")),
    ]);
    this.project = Object.freeze({ id: project.id, fields: validateProjectFields(graph.data?.organization?.projectV2?.fields?.nodes) });
    return this.project;
  }
  async syncProject(issue, values) {
    const project = await this.projectInventory();
    const added = parseJson(await this.run("gh", ["project", "item-add", "4", "--owner", "LicoLand", "--url", issue.html_url, "--format", "json"]), "weekly_project_item_invalid");
    for (const [name, value] of Object.entries(values)) {
      if (value === "" || value === undefined) continue;
      const field = project.fields[name];
      const args = ["project", "item-edit", "--id", added.id, "--project-id", project.id, "--field-id", field.id];
      if (field.options) {
        const option = field.options.find(candidate => candidate.name === value);
        if (!option) reject("weekly_project_value_invalid");
        args.push("--single-select-option-id", option.id);
      } else args.push(name === "Planned release" ? "--date" : "--text", value);
      await this.run("gh", args);
    }
  }
}

export async function reconcileWeekly({ adapter, slot, runAt }) {
  const timing = weeklySlot(slot);
  const source = selectCutoffSource(await adapter.mergeHistory(), timing.cutoff);
  const record = operationRecord({ slot, source, runAt });
  const existingRef = await adapter.ref(record.ref);
  for (const mutation of reconcileCutoffRef(existingRef, record)) await adapter.createRef(mutation.ref, mutation.revision);
  const existingIssue = await adapter.operationIssue(slot);
  const issue = await adapter.writeOperation(record, existingIssue);
  if (!existingIssue && adapter.syncProject) await adapter.syncProject(issue, { "Release track": "Nightly", "Planned release": record.slot,
    "Actual release": "", "Release state": "Waiting cloud" });
  return Object.freeze({ ...(existingIssue && adapter.parseOperation ? adapter.parseOperation(existingIssue) : record), publicationCalls: 0 });
}

export async function reconcileCallback({ adapter, payload, senderLogin, appleBotLogin, appleAppId }) {
  if (senderLogin !== appleBotLogin || !/\[bot\]$/u.test(senderLogin || "") || payload?.kind !== "nightly-published") reject("weekly_callback_unverified");
  const timing = weeklySlot(payload.slot);
  const revision = await adapter.ref(timing.ref);
  if (!revision) reject("weekly_cutoff_ref_absent");
  const release = await adapter.release("nightly");
  const tagRevision = await adapter.tagRevision("nightly");
  if (tagRevision !== revision) reject("weekly_release_source_mismatch");
  const verified = verifyRelease(release, { tag: "nightly", revision });
  verifyAppCheck(await adapter.checks(revision), { name: "Apple Release published", revision, appId: appleAppId });
  const issue = await adapter.operationIssue(timing.slot);
  if (!issue) reject("weekly_issue_absent");
  const prior = adapter.parseOperation ? adapter.parseOperation(issue) : issue.record;
  const publication = { ...prior, status: "published", state: "Published", ref: timing.ref, revision,
    publishedAt: verified.publishedAt,
    publicationMonth: new Date(instant(verified.publishedAt) + SHANGHAI_OFFSET_MS).toISOString().slice(0, 7) };
  const records = (await adapter.operations()).filter(record => record.slot !== timing.slot).concat(publication);
  const election = electMonthlyWinner(records, publication.publicationMonth);
  let result = publication;
  if (election.status === "selected" && election.slot === timing.slot) {
    const tag = `nightly-candidate-${publication.publicationMonth}`;
    const candidate = adapter.optionalRelease ? await adapter.optionalRelease(tag) : await adapter.release(tag);
    const candidateRevision = candidate ? await adapter.tagRevision(tag) : null;
    if (candidate && candidateRevision === revision) {
      const evidence = verifyRelease(candidate, { tag, revision });
      result = { ...publication, state: "Observing", status: "published", candidateTag: tag,
        candidatePublishedAt: evidence.publishedAt, maturityAt: candidateMaturity(evidence.publishedAt) };
    } else result = { ...publication, state: "Waiting cloud" };
  }
  if (adapter.updateOperation) await adapter.updateOperation(issue, result);
  if (adapter.syncProject) await adapter.syncProject(issue, { "Release track": "Nightly", "Planned release": timing.slot,
    "Actual release": result.candidateTag || "nightly", "Release state": result.state });
  return Object.freeze(result);
}

export async function coordinatorDryRun({ env = process.env, run = command } = {}) {
  const enabled = env[RELEASE_ENABLED_VARIABLE] === "true";
  const repository = env.GITHUB_REPOSITORY;
  if (!repository) reject("weekly_repository_absent");
  const details = JSON.parse(await run("gh", ["api", `repos/${repository}`]));
  if (details.full_name !== repository) reject("weekly_repository_mismatch");
  return Object.freeze({ ok: true, enabled, state: enabled ? "Ready to reconcile" : "Disabled", publicationCalls: 0, privateDataIncluded: false });
}

export async function runCoordinator({ env = process.env, run = command } = {}) {
  if (env[RELEASE_ENABLED_VARIABLE] !== "true") return Object.freeze({ ok: true, state: "Disabled", publicationCalls: 0, privateDataIncluded: false });
  const event = parseJson(await (await import("node:fs/promises")).readFile(env.GITHUB_EVENT_PATH, "utf8"), "weekly_event_invalid");
  const parsed = parseCoordinatorEvent(env.GITHUB_EVENT_NAME, event);
  const adapter = new GitHubReleaseAdapter({ repository: env.GITHUB_REPOSITORY, run });
  let result;
  if (parsed.type === "weekly") result = await reconcileWeekly({ adapter, slot: parsed.slot, runAt: event.now || new Date().toISOString() });
  else if (parsed.type === "callback") result = await reconcileCallback({ adapter, payload: parsed.payload,
    senderLogin: parsed.senderLogin, appleBotLogin: env.LICOUP_APPLE_RELEASE_BOT_LOGIN,
    appleAppId: Number(env.LICOUP_APPLE_RELEASE_APP_ID) });
  else return coordinatorDryRun({ env, run });
  return Object.freeze({ ok: true, state: "Reconciled", ...result, privateDataIncluded: false });
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try { process.stdout.write(`${JSON.stringify(await runCoordinator())}\n`); }
  catch (error) { process.stderr.write(`${JSON.stringify({ ok: false, code: error?.code || "weekly_release_failed", privateDataIncluded: false })}\n`); process.exitCode = 1; }
}
