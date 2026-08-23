#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { assertAdapterAndScenario, deepRedact, parseJson, privacyFindings, redactionSecrets, schemaVersion, transcriptHash } from "./shared.mjs";

const [inputArg, outputArg] = process.argv.slice(2);
if (!inputArg || !outputArg) throw new Error("usage: redact.mjs <private-raw.json> <candidate.json>");
const input = parseJson(resolve(inputArg));
if (input.schemaVersion !== schemaVersion) throw new Error("transcript_schema_invalid");
assertAdapterAndScenario(input.adapterId, input.scenario);
if (input.provenance?.source !== "developer-run-real-agent-session" || input.provenance?.taskContent !== "synthetic-engineering-only") {
  throw new Error("transcript_provenance_invalid");
}
const workspace = input.invocation?.cwd;
const document = deepRedact(input, workspace);
document.provenance = {
  source: "developer-run-real-agent-session",
  taskContent: "synthetic-engineering-only",
  redacted: true,
  humanReviewed: false,
};
document.review = {
  status: "pending-human-review",
  checklist: {
    syntheticTaskConfirmed: false,
    noUserConversation: false,
    pathsAndIdentityChecked: false,
    framesMatchProtocolCapture: false,
    projectionsMatchParserOutput: false,
  },
};
document.redaction = {
  algorithm: "lico-transcript-redaction-v1",
  contentSha256: "",
};
document.redaction.contentSha256 = transcriptHash(document);
const findings = privacyFindings(document, redactionSecrets());
if (findings.length > 0) {
  throw new Error(`redaction_incomplete:${findings.map(({ code, path }) => `${code}@${path}`).join(",")}`);
}
const output = resolve(outputArg);
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, `${JSON.stringify(document, null, 2)}\n`, { flag: "wx" });
process.stdout.write(`${document.redaction.contentSha256}\n`);
