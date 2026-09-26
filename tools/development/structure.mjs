import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../..", import.meta.url));
export function sourceRisk(file, text, changed) {
  if (!/\.(?:rs|dart|mjs|cjs|js|ts|tsx|jsx|py|swift|kt|go)$/u.test(file)) return null;
  if (/\.(?:g|freezed)\.dart$|(?:^|\/)generated\//u.test(file) ||
      /(?:@generated|DO NOT EDIT|GENERATED CODE)/i.test(text.slice(0, 600))) return null;
  const lines = text.split("\n").length - Number(text.endsWith("\n"));
  if (lines <= 800) return null;
  return { file, line: 801, lines, severity: lines > 1000 ? "HIGH RISK" : "REVIEW",
    changed, guide: "crates/licoup-native/resources/licoup-refactor/SKILL.md" };
}

export function scanStructure({ all = false, cwd = root } = {}) {
  const git = (args) => execFileSync("git", args, { cwd, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }).split("\0").filter(Boolean);
  const candidates = new Set(git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]));
  const changed = new Set([...git(["diff", "--name-only", "-z", "HEAD"]), ...git(["ls-files", "-z", "--others", "--exclude-standard"])]);
  const findings = [];
  for (const file of candidates) {
    if ((!all && !changed.has(file)) || !existsSync(path.join(cwd, file))) continue;
    if (!/\.(?:rs|dart|mjs|cjs|js|ts|tsx|jsx|py|swift|kt|go)$/u.test(file)) continue;
    const risk = sourceRisk(file, readFileSync(path.join(cwd, file), "utf8"), changed.has(file));
    if (risk) findings.push(risk);
  }
  return findings.sort((a, b) => b.lines - a.lines || a.file.localeCompare(b.file));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.slice(2).some((arg) => arg !== "--all")) throw new Error("Only --all is supported");
  const findings = scanStructure({ all: process.argv.includes("--all") });
  const report = "build/reports/source-structure.json";
  mkdirSync(path.join(root, "build/reports"), { recursive: true });
  writeFileSync(path.join(root, report), JSON.stringify({ observedAt: new Date().toISOString(), findings }, null, 2) + "\n");
  for (const finding of findings) {
    const label = finding.severity === "HIGH RISK" && process.stdout.isTTY ? "\x1b[31mHIGH RISK\x1b[0m" : finding.severity;
    process.stdout.write(`${label} ${finding.file}:${finding.line} (${finding.lines} lines)\n`);
  }
  process.stdout.write(`Review ${findings.length} findings using docs/CLOSURE.md; report: ${report}\n`);
}
