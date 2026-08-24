#!/usr/bin/env node
import { readdirSync } from "node:fs";
import { extname, join, resolve } from "node:path";
import {
  adapterIds,
  allowedSources,
  parseJson,
  privacyFindings,
  redactionSecrets,
  reviewApproved,
  scenarioClasses,
  transcriptHash,
} from "./shared.mjs";

const corpusArgument = process.argv.slice(2).find((argument) => !argument.startsWith("--"));
const corpusRoot = resolve(corpusArgument || "tests/replay-corpus");
const files = [];
const visit = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else if (entry.isFile() && extname(entry.name) === ".json" && entry.name !== "review-checklist.json") files.push(path);
  }
};
visit(corpusRoot);
const findings = [];
let fixtures = 0;
let pendingReviews = 0;
for (const file of files) {
  const document = parseJson(file);
  if (document.schemaVersion !== "lico.adapter-transcript.v1") continue;
  fixtures += 1;
  if (!adapterIds.includes(document.adapterId)) findings.push(`${file}:adapter_unknown`);
  if (!scenarioClasses.includes(document.scenario)) findings.push(`${file}:scenario_unknown`);
  if (!allowedSources.includes(document.provenance?.source)) findings.push(`${file}:ingestion_provenance_missing`);
  if (document.provenance?.taskContent !== "synthetic-engineering-only") findings.push(`${file}:synthetic_provenance_missing`);
  if (document.provenance?.redacted !== true) findings.push(`${file}:redaction_not_attested`);
  if (!reviewApproved(document)) pendingReviews += 1;
  if (document.redaction?.contentSha256 !== transcriptHash(document)) findings.push(`${file}:content_hash_mismatch`);
  for (const finding of privacyFindings(document, redactionSecrets())) findings.push(`${file}:${finding.code}@${finding.path}`);
}
if (findings.length > 0) {
  process.stderr.write(`${findings.join("\n")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`redaction scan passed: ${fixtures} transcript fixtures, zero privacy findings, ${pendingReviews} pending human review\n`);
  if (process.argv.includes("--require-reviewed") && pendingReviews > 0) {
    process.stderr.write(`human review required before commit: ${pendingReviews} fixture(s) pending\n`);
    process.exitCode = 1;
  }
}
