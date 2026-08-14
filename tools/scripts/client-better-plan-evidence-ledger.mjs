#!/usr/bin/env node
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  BETTER_PLAN_EVIDENCE_LEDGER_SCHEMA,
  DEFAULT_BETTER_PLAN_MANIFEST_REF,
  evaluateBetterPlanEvidenceLedger,
  isSafeRepositoryRelativePath
} from "./lib/better-plan-evidence-ledger.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
process.stdout.on("error", (error) => {
  if (error?.code === "EPIPE") {
    process.exit(1);
  }
  console.error(JSON.stringify({ ok: false, redacted: true, error: "stdout-write-failed" }));
  process.exit(1);
});
const rawArgs = process.argv.slice(2);
let reportOnly = false;
let selfTest = false;
let outputRef = null;
let argumentError = null;
for (let index = 0; index < rawArgs.length; index += 1) {
  const arg = rawArgs[index];
  if (arg === "--report-only") {
    reportOnly = true;
  } else if (arg === "--self-test") {
    selfTest = true;
  } else if (arg === "--output") {
    outputRef = rawArgs[index + 1] || null;
    index += 1;
    if (!outputRef) {
      argumentError = "missing-output-ref";
    }
  } else {
    argumentError = "unknown-argument";
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fixturePlan(checkpointRef = "sample/Checkpoints.json") {
  return [
    {
      id: "11111111-1111-4111-8111-111111111111",
      status: "completed",
      title: "Fixture plan",
      directory: "sample",
      source_files: ["docs/plan/sample/Plan.md"],
      goal: "Exercise evidence ledger behavior.",
      description: "Synthetic, redacted self-test fixture.",
      checkpoints: checkpointRef
    }
  ];
}

function fixtureNodes(evidenceRef) {
  return [
    {
      id: "22222222-2222-4222-8222-222222222222",
      status: "completed",
      role: "final_validation",
      prerequisites: [],
      platform: "any",
      difficulty: "high",
      goal: "Prove the fixture.",
      description: "Synthetic, redacted self-test fixture.",
      acceptance_criteria: [
        {
          checked: true,
          text: "The synthetic evidence is reproducible.",
          evidence_refs: [evidenceRef]
        }
      ],
      commit: {
        repository: ".git",
        message: "test: fixture",
        target: "fixture"
      },
      next: []
    }
  ];
}

async function writeJson(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function runSelfTest() {
  const fixtureRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lico-better-plan-ledger-"));
  const manifestPath = path.join(fixtureRoot, DEFAULT_BETTER_PLAN_MANIFEST_REF);
  const checkpointsPath = path.join(fixtureRoot, "docs/plan/sample/Checkpoints.json");
  const evidencePath = path.join(fixtureRoot, "evidence/proof.txt");
  const validTimestamp = "2026-01-02T03:04:05Z";
  const validCommandRef = {
    type: "command",
    command: "node --version",
    exit_code: 0,
    recorded_at: validTimestamp
  };
  const scenarios = [];
  const expect = async (name, expectedReady, expectedCode, prepare) => {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
    await fs.mkdir(path.dirname(evidencePath), { recursive: true });
    await fs.writeFile(path.join(fixtureRoot, "package.json"), '{"scripts":{"client:test":"true"}}\n');
    await fs.writeFile(evidencePath, "synthetic-proof\n", "utf8");
    await writeJson(manifestPath, fixturePlan());
    await writeJson(checkpointsPath, fixtureNodes({
      type: "file",
      path: "evidence/proof.txt",
      sha256: sha256("synthetic-proof\n"),
      recorded_at: validTimestamp
    }));
    await prepare?.({ fixtureRoot, manifestPath, checkpointsPath, evidencePath });
    const report = await evaluateBetterPlanEvidenceLedger({ repoRoot: fixtureRoot });
    if (report.ready !== expectedReady) {
      const error = new Error("unexpected-readiness");
      error.scenario = name;
      error.issueCodes = report.issues.map((issue) => issue.code);
      throw error;
    }
    if (expectedCode && !report.issues.some((issue) => issue.code === expectedCode)) {
      const error = new Error("expected-issue-code-absent");
      error.scenario = name;
      throw error;
    }
    scenarios.push(name);
  };

  try {
    await expect("valid-file-reference", true, null);
    await expect("valid-command-reference", true, null, async ({ checkpointsPath: ref }) => {
      await writeJson(ref, fixtureNodes(validCommandRef));
    });
    await expect("missing-reference", false, "missing_evidence_refs", async ({ checkpointsPath: ref }) => {
      const nodes = fixtureNodes(validCommandRef);
      delete nodes[0].acceptance_criteria[0].evidence_refs;
      await writeJson(ref, nodes);
    });
    await expect("free-text-only", false, "free_text_only_evidence", async ({ checkpointsPath: ref }) => {
      const nodes = fixtureNodes(validCommandRef);
      delete nodes[0].acceptance_criteria[0].evidence_refs;
      nodes[0].acceptance_criteria[0].evidence = "Synthetic prose is not a machine-verifiable reference.";
      await writeJson(ref, nodes);
    });
    await expect("tampered-file", false, "evidence_file_digest_mismatch", async ({ evidencePath: ref }) => {
      await fs.writeFile(ref, "tampered\n", "utf8");
    });
    await expect("absolute-path", false, "unsafe_evidence_file_path", async ({ checkpointsPath: ref }) => {
      const nodes = fixtureNodes({
        type: "file",
        path: path.join(path.parse(fixtureRoot).root, "outside-proof.txt"),
        sha256: sha256("synthetic-proof\n"),
        recorded_at: validTimestamp
      });
      await writeJson(ref, nodes);
    });
    await expect("failed-command", false, "evidence_command_failed", async ({ checkpointsPath: ref }) => {
      await writeJson(ref, fixtureNodes({ ...validCommandRef, exit_code: 1 }));
    });
    await expect("private-command", false, "privacy_leak", async ({ checkpointsPath: ref }) => {
      const sensitiveName = ["ACCESS", "TOKEN"].join("_");
      const sensitiveValue = ["fixture", "credential"].join("-");
      await writeJson(ref, fixtureNodes({
        ...validCommandRef,
        command: `${sensitiveName}=${sensitiveValue} node --version`
      }));
    });
    await expect("dangling-checkpoint", false, "dangling_checkpoint_ref", async ({ manifestPath: ref }) => {
      await writeJson(ref, fixturePlan("missing/Checkpoints.json"));
    });
    await expect("dangling-file", false, "dangling_evidence_file_ref", async ({ checkpointsPath: ref }) => {
      await writeJson(ref, fixtureNodes({
        type: "file",
        path: "evidence/missing.txt",
        sha256: sha256("synthetic-proof\n"),
        recorded_at: validTimestamp
      }));
    });
    await expect("unknown-reference-type", false, "unknown_evidence_ref_type", async ({ checkpointsPath: ref }) => {
      await writeJson(ref, fixtureNodes({ type: "receipt", recorded_at: validTimestamp }));
    });
    await expect("duplicate-reference", false, "duplicate_evidence_ref", async ({ checkpointsPath: ref }) => {
      const nodes = fixtureNodes(validCommandRef);
      nodes[0].acceptance_criteria[0].evidence_refs.push({ ...validCommandRef });
      await writeJson(ref, nodes);
    });
    await expect("invalid-timestamp", false, "invalid_evidence_timestamp", async ({ checkpointsPath: ref }) => {
      await writeJson(ref, fixtureNodes({ ...validCommandRef, recorded_at: "not-a-timestamp" }));
    });
  } finally {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
  }

  return {
    ok: true,
    redacted: true,
    scenarioCount: scenarios.length,
    scenarios
  };
}

if (argumentError) {
  console.error(JSON.stringify({ ok: false, redacted: true, error: argumentError }));
  process.exit(2);
}
if (selfTest && (reportOnly || outputRef)) {
  console.error(JSON.stringify({ ok: false, redacted: true, error: "conflicting-modes" }));
  process.exit(2);
}
if (outputRef && !isSafeRepositoryRelativePath(outputRef)) {
  console.error(JSON.stringify({ ok: false, redacted: true, error: "unsafe-output-ref" }));
  process.exit(2);
}

if (selfTest) {
  try {
    console.log(JSON.stringify(await runSelfTest(), null, 2));
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      redacted: true,
      error: "self-test-failed",
      failureCode: ["unexpected-readiness", "expected-issue-code-absent"].includes(error?.message)
        ? error.message
        : "unexpected",
      scenario: typeof error?.scenario === "string" ? error.scenario : "unknown",
      issueCodes: Array.isArray(error?.issueCodes) ? error.issueCodes : []
    }));
    process.exit(1);
  }
} else {
  let report;
  try {
    report = await evaluateBetterPlanEvidenceLedger({ repoRoot });
  } catch {
    report = {
      schema: BETTER_PLAN_EVIDENCE_LEDGER_SCHEMA,
      generatedBy: "tools/scripts/client-better-plan-evidence-ledger.mjs",
      redacted: true,
      ready: false,
      summary: { completionGapCount: 0, failureCount: 1, issuesByCode: { internal_error: 1 } },
      issues: [{ code: "internal_error" }]
    };
  }
  const renderedReport = { ...report, mode: reportOnly ? "report-only" : "strict" };
  const serializedReport = `${JSON.stringify(renderedReport, null, 2)}\n`;
  if (outputRef) {
    const outputPath = path.resolve(repoRoot, ...outputRef.split("/"));
    await fs.mkdir(path.dirname(outputPath), { recursive: true });
    await fs.writeFile(outputPath, serializedReport, "utf8");
  }
  const consoleReport = outputRef
    ? {
        schema: renderedReport.schema,
        redacted: true,
        ready: renderedReport.ready,
        mode: renderedReport.mode,
        report: outputRef,
        summary: renderedReport.summary
      }
    : renderedReport;
  process.stdout.write(`${JSON.stringify(consoleReport, null, 2)}\n`);
  if (!reportOnly && !report.ready) {
    process.exitCode = 1;
  }
}
