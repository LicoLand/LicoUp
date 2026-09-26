#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { access, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const reportRef = "build/reports/repo-local-info-hygiene.json";
const reportPath = path.join(repoRoot, reportRef);
const schemaVersion = "licomesh.repo-local-info-hygiene.v1";
function sha256(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}

function safeRelativePath(root, candidate) {
  const relative = path.isAbsolute(candidate) ? path.relative(root, candidate) : candidate;
  const normalized = relative.split(path.sep).join("/");
  if (
    normalized === "." ||
    (
      normalized.length > 0 &&
      !normalized.startsWith("/") &&
      !normalized.startsWith("../") &&
      normalized !== ".." &&
      !/^[A-Za-z]:/u.test(normalized) &&
      !normalized.includes("\0") &&
      path.posix.normalize(normalized) === normalized
    )
  ) {
    return normalized;
  }
  return null;
}

function redactedFailure(reasonCode, relativePath, privateDetail = "") {
  return {
    reasonCode,
    path: relativePath,
    digest: sha256(`${reasonCode}\0${relativePath}\0${String(privateDetail)}`)
  };
}

function scannerFailure(reasonCode, detail = "") {
  return { ok: false, failures: [redactedFailure(reasonCode, ".", detail)], warnings: [] };
}

export function parseAuditorResult(stdout, exitCode, scanRoot) {
  let findings;
  try { findings = JSON.parse(stdout); } catch {
    return scannerFailure("AUDITOR_PROTOCOL_ERROR", stdout);
  }
  if (!Array.isArray(findings)) return scannerFailure("AUDITOR_PROTOCOL_ERROR", stdout);
  const failures = [];
  const warnings = [];
  for (const finding of findings) {
    if (!finding || typeof finding !== "object" ||
        !["error", "high-risk", "warning", "info"].includes(finding.severity) ||
        typeof finding.rule !== "string" || !/^[a-z0-9-]+$/u.test(finding.rule) ||
        typeof finding.path !== "string" ||
        !Number.isInteger(finding.line) || finding.line < 0 ||
        typeof finding.fingerprint !== "string" ||
        (finding.fingerprint !== "" && !/^[a-f0-9]{16,64}$/u.test(finding.fingerprint))) {
      return scannerFailure("AUDITOR_UNSAFE_OUTPUT", stdout);
    }
    const relative = safeRelativePath(scanRoot, finding.path || ".");
    if (!relative) return scannerFailure("AUDITOR_UNSAFE_OUTPUT", stdout);
    const item = {
      reasonCode: `AUDITOR_${finding.rule.replaceAll("-", "_").toUpperCase()}`,
      path: relative,
      line: finding.line,
      digest: finding.fingerprint || sha256(JSON.stringify(finding)),
    };
    if (finding.severity === "error") failures.push(item);
    else warnings.push({ ...item, severity: finding.severity });
  }
  if (exitCode !== (failures.length > 0 ? 1 : 0)) {
    return scannerFailure("AUDITOR_PROTOCOL_ERROR", stdout);
  }
  return { ok: failures.length === 0, failures, warnings };
}

