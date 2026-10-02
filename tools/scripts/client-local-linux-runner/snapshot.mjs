import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  symlinkSync,
} from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

function candidatePaths(root, git = execFileSync) {
  const output = git(
    "git",
    ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"],
    { cwd: root, encoding: "buffer", stdio: ["ignore", "pipe", "pipe"] },
  );
  return output.toString("utf8").split("\0").filter(Boolean);
}

function safeRelativePath(value) {
  if (
    value.length === 0 ||
    value.includes("\0") ||
    value.includes("\\") ||
    path.posix.isAbsolute(value) ||
    path.posix.normalize(value) !== value ||
    value === ".." ||
    value.startsWith("../")
  ) {
    throw new Error("client_local_linux_runner_candidate_path_invalid");
  }
  return value;
}

function digestFile(hash, source, relative, mode) {
  hash.update(relative);
  hash.update("\0");
  hash.update(String(mode));
  hash.update("\0");
  hash.update(readFileSync(source));
  hash.update("\0");
}

export function materializeCandidate(root, destination, options = {}) {
  const paths = candidatePaths(root, options.git);
  const hash = createHash("sha256");
  let fileCount = 0;
  mkdirSync(destination, { recursive: true, mode: 0o700 });
  for (const raw of [...new Set(paths)].sort()) {
    const relative = safeRelativePath(raw);
    const source = path.join(root, ...relative.split("/"));
    let metadata;
    try {
      metadata = lstatSync(source);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    if (!metadata.isFile() && !metadata.isSymbolicLink()) continue;
    const target = path.join(destination, ...relative.split("/"));
    mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    if (metadata.isSymbolicLink()) {
      const link = readlinkSync(source);
      symlinkSync(link, target);
      hash.update(relative);
      hash.update("\0link\0");
      hash.update(link);
      hash.update("\0");
    } else {
      copyFileSync(source, target);
      chmodSync(target, metadata.mode & 0o777);
      digestFile(hash, source, relative, metadata.mode & 0o111);
    }
    fileCount += 1;
  }
  return Object.freeze({
    fileCount,
    sourceStateDigest: `sha256:${hash.digest("hex")}`,
  });
}
