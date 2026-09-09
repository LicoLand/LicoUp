import fs from "node:fs";
import path from "node:path";
import { nodeTestFileToolchain } from "./client-regression-metadata.mjs";

function walkContractTests(root) {
  const directory = path.join(root, "tests/contract/client");
  const files = [];
  const stack = [directory];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(absolute);
        continue;
      }
      if (entry.isFile() && entry.name.endsWith(".test.mjs")) {
        files.push(path.relative(root, absolute).replaceAll("\\", "/"));
      }
    }
  }
  return files.sort();
}

export function listContractClientTests(root = ".") {
  return walkContractTests(root);
}

export function nodeOnlyContractTestFiles(root = ".") {
  return listContractClientTests(root).filter(
    (file) => nodeTestFileToolchain(file) === "node-test",
  );
}

export function sdkOwnedContractTestFiles(root = ".") {
  return listContractClientTests(root).filter(
    (file) => nodeTestFileToolchain(file) !== "node-test",
  );
}
