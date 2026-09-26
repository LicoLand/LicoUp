import { readFileSync, existsSync, mkdirSync, writeFileSync, renameSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));

export function compareObservation(previous, observation) {
  const changed = Boolean(previous?.validator && observation.validator && previous.validator !== observation.validator);
  const pendingReview = Boolean(previous?.pendingReview || changed);
  return { ...observation, pendingReview, status: observation.available
    ? pendingReview ? "changed-review-required" : !observation.validator ? "no-change-validator" : previous?.validator ? "unchanged-observation" : "first-observation"
    : "unavailable", severity: "warning", protocolCompatibility: "unverified" };
}

export async function observeReference(url, previous, fetcher = fetch) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) throw new Error("invalid public source");
    // Only public manifest URLs; no account cookies, Agent process or local runtime.
    // A bounded HTTP observation failing leaves a warning, never a failed Agent.
    const response = await fetcher(url, { method: "HEAD", credentials: "omit", signal: AbortSignal.timeout(12000) });
    const etag = response.headers.get("etag");
    const modified = response.headers.get("last-modified");
    const observation = { url, available: response.ok, httpStatus: response.status,
      validator: response.ok ? etag ? `etag:${etag}` : modified ? `modified:${modified}` : null : previous?.validator ?? null };
    return compareObservation(previous, observation);
  } catch {
    return compareObservation(previous, { url, available: false, httpStatus: null, validator: previous?.validator ?? null });
  }
}

export function officialSources(drivers, readManifest) {
  return drivers.map(({ agentId }) => {
    let references = [];
    try { references = readManifest(agentId).officialCapabilityAssessment?.officialReferences ?? []; } catch { /* Missing source stays visible. */ }
    return { agentId, references: [...new Set(references)].filter((url) => typeof url === "string") };
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length > 2) throw new Error("No options supported");
  const read = (file) => JSON.parse(readFileSync(path.join(root, file), "utf8"));
  const sources = officialSources(read("crates/licoup-native/resources/agent-conversation-drivers.json").drivers,
    (id) => read(`packages/contracts/client/fixtures/agent-conversation-adapter/manifests/${id}.json`));
  const output = "build/reports/upstream-observations.json";
  const prior = existsSync(path.join(root, output)) ? read(output).references ?? [] : [];
  const previous = new Map(prior.map((entry) => [entry.url, entry]));
  const references = [];
  // Fetch each unique reference once, sequentially. Never run a real Agent here.
  for (const url of new Set(sources.flatMap((entry) => entry.references))) {
    references.push(await observeReference(url, previous.get(url)));
  }
  const byUrl = new Map(references.map((entry) => [entry.url, entry]));
  const agents = sources.map(({ agentId, references: urls }) => ({ agentId,
    status: urls.length ? [...new Set(urls.map((url) => byUrl.get(url).status))].join(",") : "official-reference-missing",
    severity: "warning", blocking: false, liveValidation: "not-run" }));
  const report = { observedAt: new Date().toISOString(), method: "public-http-metadata", agents, references,
    limitation: "Page metadata is not a protocol diff. First, changed or unavailable observations require review; upstream repairs belong in a separate scoped PR. No live validation is inferred." };
  mkdirSync(path.join(root, "build/reports"), { recursive: true });
  writeFileSync(path.join(root, `${output}.tmp`), JSON.stringify(report, null, 2) + "\n");
  renameSync(path.join(root, `${output}.tmp`), path.join(root, output));
  for (const agent of agents) process.stdout.write(`warning ${agent.agentId}: ${agent.status}; live validation not-run\n`);
}
