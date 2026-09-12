import assert from "node:assert/strict";
import test from "node:test";
import {
  activationPlan, candidateMaturity, electMonthlyWinner, idempotencyKey, operationRecord,
  promotionSource, promotionTreeMatches, reconcileCutoffRef, selectCutoffSource, verifyRelease, weeklySlot,
  reconcileWeekly, reconcileCallback, validateProjectFields,
} from "../../../tools/scripts/client-weekly-release.mjs";

const s = digit => String(digit).repeat(40);
const d = digit => `sha256:${String(digit).repeat(64)}`;
const merge = (sha, committedAt, number, mergedAt = committedAt) => ({ sha, committedAt, parents: 2,
  pullRequest: { number, mergedAt, baseRef: "nightly" } });

test("exclusive Shanghai cutoff is deterministic across delayed retries", () => {
  const slot = weeklySlot("2026-09-12");
  assert.equal(slot.cutoff, "2026-09-11T16:00:00.000Z");
  const source = selectCutoffSource([
    merge(s(3), "2026-09-11T16:00:01Z", 3), merge(s(2), "2026-09-11T16:00:00Z", 2),
    merge(s(1), "2026-09-11T15:59:59Z", 1),
  ], slot.cutoff);
  assert.deepEqual(source.includedPullRequests, [1]);
  const first = operationRecord({ slot: slot.slot, source, runAt: "2026-09-12T10:00:00Z" });
  const retry = operationRecord({ slot: slot.slot, source, runAt: "2026-09-13T10:00:00Z" });
  assert.equal(first.sourceRevision, s(1)); assert.equal(first.idempotencyKey, retry.idempotencyKey);
  assert.equal(slot.plannedAt, "2026-09-12T04:00:00.000Z");
  assert.equal(first.delayed, true); assert.deepEqual(reconcileCutoffRef(null, first), [{ type: "create-ref", ref: slot.ref, revision: s(1) }]);
  assert.deepEqual(reconcileCutoffRef(s(1), retry), []);
  assert.throws(() => selectCutoffSource([], slot.cutoff));
  assert.throws(() => reconcileCutoffRef(s(2), retry));
  assert.equal(idempotencyKey({ slot: slot.slot, ...source }), "weekly:2026-09-12");
});

test("fake GitHub seam reconciles schedule, retry, verified cloud callback, and Project values", async () => {
  const state = { ref: null, issue: null, project: [], creates: 0, updates: 0 };
  const slot = "2026-09-05", revision = s(1);
  const release = tag => ({ draft: false, prerelease: true, tag_name: tag, target_commitish: revision,
    published_at: "2026-09-05T04:00:00Z", assets: ["LicoUp-macos-arm64.dmg", "LicoUp-macos-arm64.dmg.sha256",
      "LicoUp-macos-arm64-update.zip", "LicoUp-macos-arm64-update.zip.sha256", "LicoUp-update-manifest.json"].map(name => ({ name, digest: d(4) })) });
  const adapter = {
    mergeHistory: async () => [merge(revision, "2026-09-04T15:59:59Z", 1)],
    ref: async () => state.ref,
    createRef: async (_ref, value) => { state.ref = value; state.creates += 1; },
    operationIssue: async () => state.issue,
    writeOperation: async (record, existing) => { if (!existing) state.issue = { number: 7, html_url: "https://example.invalid/7", record }; return state.issue; },
    parseOperation: issue => issue.record,
    operations: async () => state.issue ? [state.issue.record] : [],
    updateOperation: async (issue, record) => { issue.record = record; state.updates += 1; },
    syncProject: async (_issue, values) => { state.project.push(values); },
    release: async tag => release(tag),
    tagRevision: async () => revision,
    checks: async headSha => [{ name: "Apple Release published", head_sha: headSha, conclusion: "success", app: { id: 22 } }],
  };
  const first = await reconcileWeekly({ adapter, slot, runAt: "2026-09-05T05:00:00Z" });
  await reconcileWeekly({ adapter, slot, runAt: "2026-09-05T06:00:00Z" });
  assert.equal(state.creates, 1); assert.equal(first.publicationCalls, 0);
  const appleBot = "lico-apple-release[bot]";
  const result = await reconcileCallback({ adapter, payload: { kind: "nightly-published", slot },
    senderLogin: appleBot, appleBotLogin: appleBot, appleAppId: 22 });
  assert.equal(result.state, "Observing"); assert.equal(state.updates, 1);
  assert.equal(state.project.at(-1)["Actual release"], "nightly-candidate-2026-09");
  await assert.rejects(reconcileCallback({ adapter, payload: { kind: "nightly-published", slot },
    senderLogin: "someone-else[bot]", appleBotLogin: appleBot, appleAppId: 22 }));
});

