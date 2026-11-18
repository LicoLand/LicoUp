import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const NODE_TEST_INPUTS_ENV = "LICO_CLIENT_NODE_TEST_INPUTS";
export const NODE_TEST_ATTRIBUTION_SCHEMA = "licoup.node-test-attribution.v1";
const PRIVATE_FAILURE_LIMIT = 64 * 1024;

function normalizedFile(value) {
  try {
    const raw = String(value || "");
    const resolved = raw.startsWith("file:")
      ? fileURLToPath(raw)
      : path.resolve(process.cwd(), raw);
    const normalized = path.normalize(resolved);
    return process.platform === "win32" ? normalized.toLowerCase() : normalized;
  } catch {
    return "";
  }
}

function configuredInputs() {
  try {
    const parsed = JSON.parse(process.env[NODE_TEST_INPUTS_ENV] || "null");
    if (!Array.isArray(parsed) || !parsed.every((value) => typeof value === "string")) {
      return null;
    }
    return parsed.map(normalizedFile);
  } catch {
    return null;
  }
}

function safeFailureCategory(error) {
  const candidate = error?.code || error?.failureType || error?.name || "test_failure";
  const normalized = String(candidate)
    .toLowerCase()
    .replace(/[^a-z0-9_.:+-]+/gu, "_")
    .replace(/^_+|_+$/gu, "")
    .slice(0, 80);
  return normalized || "test_failure";
}

function privateFailureDiagnostic(error) {
  const sections = [];
  const visited = new Set();
  let current = error;
  for (let depth = 0; current && depth < 4 && !visited.has(current); depth += 1) {
    visited.add(current);
    const stack = typeof current.stack === "string" ? current.stack : "";
    const message = typeof current.message === "string" ? current.message : "";
    if (stack) sections.push(stack);
    else if (message) sections.push(message);
    else sections.push(String(current));
    current = current.cause;
    if (current) sections.push("Caused by:");
  }
  return sections.join("\n").slice(-PRIVATE_FAILURE_LIMIT);
}

export default async function* nodeTestAttributionReporter(source) {
  const inputs = configuredInputs();
  const indexByFile = inputs
    ? new Map(inputs.map((file, index) => [file, index]))
    : new Map();
  const failedInputIndexes = new Set();
  let complete = inputs !== null && inputs.every(Boolean);

  for await (const event of source) {
    if (event?.type !== "test:fail") continue;
    const file = normalizedFile(event?.data?.file);
    const index = indexByFile.get(file);
    if (index === undefined) complete = false;
    else {
      failedInputIndexes.add(index);
      const error = event?.data?.details?.error;
      yield `[node-test-private-diagnostic input=${index} category=${safeFailureCategory(error)}]\n`;
      yield `${privateFailureDiagnostic(error)}\n`;
    }
  }

  yield `${JSON.stringify({
    schemaVersion: NODE_TEST_ATTRIBUTION_SCHEMA,
    complete,
    inputCount: inputs?.length || 0,
    failedInputIndexes: [...failedInputIndexes].sort((left, right) => left - right),
  })}\n`;
}
