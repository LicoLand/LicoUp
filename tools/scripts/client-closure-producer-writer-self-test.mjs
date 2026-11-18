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
const writer = source("tools/scripts/lib/safe-report-io.mjs");
const writerTest = source("tools/scripts/client-release-artifact-io-self-test.mjs");

// Desktop-owned producers that write release-closure report files. Each must
// use the canonical bounded atomic writer and reject absolute output refs.
const reportProducers = [
  {
    facade: "tools/scripts/client-artifact-verification-receipts.mjs",
    authority: "tools/scripts/client-artifact-verification-receipts/run.mjs",
  },
  {
    facade: "tools/scripts/client-release-acceptance.mjs",
    authority: "tools/scripts/client-release-acceptance/run.mjs",
  },
  {
    facade: "tools/scripts/client-macos-consumer-verification.mjs",
    authority: "tools/scripts/client-macos-consumer-verification.mjs",
  },
];

for (const id of acceptanceConfig.reportOrder || []) {
  const producerRef = acceptanceConfig.reports[id].producer;
  const producer = source(producerRef);
  requireValue(producer.includes("atomicWriteReportJson") &&
    !producer.includes("fs.writeFile(path.join(repoRoot, reportPath)") &&
    !producer.includes("fs.writeFileSync(absolutePath"),
    `closure_producer_does_not_use_safe_atomic_writer:${id}`);
}
for (const producer of reportProducers) {
  const authority = source(producer.authority);
  requireValue(
    authority.includes("atomicWriteReportJson") &&
      !authority.includes("fs.writeFile(path.join(repoRoot, reportPath)") &&
      !authority.includes("writeFileSync(target, `${JSON.stringify(report"),
    `first_party_report_producer_is_not_bounded_atomic:${producer.facade}`,
  );
}
requireValue(writer.includes("beforePublish") &&
  writer.includes("report directory changed before atomic publication") &&
  writer.includes("report JSON exceeds the byte bound"),
"safe_report_writer_has_no_prepublication_identity_check");
requireValue(writerTest.includes("report_parent_symlink_swap_accepted"),
  "safe_report_writer_symlink_swap_negative_test_missing");

console.log(JSON.stringify({
  ok: true,
  caseCount: (acceptanceConfig.reportOrder || []).length + 2 +
    reportProducers.length,
  reportOrderProducerCount: (acceptanceConfig.reportOrder || []).length,
  firstPartyReportProducerCount: reportProducers.length,
  privatePathsIncluded: false,
}));