export async function runAuditorScan(scanRoot, command = process.env.LICO_AUDITOR_PATH
  ? path.resolve(process.env.LICO_AUDITOR_PATH, "bin/lico-auditor") : "lico-auditor", options = {}) {
  const htmlRef = `build/reports/privacy-audit/audit-${new Date().toISOString().replaceAll(":", "-")}-${process.pid}.html`;
  const htmlPath = path.join(scanRoot, htmlRef);
  let stdout = "";
  let exitCode = 0;
  try {
    const result = await execFileAsync(command, [
      "gate", "--repo", scanRoot, "--profile", "licoup", "--no-contribution", "--format", "json",
      "--html-report", htmlPath,
      "--local-evidence",
      ...scanArguments(options),
    ], { cwd: scanRoot, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
    stdout = result.stdout;
  } catch (error) {
    if (error?.code === "ENOENT") return scannerFailure("AUDITOR_UNAVAILABLE");
    stdout = typeof error?.stdout === "string" ? error.stdout : "";
    exitCode = Number.isInteger(error?.code) ? error.code : -1;
  }
  const result = parseAuditorResult(stdout, exitCode, scanRoot);
  try {
    await access(htmlPath);
    const reviewPrompt = htmlRef.replace(/\.html$/u, ".review.md");
    await access(path.join(scanRoot, reviewPrompt));
    const scanSnapshot = htmlRef.replace(/\.html$/u, ".scan.json");
    await access(path.join(scanRoot, scanSnapshot));
    return { ...result, htmlReport: htmlRef, reviewPrompt, scanSnapshot };
  } catch {
    return result.ok ? scannerFailure("AUDITOR_REPORT_MISSING") : result;
  }
}

export function parseScanOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--all-candidates") options.allCandidates = true;
    else if (arg === "--all-refs") options.allRefs = true;
    else if (arg === "--full-history") options.fullHistory = true;
    else if (["--base", "--head", "--scope", "--ref", "--max-commits", "--complete-review", "--review-result"].includes(arg)) {
      const value = args[++index];
      if (!value || value.startsWith("-")) throw new Error("A comparison ref is required");
      options[arg.slice(2)] = value;
    } else throw new Error("Unsupported privacy scan option");
  }
  if (options["complete-review"] || options["review-result"]) {
    if (!options["complete-review"] || !options["review-result"] || Object.keys(options).length !== 2) {
      throw new Error("Complete an existing scan with its review result; do not mix scan options");
    }
    return options;
  }
  if (options.head && !options.base) throw new Error("A head requires a base");
  if (options.scope && !["changed", "worktree", "history"].includes(options.scope)) throw new Error("Unknown scan scope");
  if (options.allCandidates && (options.base || options.scope)) throw new Error("Choose one scan scope");
  const scope = options.allCandidates ? "worktree" : options.scope ?? "changed";
  if (scope !== "changed" && options.base) throw new Error("Comparison refs require changed scope");
  if (scope !== "history" && (options.allRefs || options.fullHistory || options.ref || options["max-commits"])) {
    throw new Error("History options require history scope");
  }
  if (options.allRefs && options.ref) throw new Error("Choose a ref or all refs");
  if (options["max-commits"] && !/^\d+$/u.test(options["max-commits"])) throw new Error("Invalid commit limit");
  return options;
}

function scanArguments(options) {
  return [
    ...(options.allCandidates ? ["--all-candidates"] : []),
    ...(options.base ? ["--base", options.base] : []),
    ...(options.head ? ["--head", options.head] : []),
    ...(options.scope ? ["--scope", options.scope] : []),
    ...(options.ref ? ["--ref", options.ref] : []),
    ...(options.allRefs ? ["--all-refs"] : []),
    ...(options.fullHistory ? ["--full-history"] : []),
    ...(options["max-commits"] ? ["--max-commits", options["max-commits"]] : []),
  ];
}

function buildReport(auditor, options) {
  const { failures, warnings } = auditor;
  return {
    schemaVersion,
    ok: failures.length === 0,
    executionStatus: failures.length === 0 ? "completed" : "failed",
    reviewRequired: true,
    agentReviewStatus: "pending",
    authoritativeScanner: "lico-auditor",
    scope: options.scope ?? (options.allCandidates ? "all-candidates" : options.head ? "commit-range" : "changed-candidate"),
    allRefs: options.allRefs ?? false,
    fullHistory: options.fullHistory ?? false,
    findingCount: failures.length + warnings.length,
    htmlReport: auditor.htmlReport ?? null,
    reviewPrompt: auditor.reviewPrompt ?? null,
    scanSnapshot: auditor.scanSnapshot ?? null,
    nextAction: "Review the scan using its reviewPrompt, then run --complete-review SCAN_JSON --review-result REVIEW_JSON.",
    failures,
    warnings,
  };
}

