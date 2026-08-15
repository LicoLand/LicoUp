import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  PromotionError,
  hasPromotableCommits,
  inferPromotionBase,
  promotionPlan,
  releaseTrainEdges,
  resolvePromotionHead,
  summarizeDocsTrain,
} from "../../../tools/scripts/client-promotion.mjs";

test("promotion planner accepts only the three repository promotion edges", () => {
  assert.equal(promotionPlan("fix/example", "nightly").aggregate, "Client required");
  assert.equal(promotionPlan("nightly", "stable").aggregate, "Stable client");
  assert.equal(promotionPlan("stable", "release").aggregate, "Release ready");
  for (const [head, base] of [
    ["fix/example", "stable"],
    ["nightly", "release"],
    ["stable", "nightly"],
    ["release", "nightly"],
  ]) {
    assert.throws(
      () => promotionPlan(head, base),
      (error) => error instanceof PromotionError && error.code === "promotion_edge_invalid",
    );
  }
});

test("promotion accepts merge-history divergence only when the source has new commits", () => {
  assert.equal(hasPromotableCommits("ahead"), true);
  assert.equal(hasPromotableCommits("diverged"), true);
  assert.equal(hasPromotableCommits("behind"), false);
  assert.equal(hasPromotableCommits("identical"), false);
});

test("promotion planner rejects unsafe or non-action branch names", () => {
  for (const head of ["agent/example", "dev/example", "../fix/example", "fix/with space"]) {
    assert.throws(() => promotionPlan(head, "nightly"), PromotionError);
  }
});

test("promotion base inference follows the release train without a default-branch shortcut", () => {
  assert.equal(inferPromotionBase("refactor/promotion-gates"), "nightly");
  assert.equal(inferPromotionBase("nightly"), "stable");
  assert.equal(inferPromotionBase("stable"), "release");
  assert.throws(
    () => inferPromotionBase("release"),
    (error) => error instanceof PromotionError &&
      error.code === "promotion_source_has_no_next_edge",
  );
  assert.deepEqual(releaseTrainEdges.map(({ head, base, aggregate }) =>
    `${head}->${base}:${aggregate}`), [
    "current->nightly:Client required",
    "nightly->stable:Stable client",
    "stable->release:Release ready",
  ]);
});

test("documentation train timing warns without changing successful promotion status", () => {
  const stages = [
    { head: "docs/readme-refresh", base: "nightly", durationMs: 30_000 },
    { head: "nightly", base: "stable", durationMs: 35_000 },
    { head: "stable", base: "release", durationMs: 40_000 },
  ];
  const quick = summarizeDocsTrain({
    startedAtMs: Date.parse("2026-08-15T00:00:00Z"),
    endedAt: "2026-08-15T00:04:59Z",
    stages,
  });
  assert.equal(quick.status, "release-branch-promoted");
  assert.equal(quick.efficiencyWarning, false);
  const slow = summarizeDocsTrain({
    startedAtMs: Date.parse("2026-08-15T00:00:00Z"),
    endedAt: "2026-08-15T00:05:01Z",
    stages,
  });
  assert.equal(slow.status, "release-branch-promoted");
  assert.equal(slow.efficiencyWarning, true);
  assert.equal(slow.totalDurationMs, 301_000);
  assert.deepEqual(slow.stageDurationsMs.map(({ edge }) => edge), [
    "docs/readme-refresh->nightly",
    "nightly->stable",
    "stable->release",
  ]);
});

test("documentation train timing fails closed for invalid telemetry", () => {
  assert.throws(() => summarizeDocsTrain({
    startedAtMs: 0,
    endedAt: "invalid",
    stages: [],
  }), PromotionError);
});

test("detached documentation entry never resolves a current branch", () => {
  let branchRead = false;
  const readCurrentBranch = () => {
    branchRead = true;
    throw new Error("detached");
  };
  assert.equal(resolvePromotionHead("docs-train", {}, readCurrentBranch), null);
  assert.equal(branchRead, false);
  assert.equal(resolvePromotionHead("train", { head: "fix/example" }, readCurrentBranch),
    "fix/example");
  assert.equal(branchRead, false);
});

test("promotion mutations use idempotent REST confirmation instead of GraphQL writes", () => {
  const source = readFileSync("tools/scripts/client-promotion.mjs", "utf8");
  assert.equal(source.includes('"pr", "create"'), false);
  assert.equal(source.includes('"pr", "merge"'), false);
  assert.match(source, /repos\/\$\{repository\}\/pulls/u);
  assert.match(source, /merge_method=merge/u);
  assert.match(source, /attempts: 3/u);
  assert.match(source, /check-runs/u);
  assert.match(source, /"Branch flow", "Commit identity", plan\.aggregate, "Auditor"/u);
  assert.match(source, /for \(;;\)/u);
  assert.match(source, /retryTransient: true/u);
  assert.equal(source.includes('"pr", "checks"'), false);
  assert.equal(source.includes("docsEfficiencyThresholdMs"), true);
});
