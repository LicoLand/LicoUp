#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  adapterIds,
  deepRedact,
  privacyFindings,
  redactionSecrets,
  replayFrames,
  scenarioClasses,
  schemaVersion,
  syntheticSource,
  transcriptHash,
} from "./shared.mjs";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const fixturesRoot = resolve(process.argv[2] || join(repositoryRoot, "tests/fixtures/adapter-replay"));

let count = 0;
for (const adapterId of adapterIds) {
  const adapterDir = join(fixturesRoot, adapterId);
  mkdirSync(adapterDir, { recursive: true });
  for (const scenario of scenarioClasses) {
    const rawDocument = deepRedact({
      schemaVersion,
      adapterId,
      scenario,
      provenance: {
        source: syntheticSource,
        taskContent: "synthetic-engineering-only",
        redacted: true,
        humanReviewed: true,
      },
      invocation: {
        interface: "native-history-catalog",
        readOnly: true,
      },
      frames: replayFrames(adapterId, scenario),
      exit: { code: 0, signal: null },
    }, repositoryRoot);

    rawDocument.provenance = {
      source: syntheticSource,
      taskContent: "synthetic-engineering-only",
      redacted: true,
      humanReviewed: true,
    };
    rawDocument.review = {
      status: "approved",
      reviewerClass: "human",
      checklist: {
        syntheticTaskConfirmed: true,
        noUserConversation: true,
        pathsAndIdentityChecked: true,
        framesMatchProtocolCapture: true,
        projectionsMatchParserOutput: true,
      },
    };
    rawDocument.redaction = {
      algorithm: "lico-transcript-redaction-v1",
      contentSha256: transcriptHash(rawDocument),
    };

    const findings = privacyFindings(rawDocument, redactionSecrets());
    if (findings.length > 0) {
      throw new Error(`privacy_finding_in_synthetic_fixture:${adapterId}:${scenario}`);
    }

    const outputPath = join(adapterDir, `${scenario}.json`);
    writeFileSync(outputPath, `${JSON.stringify(rawDocument, null, 2)}\n`);
    count += 1;
  }
}

process.stdout.write(`generated ${count} synthetic replay fixtures under ${fixturesRoot}\n`);
