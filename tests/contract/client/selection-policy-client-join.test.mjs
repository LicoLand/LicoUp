import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");

const selectionRoot = "apps/desktop/lib/src/frontend/features/models/selection";
const composition =
  "apps/desktop/lib/src/composition/features/models/selection_policy_composition.dart";

function dartSources(root) {
  const found = [];
  for (const entry of readdirSync(root)) {
    const full = path.join(root, entry);
    if (statSync(full).isDirectory()) {
      found.push(...dartSources(full));
    } else if (entry.endsWith(".dart")) {
      found.push(full);
    }
  }
  return found;
}

test("the selection surface keeps suggestion, adopted policy and execution apart", () => {
  const view = read(`${selectionRoot}/selection_policy_view.dart`);

  // The four honest judgment outcomes, the attributed evaluator, the bounded
  // evidence and the promotion subject are separate members: none of them is
  // collapsed into one readiness or approval flag.
  for (const symbol of [
    "enum SelectionEvaluation { usable, rejected, uncertain, missing }",
    "enum SelectionPromotionSubject { routingOnly, routingAndContext }",
    "class SelectionSuggestionView",
    "class SelectionPolicyView",
    "class SelectionPolicyOutcome",
    "abstract interface class SelectionPolicyActions",
    "class UnavailableSelectionPolicyActions",
  ]) {
    assert.ok(
      view.includes(symbol),
      `selection_policy_view.dart must declare ${symbol}`,
    );
  }

  // Only a usable evaluation proposes a change; the other three are evidence
  // about the sample.
  assert.match(
    view,
    /proposesPolicyChange\s*=>\s*evaluation\s*==\s*SelectionEvaluation\.usable/u,
  );
  // A routing-only sample may never speak to context or collaboration.
  assert.match(
    view,
    /speaksToContext\s*=>\s*promotionSubject\s*==\s*SelectionPromotionSubject\.routingAndContext/u,
  );
});

test("no Dart source writes the native-owned selection policy document", () => {
  // The durable register is owned by the native selection-policy module and is
  // reachable only through its own transition. The client must not name the
  // settings key it stores, because a client-side write would make the client a
  // second implementer of a transition the owner owns.
  const offenders = dartSources("apps/desktop/lib").filter((file) =>
    read(file).includes("selectionPolicyAdoption"),
  );
  assert.deepEqual(
    offenders,
    [],
    `the client must not write the native-owned policy document: ${offenders.join(", ")}`,
  );
});

test("the composition composes the fail-closed actions by default", () => {
  const source = read(composition);

  // The default composition changes nothing and says so, instead of reporting
  // an adoption that no durable owner performed.
  assert.match(
    source,
    /const SelectionPolicyComposition\.unavailable\(\)[\s\S]*?actions = const UnavailableSelectionPolicyActions\(\)/u,
  );
  assert.match(source, /abstract interface class SelectionPolicySource/u);
  assert.match(source, /abstract interface class SelectionFactsSource/u);
  // An unreadable read is a failure carrying a reason, never an empty success.
  assert.match(source, /selectionFactsSourceAbsentCode/u);
  assert.match(source, /PresentationPhase\.failed/u);
});

test("the client contract composes or refuses; it never invents a policy", () => {
  const compositionSource = read(composition);
  const viewSource = read(`${selectionRoot}/selection_policy_view.dart`);
  const sectionSource = read(`${selectionRoot}/selection_policy_section.dart`);

  // Refusals carry the durable owner's own reason code through to the reader
  // instead of being swallowed into a generic failure.
  assert.match(viewSource, /SelectionPolicyOutcome\.refused\(String reasonCode\)/u);
  assert.match(sectionSource, /selectionPolicyRefused\(_refusalCode!\)/u);
  assert.match(sectionSource, /selectionPolicyOwnerAbsentCode/u);
  assert.match(compositionSource, /selectionPolicyOwnerAbsentCode/u);

  // A dismissal is accepted and the current policy stays in force.
  assert.match(sectionSource, /selectionPolicyKeptCurrent/u);
});
