import assert from "node:assert/strict";
import test from "node:test";

import {
  PromotionError,
  hasPromotableCommits,
  inferPromotionBase,
  promotionPlan,
  releaseTrainEdges,
  requiredCheckRegistered,
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

test("required check registration accepts check-run names and commit-status contexts", () => {
  assert.equal(requiredCheckRegistered([
    { name: "Client required", status: "IN_PROGRESS" },
  ], "Client required"), true);
  assert.equal(requiredCheckRegistered([
    { context: "Client required", state: "PENDING" },
  ], "Client required"), true);
  assert.equal(requiredCheckRegistered([
    { name: "unrelated check", status: "COMPLETED" },
    { context: "Client required", state: "PENDING" },
  ], "Client required"), true);
});

test("required check registration stays false until the aggregate appears", () => {
  assert.equal(requiredCheckRegistered([], "Client required"), false);
  assert.equal(requiredCheckRegistered([
    { name: "unrelated check", status: "COMPLETED" },
    { context: "other status", state: "SUCCESS" },
  ], "Client required"), false);
  assert.equal(requiredCheckRegistered([
    { name: "Client required extra" },
    { context: "Client require" },
  ], "Client required"), false);
});

test("required check registration rejects non-array and garbage rollups", () => {
  for (const rollup of [
    undefined,
    null,
    "Client required",
    42,
    { name: "Client required" },
    [null, "Client required", 42, [{ name: "Client required" }]],
  ]) {
    assert.equal(requiredCheckRegistered(rollup, "Client required"), false);
  }
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
