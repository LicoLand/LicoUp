#!/usr/bin/env node
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { privacyFindings, transcriptHash } from "./shared.mjs";

const directory = mkdtempSync(join(tmpdir(), "lico-transcript-pipeline-"));
const raw = join(directory, "raw.json");
const candidate = join(directory, "candidate.json");
const run = (script, args, env = process.env) => {
  const result = spawnSync(process.execPath, [resolve(import.meta.dirname, script), ...args], {
    cwd: resolve(import.meta.dirname, "../../.."),
    env,
    encoding: "utf8",
    input: "",
  });
  if (result.status !== 0) throw new Error(`${script}_failed:${result.stderr.trim()}`);
};

try {
  run("record.mjs", [
    "--adapter", "codex",
    "--scenario", "normal-turn",
    "--output", raw,
    "--",
    process.execPath,
    "-e",
    "process.stdout.write(JSON.stringify({type:'result',cwd:process.cwd(),role:'user'})+'\\n')",
  ], { ...process.env, LICO_TRANSCRIPT_SYNTHETIC_ACK: "1" });
  run("redact.mjs", [raw, candidate]);
  run("review.mjs", [
    candidate,
    "--approve",
    "--synthetic-task-confirmed",
    "--no-user-conversation",
    "--paths-and-identity-checked",
    "--frames-match-capture",
    "--projections-match-parser",
  ]);
  const reviewed = JSON.parse(readFileSync(candidate, "utf8"));
  if (reviewed.review?.status !== "approved") throw new Error("review_attestation_missing");
  if (reviewed.redaction?.contentSha256 !== transcriptHash(reviewed)) throw new Error("content_hash_mismatch");
  if (privacyFindings(reviewed).length > 0) throw new Error("privacy_finding_after_redaction");
  process.stdout.write("transcript pipeline self-test passed\n");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
