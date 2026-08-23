#!/usr/bin/env node
import { readdirSync } from "node:fs";
import { extname, join, resolve } from "node:path";
import { adapterIds, parseJson, privacyFindings, redactionSecrets, scenarioClasses, transcriptHash } from "./shared.mjs";

const corpusRoot = resolve(process.argv[2] || "tests/replay-corpus");
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
for (const file of files) {
  const document = parseJson(file);
  if (document.schemaVersion !== "lico.adapter-transcript.v1") continue;
  fixtures += 1;
  if (!adapterIds.includes(document.adapterId)) findings.push(`${file}:adapter_unknown`);
  if (!scenarioClasses.includes(document.scenario)) findings.push(`${file}:scenario_unknown`);
  if (document.provenance?.source !== "developer-run-real-agent-session") findings.push(`${file}:recording_provenance_missing`);
  if (document.provenance?.taskContent !== "synthetic-engineering-only") findings.push(`${file}:synthetic_provenance_missing`);
  if (document.provenance?.redacted !== true) findings.push(`${file}:redaction_not_attested`);
  if (document.provenance?.humanReviewed !== true || document.review?.status !== "approved") findings.push(`${file}:human_review_missing`);
  if (!Object.values(document.review?.checklist || {}).every((value) => value === true)) findings.push(`${file}:review_checklist_incomplete`);
  if (document.redaction?.contentSha256 !== transcriptHash(document)) findings.push(`${file}:content_hash_mismatch`);
  for (const finding of privacyFindings(document, redactionSecrets())) findings.push(`${file}:${finding.code}@${finding.path}`);
}
if (findings.length > 0) {
  process.stderr.write(`${findings.join("\n")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`redaction scan passed: ${fixtures} approved transcript fixtures, zero findings\n`);
}
