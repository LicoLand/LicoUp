import fs from "node:fs/promises";
import path from "node:path";

const flutterLibRoot = "apps/desktop/lib";

export function createArchitectureFilesystem({ repoRoot, fail }) {
  let dartSourceFilesCache = null;

  async function exists(relativePath) {
    try {
      await fs.access(path.join(repoRoot, relativePath));
      return true;
    } catch {
      return false;
    }
  }

  async function readText(relativePath) {
    return fs.readFile(path.join(repoRoot, relativePath), "utf8");
  }

  async function readJoinedText(relativePaths) {
    return (await Promise.all(relativePaths.map((relativePath) => readText(relativePath)))).join("\n");
  }

  async function readJson(relativePath) {
    return JSON.parse(await readText(relativePath));
  }

  async function readImmediateDirectoryNames(relativeRoot) {
    try {
      const items = await fs.readdir(path.join(repoRoot, relativeRoot), { withFileTypes: true });
      return items.filter((item) => item.isDirectory()).map((item) => item.name).sort();
    } catch (error) {
      fail(`${relativeRoot} must be readable`);
      return [];
    }
  }

  async function collectSourceFiles(relativeRoot, extension) {
    const absoluteRoot = path.join(repoRoot, relativeRoot);
    const files = [];

    async function walk(relativeDir = "") {
      const items = await fs.readdir(path.join(absoluteRoot, relativeDir), { withFileTypes: true });
      for (const item of items) {
        const child = relativeDir ? `${relativeDir}/${item.name}` : item.name;
        if (item.isDirectory()) {
          await walk(child);
        } else if (item.isFile() && child.endsWith(extension)) {
          files.push(`${relativeRoot}/${child}`);
        }
      }
    }

    await walk();
    return files.sort();
  }

  async function collectDartSourceFiles() {
    if (!dartSourceFilesCache) {
      dartSourceFilesCache = await collectSourceFiles(flutterLibRoot, ".dart");
    }
    return dartSourceFilesCache;
  }

  async function resolveDartSourceByBasename(basename) {
    const matches = (await collectDartSourceFiles())
      .filter((relativePath) => path.basename(relativePath) === basename);
    if (matches.length !== 1) {
      fail(`Flutter source file ${basename} must resolve to exactly one file under ${flutterLibRoot}; found ${matches.length}: ${matches.join(", ")}`);
      return null;
    }
    return matches[0];
  }

  async function readDartSourceByBasename(basename) {
    const relativePath = await resolveDartSourceByBasename(basename);
    if (!relativePath) {
      return "";
    }
    return readText(relativePath);
  }

  async function readJoinedDartSourcesByBasename(basenames) {
    return (await Promise.all(basenames.map((basename) => readDartSourceByBasename(basename)))).join("\n");
  }

  async function collectRustUnsafeFiles(relativeRoot) {
    const absoluteRoot = path.join(repoRoot, relativeRoot);
    const unsafeFiles = [];

    async function walk(relativeDir = "") {
      const items = await fs.readdir(path.join(absoluteRoot, relativeDir), { withFileTypes: true });
      for (const item of items) {
        if (item.name === "target") {
          continue;
        }
        const child = relativeDir ? `${relativeDir}/${item.name}` : item.name;
        if (item.isDirectory()) {
          await walk(child);
        } else if (item.isFile() && child.endsWith(".rs")) {
          const content = await fs.readFile(path.join(absoluteRoot, child), "utf8");
          const scannedContent = child === "android_ffi.rs"
            ? content.replace(/#\s*\[\s*unsafe\s*\(\s*no_mangle\s*\)\s*\]/g, "")
            : content;
          if (/(^|[^A-Za-z0-9_])unsafe([^A-Za-z0-9_]|$)/.test(scannedContent)) {
            unsafeFiles.push(`${relativeRoot}/${child}`);
          }
        }
      }
    }

    await walk();
    return unsafeFiles.sort();
  }

  return {
    collectDartSourceFiles,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
  };
}
