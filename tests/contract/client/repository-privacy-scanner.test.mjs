import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { parseAuditorResult, parseScanOptions, runAuditorScan, runAuditorReview } from "../../../tools/scripts/repo-local-info-hygiene.mjs";

test("the public scanner receives the candidate and only public CLI options", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "public-auditor-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const command = path.join(root, "auditor");
  await writeFile(command, `#!/usr/bin/env node
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    fs.writeFileSync('arguments.json', JSON.stringify(args));
    const report = args[args.indexOf('--html-report') + 1];
    fs.mkdirSync(require('node:path').dirname(report), { recursive: true });
    fs.writeFileSync(report, '<!doctype html>');
    fs.writeFileSync(report.replace(/\\.html$/, '.review.md'), '# Pending Agent review');
    fs.writeFileSync(report.replace(/\\.html$/, '.scan.json'), '{}');
    console.log('[]');
  `, { mode: 0o755 });
  const first = await runAuditorScan(root, command);
  assert.equal(first.ok, true);
  assert.match(first.htmlReport, /^build\/reports\/privacy-audit\/audit-.+\.html$/u);
  assert.equal(first.reviewPrompt, first.htmlReport.replace(/\.html$/u, ".review.md"));
  assert.match(await readFile(path.join(root, first.reviewPrompt), "utf8"), /Pending Agent review/u);
  assert.deepEqual(JSON.parse(await readFile(path.join(root, "arguments.json"))), [
    "gate", "--repo", root, "--profile", "licoup", "--no-contribution", "--format", "json",
    "--html-report", path.join(root, first.htmlReport), "--local-evidence",
  ]);
  for (const args of [["--base", "main"], ["--base", "main", "--head", "HEAD"], ["--all-candidates"],
    ["--scope", "history", "--all-refs", "--full-history"],
    ["--scope", "history", "--ref", "main", "--max-commits", "3"]]) {
    const result = await runAuditorScan(root, command, parseScanOptions(args));
    assert.equal(result.ok, true);
    assert.deepEqual(JSON.parse(await readFile(path.join(root, "arguments.json"))), [
      "gate", "--repo", root, "--profile", "licoup", "--no-contribution", "--format", "json",
      "--html-report", path.join(root, result.htmlReport), "--local-evidence", ...args,
    ]);
  }
});

test("a scanner that omits the promised HTML report cannot claim completion", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "public-auditor-report-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const command = path.join(root, "auditor");
  await writeFile(command, "#!/usr/bin/env node\nconsole.log('[]');\n", { mode: 0o755 });
  const result = await runAuditorScan(root, command);
  assert.equal(result.ok, false);
  assert.equal(result.failures[0].reasonCode, "AUDITOR_REPORT_MISSING");
  await writeFile(command, `#!/usr/bin/env node
    const fs = require('node:fs');
    const report = process.argv[process.argv.indexOf('--html-report') + 1];
    fs.mkdirSync(require('node:path').dirname(report), {recursive:true});
    fs.writeFileSync(report, '<!doctype html>');
    console.log('[]');
  `, { mode: 0o755 });
  assert.equal((await runAuditorScan(root, command)).failures[0].reasonCode, "AUDITOR_REPORT_MISSING");
});

test("incomplete or mixed comparison scopes never fall back to a wider scan", () => {
  for (const args of [["--head", "HEAD"], ["--base"], ["--history"], ["--all-candidates", "--base", "main"],
    ["--all-refs"], ["--scope", "history", "--ref", "main", "--all-refs"],
    ["--scope", "history", "--base", "main"], ["--scope", "unknown"],
    ["--scope", "history", "--max-commits", "invalid"]]) {
    assert.throws(() => parseScanOptions(args));
  }
});

test("high-risk findings require review without becoming automatic rejections", () => {
  const finding = { severity: "high-risk", rule: "inline-secret", path: "fixture.txt",
    line: 7, fingerprint: "a".repeat(16), message: "synthetic-sensitive-value" };
  const result = parseAuditorResult(JSON.stringify([finding]), 0, process.cwd());
  assert.equal(result.ok, true);
  assert.equal(result.warnings[0].line, 7);
  assert.equal(result.warnings[0].severity, "high-risk");
  assert.equal(JSON.stringify(result).includes(finding.message), false);
  assert.equal(parseAuditorResult(JSON.stringify([finding]), 1, process.cwd()).failures[0].reasonCode,
    "AUDITOR_PROTOCOL_ERROR");
  const failedExecution = { ...finding, severity: "error", rule: "candidate-unreadable" };
  assert.equal(parseAuditorResult(JSON.stringify([failedExecution]), 1, process.cwd()).ok, false);
});

test("warnings remain visible and unsafe or malformed findings fail closed", () => {
  const finding = { severity: "warning", rule: "review-needed", path: "fixture.txt", line: 0, fingerprint: "" };
  const warning = parseAuditorResult(JSON.stringify([finding]), 0, process.cwd());
  assert.equal(warning.ok, true);
  assert.equal(warning.warnings.length, 1);
  for (const invalid of [null, {}, [{ ...finding, path: "../outside" }], [{ ...finding, severity: "unknown" }]]) {
    assert.equal(parseAuditorResult(JSON.stringify(invalid), 0, process.cwd()).ok, false);
  }
});


test("review completion calls the finalizer and cannot accept an unreviewed scan", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "auditor-complete-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const command = path.join(root, "auditor");
  const options = parseScanOptions(["--complete-review", "scan.json", "--review-result", "review.json"]);
  await writeFile(command, `#!/usr/bin/env node
    const fs = require('node:fs');
    fs.writeFileSync('arguments.json', JSON.stringify(process.argv.slice(2)));
    fs.writeFileSync('final.html', '<!doctype html>');
    console.log(JSON.stringify({status:'passed', review_complete:true, html_report:'final.html',
      counts:{confirmed:0,false_positive:1,uncertain:0}}));
  `, {mode:0o755});
  const result = await runAuditorReview(root, options, command);
  assert.equal(result.reviewRequired, false);
  assert.equal(result.agentReviewStatus, "completed");
  assert.deepEqual(JSON.parse(await readFile(path.join(root, "arguments.json"))), [
    "complete-review", "--repo", root, "--scan", path.join(root, "scan.json"),
    "--review", path.join(root, "review.json"),
  ]);
  await writeFile(command, "#!/usr/bin/env node\nconsole.log(JSON.stringify({status:'review_required'}));\n", {mode:0o755});
  await assert.rejects(runAuditorReview(root, options, command));
  assert.throws(() => parseScanOptions(["--complete-review", "scan.json"]));
  assert.throws(() => parseScanOptions(["--complete-review", "scan.json", "--review-result", "review.json", "--all-candidates"]));
});