export async function runAuditorReview(scanRoot, options, command = process.env.LICO_AUDITOR_PATH
  ? path.resolve(process.env.LICO_AUDITOR_PATH, "bin/lico-auditor") : "lico-auditor") {
  let stdout;
  try {
    ({ stdout } = await execFileAsync(command, ["complete-review", "--repo", scanRoot,
      "--scan", path.resolve(scanRoot, options["complete-review"]),
      "--review", path.resolve(scanRoot, options["review-result"])],
    { cwd: scanRoot, encoding: "utf8", maxBuffer: 1024 * 1024 }));
  } catch (error) {
    stdout = typeof error?.stdout === "string" ? error.stdout : "";
  }
  let result;
  try { result = JSON.parse(stdout); } catch { throw new Error("Invalid review result"); }
  const htmlReport = typeof result.html_report === "string" && safeRelativePath(scanRoot, result.html_report);
  if (result.review_complete !== true || !["passed", "action_required", "incomplete"].includes(result.status) || !htmlReport) {
    throw new Error("Review did not produce a final report");
  }
  const counts = Object.fromEntries(["confirmed", "false_positive", "uncertain"].map((key) => {
    const value = result.counts?.[key];
    if (!Number.isInteger(value) || value < 0) throw new Error("Invalid review count");
    return [key, value];
  }));
  await access(path.join(scanRoot, htmlReport));
  return { schemaVersion, ok: result.status === "passed", auditStatus: result.status,
    reviewRequired: false, agentReviewStatus: "completed", htmlReport, counts };
}

async function runSelfTest() {
  const { default: assert } = await import("node:assert/strict");
  const root = await mkdtemp(path.join(tmpdir(), "lico-up-hygiene-test-"));
  try {
    assert.equal(parseAuditorResult("[]", 0, root).ok, true);
    assert.equal(parseAuditorResult("[]", 1, root).ok, false);
    assert.equal(parseAuditorResult("invalid", 0, root).ok, false);
    const finding = { severity: "high-risk", rule: "machine-path", path: "source.mjs",
      line: 2, fingerprint: sha256("synthetic"), message: "do not forward raw output" };
    const result = parseAuditorResult(JSON.stringify([finding]), 0, root);
    assert.equal(result.ok, true);
    assert.equal(result.warnings[0].line, 2);
    assert.equal(JSON.stringify(result).includes(finding.message), false);
    assert.equal(parseAuditorResult(JSON.stringify([{ ...finding, path: "../outside" }]), 0, root)
      .failures[0].reasonCode, "AUDITOR_UNSAFE_OUTPUT");
    assert.equal(parseAuditorResult(JSON.stringify([{ ...finding, severity: "warning" }]), 0, root).ok, true);
    assert.equal((await runAuditorScan(root, path.join(root, "missing-auditor"))).ok, false);
    assert.deepEqual(parseScanOptions([]), {});
    assert.deepEqual(parseScanOptions(["--base", "main", "--head", "HEAD"]), { base: "main", head: "HEAD" });
    return { schemaVersion, ok: true, checks: ["auditor-protocol", "redacted-output", "execution-failure", "change-scope"] };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

async function main() {
  if (process.argv.slice(2).includes("--self-test")) {
    console.log(JSON.stringify(await runSelfTest(), null, 2));
    return;
  }
  const options = parseScanOptions(process.argv.slice(2));
  const report = options["complete-review"] ? await runAuditorReview(repoRoot, options)
    : buildReport(await runAuditorScan(repoRoot, undefined, options), options);
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(report, null, 2));
  if (!report.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    console.error(JSON.stringify({ schemaVersion, ok: false, reasonCode: "HYGIENE_CHECK_FAILED" }));
    process.exitCode = 1;
  });
}