test("Project inventory must use exact field types and options", () => {
  const fields = [
    { id: "1", name: "Release track", dataType: "ProjectV2SingleSelectField", options: [{ name: "Nightly" }, { name: "Stable" }] },
    { id: "2", name: "Planned release", dataType: "ProjectV2Field" },
    { id: "3", name: "Actual release", dataType: "ProjectV2Field" },
    { id: "4", name: "Release state", dataType: "ProjectV2SingleSelectField", options: ["Planned", "Waiting cloud", "Published", "Observing", "Mature", "Blocked", "Abandoned"].map(name => ({ name })) },
  ];
  assert.equal(validateProjectFields(fields)["Release state"].id, "4");
  assert.throws(() => validateProjectFields(fields.filter(field => field.name !== "Actual release")));
});

test("month election waits for earlier slots and ignores callback order", () => {
  const later = { slot: "2026-09-12", status: "published", revision: s(2), ref: "nightly-cutoff/2026-09-12",
    publishedAt: "2026-09-12T03:00:00Z", publicationMonth: "2026-09" };
  assert.equal(electMonthlyWinner([{ slot: "2026-09-05", status: "pending" }, later], "2026-09").status, "waiting-earlier-slot");
  const winner = { slot: "2026-09-05", status: "published", revision: s(1), ref: "nightly-cutoff/2026-09-05",
    publishedAt: "2026-09-05T04:00:00Z", publicationMonth: "2026-09" };
  assert.equal(electMonthlyWinner([later, winner], "2026-09").revision, s(1));
  assert.equal(electMonthlyWinner([{ slot: "2026-09-05", status: "failed" }, later], "2026-09").revision, s(2));
});

test("calendar month maturity clamps days in Shanghai", () => {
  assert.equal(candidateMaturity("2024-01-31T12:30:00Z"), "2024-02-29T12:30:00.000Z");
  assert.equal(candidateMaturity("2025-01-31T12:30:00Z"), "2025-02-28T12:30:00.000Z");
});

test("verified release, app readiness, and tree equality gate promotion", () => {
  const release = { draft: false, prerelease: true, tag_name: "nightly-candidate-2026-09", target_commitish: s(1),
    published_at: "2026-09-05T04:00:00Z", assets: ["a", "b", "c", "d", "e"].map((name, i) => ({ name, digest: d(i + 1) })) };
  assert.deepEqual(verifyRelease(release, { tag: release.tag_name, revision: s(1), assets: ["a", "b", "c", "d", "e"] }),
    { revision: s(1), publishedAt: "2026-09-05T04:00:00.000Z" });
  const plan = promotionSource({ ref: "nightly-cutoff/2026-09-05", revision: s(1), maturityAt: "2026-10-05T04:00:00Z",
    now: "2026-10-05T04:00:00Z", appleAppId: 7,
    readinessChecks: [{ name: "Apple Release ready", head_sha: s(1), conclusion: "success", app: { id: 7 } }] });
  assert.equal(plan.head, "nightly-cutoff/2026-09-05");
  assert.equal(promotionTreeMatches({ cutoffTree: s(9), stableMergeTree: s(9), releaseMergeTree: s(9) }), true);
  assert.throws(() => promotionTreeMatches({ cutoffTree: s(9), stableMergeTree: s(8), releaseMergeTree: s(9) }));
  assert.throws(() => promotionSource({ ...plan, now: "2026-10-05T03:59:59Z", readinessChecks: [] }));
});

test("activation stays disabled or blocked until Apps and rolling Nightly exist", () => {
  assert.equal(activationPlan({ enabled: false }).state, "Disabled");
  assert.equal(activationPlan({ enabled: true }).state, "Blocked");
  assert.equal(activationPlan({ enabled: true, automationAppId: 1, appleAppId: 2 }).state, "Waiting cloud");
});
