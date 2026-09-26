import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const dataFile = /\.(?:mdx?|jsonl?|html?|log|txt|csv|xml|ya?ml|png|jpe?g|webp|pdf)$/iu;

// Heuristics complement source review: arbitrary prose cannot prove its own audience.
export function localArtifactReason(file, source = "") {
  if (!dataFile.test(file) || /\.schema\.json$/u.test(file)) return null;
  if (/(?:^|\/)(?:fixtures?|examples?)\//u.test(file) &&
      /synthetic|fictional|"fixture"\s*:\s*true/iu.test(source)) return null;
  if (/(?:^|\/)(?:plans?|reports?|coverage|test-results|playwright-report|screenshots?)\//iu.test(file)) {
    return "local-artifact-directory";
  }
  const name = path.posix.basename(file);
  if (/^(?:plan|report|progress|blockers?|handoff|test-results|benchmark-results)(?:[._-]|$)/iu.test(name) ||
      /(?:^|[-_])(?:report|results|plan)\.(?:md|json|html|csv|xml|txt)$/iu.test(name) ||
      /\.log$/u.test(name)) return "local-artifact-name";
  if (/\.mdx?$/u.test(file) && /^#\s+(?:(?:local|development|test|benchmark|audit|acceptance|progress|implementation)\s+)+(?:report|plan|results|status)\b/imu.test(source)) {
    return "local-work-document";
  }
  return null;
}

export function inspectCandidate(repoRoot = root) {
  const git = (args) => execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const files = [...new Set(git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]).split("\0").filter(Boolean))];
  const staged = new Set(git(["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"]).split("\0").filter(Boolean));
  const findings = [];
  for (const file of files) {
    if (!dataFile.test(file)) continue;
    if (existsSync(path.join(repoRoot, file))) {
      const reason = localArtifactReason(file, /\.(?:png|jpe?g|webp|pdf)$/iu.test(file) ? "" : readFileSync(path.join(repoRoot, file), "utf8"));
      if (reason) findings.push({ file, snapshot: "worktree", reason });
    }
    if (staged.has(file)) {
      const reason = localArtifactReason(file, git(["show", `:${file}`]));
      if (reason) findings.push({ file, snapshot: "index", reason });
    }
  }
  return { inspected: files.length, findings };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = inspectCandidate();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = result.findings.length ? 1 : 0;
}
