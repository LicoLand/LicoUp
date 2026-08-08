#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { stableReadFile } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function source(ref) {
  return stableReadFile(path.join(repoRoot, ref), {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8");
}

const acceptanceConfig = JSON.parse(source(
  "tools/scripts/config/client-release-acceptance.json",
));
const userPresence = [
  source("tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs"),
  source("tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof/report.mjs"),
  source("tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof/run.mjs"),
].join("\n");
const writer = source("tools/scripts/lib/safe-report-io.mjs");
const writerTest = source("tools/scripts/client-release-artifact-io-self-test.mjs");
const additionalFirstPartyReportProducers = [
  {
    facade: "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    authority: "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof/report.mjs",
  },
  {
    facade: "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
    authority: "tools/scripts/client-secure-mesh-release-proof-bundle/run.mjs",
  },
  {
    facade: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
    authority: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle/run.mjs",
  },
  {
    facade: "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
    authority: "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
  },
  {
    facade: "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
    authority: "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
  },
];

const producerAuthorityByFacade = Object.freeze({
  "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs":
    "tools/scripts/client-secure-mesh-pairwise-content-audit/run.mjs",
  "tools/scripts/client-artifact-verification-receipts.mjs":
    "tools/scripts/client-artifact-verification-receipts/run.mjs",
});

for (const id of acceptanceConfig.reportOrder) {
  const producerRef = acceptanceConfig.reports[id].producer;
  const authorityRef = producerAuthorityByFacade[producerRef] || producerRef;
  const producer = source(authorityRef);
  requireValue(producer.includes("atomicWriteReportJson") &&
    !producer.includes("fs.writeFile(path.join(repoRoot, reportPath)") &&
    !producer.includes("fs.writeFileSync(absolutePath"),
    `closure_producer_does_not_use_safe_atomic_writer:${id}`);
}
for (const producer of additionalFirstPartyReportProducers) {
  const authority = source(producer.authority);
  requireValue(
    authority.includes("atomicWriteReportJson") &&
      authority.includes("assertNoLeak") &&
      !authority.includes("fs.writeFile(path.join(repoRoot, reportPath)") &&
      !authority.includes("writeFileSync(target, `${JSON.stringify(report"),
    `first_party_report_producer_is_not_bounded_atomic_and_no_plaintext:${producer.facade}`,
  );
}
requireValue(userPresence.includes(
  "atomicWriteReportJson(repoRoot, configuredReportRef, report)",
) && userPresence.includes("normalizeReportReference"),
"macos_user_presence_does_not_use_safe_atomic_writer");
requireValue(userPresence.includes('!ref.startsWith("build/")') &&
  userPresence.includes("path.isAbsolute(ref)"),
"macos_user_presence_absolute_output_not_rejected");
requireValue(writer.includes("beforePublish") &&
  writer.includes("report directory changed before atomic publication") &&
  writer.includes("report JSON exceeds the byte bound"),
"safe_report_writer_has_no_prepublication_identity_check");
requireValue(writerTest.includes("report_parent_symlink_swap_accepted"),
  "safe_report_writer_symlink_swap_negative_test_missing");

console.log(JSON.stringify({
  ok: true,
  caseCount: acceptanceConfig.reportOrder.length + 4 +
    additionalFirstPartyReportProducers.length,
  reportOrderProducerCount: acceptanceConfig.reportOrder.length,
  additionalFirstPartyReportProducerCount:
    additionalFirstPartyReportProducers.length,
  privatePathsIncluded: false,
}));
