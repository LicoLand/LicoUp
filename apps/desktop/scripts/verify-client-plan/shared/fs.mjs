import fs from "node:fs/promises";
import path from "node:path";

function createResolver(repoRoot) {
  const resolvedRoot = path.resolve(repoRoot);
  const rootPrefix = `${resolvedRoot}${path.sep}`;
  return (relativePath) => {
    const value = String(relativePath || "");
    if (!value || path.isAbsolute(value) || value.includes("\0")) {
      throw new Error("plan file reference must be a non-empty relative path");
    }
    const resolved = path.resolve(resolvedRoot, value);
    if (resolved !== resolvedRoot && !resolved.startsWith(rootPrefix)) {
      throw new Error("plan file reference escapes the repository root");
    }
    return resolved;
  };
}

export function createPlanFileReader(repoRoot) {
  const resolvePath = createResolver(repoRoot);

  async function readText(relativePath) {
    return fs.readFile(resolvePath(relativePath), "utf8");
  }

  async function readJson(relativePath) {
    return JSON.parse(await readText(relativePath));
  }

  async function sourceFilesUnder(relativeDirectory, extension) {
    const discovered = [];
    async function visit(directory) {
      const entries = await fs.readdir(resolvePath(directory), {
        withFileTypes: true,
      });
      for (const entry of entries) {
        const relativePath = path.posix.join(directory, entry.name);
        if (entry.isDirectory()) {
          await visit(relativePath);
        } else if (entry.isFile() && entry.name.endsWith(extension)) {
          discovered.push(relativePath);
        }
      }
    }
    await visit(relativeDirectory);
    return discovered.sort();
  }

  async function readSourceBundle(rootFile, sourceDirectory, extension) {
    const sourceFiles = (await sourceFilesUnder(sourceDirectory, extension))
      .filter((relativePath) => relativePath !== rootFile);
    return (await Promise.all([rootFile, ...sourceFiles].map(readText))).join("\n");
  }

  return Object.freeze({
    readText,
    readJson,
    sourceFilesUnder,
    readSourceBundle,
  });
}
