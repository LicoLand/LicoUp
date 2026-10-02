import {createHash} from "node:crypto";
import path from "node:path";
import {lexicalView} from "./lexical.mjs";

export const sourceDigest = (source) => createHash("sha256").update(source).digest("hex");

const kinds = new Set(["parameter", "field", "environment", "command", "configuration", "discovery", "materialized-script"]);
const safePath = (value) => typeof value === "string" && /^(?:crates|components|sdk|apps\/desktop\/lib)\/[A-Za-z0-9_./-]+\.(?:rs|dart|sh|ps1)$/u.test(value)
  && value.split("/").every((part) => part && part !== "." && part !== "..");

function contractIdentity(review) {
  return sourceDigest(JSON.stringify({id: review.id, purpose: review.purpose, selection: review.selection,
    provenance: review.provenance.map(({file, role}) => ({file, role}))})).slice(0, 20);
}

// This discharges only a bounded interpreter's inability to enumerate a
// specifically reviewed non-literal source selector. It never clears syntax,
// import/API identity, cycles, unsupported literals, or repository I/O failures.
function reviewedSelectorCovers(reason, review, sources, functionSource) {
  const selector = review.selection;
  if (!["configuration", "discovery"].includes(selector.kind)) return false;
  const text = sources.get(selector.file)?.source;
  if (!text || !selector.symbol) return false;
  const limitation = reason.replace(/^guest target: /u, "");
  const expression = limitation.match(/^unsupported or dynamic target expression:\s*([\s\S]*)$/u)?.[1];
  const returned = limitation.match(/^function (\w+) has an unsupported fall-through target$/u)?.[1];
  const invoked = expression?.match(/^((?:\w+\s*::\s*)*\w+)\s*\(/u)?.[1];
  const definition = functionSource?.(review.id.split("::")[0], returned ?? invoked ?? "");
  if (definition?.file !== selector.file || definition?.symbol !== selector.symbol) return false;
  const masked = lexicalView(text, selector.file.endsWith(".dart") ? "dart" : "rust").masked;
  const declaration = new RegExp(`\\bfn\\s+${selector.symbol}\\s*\\(`, "u").exec(masked);
  if (!declaration) return false;
  const open = masked.indexOf("{", declaration.index);
  let depth = 0, end = open;
  for (; end >= 0 && end < masked.length; end += 1) {
    if (masked[end] === "{") depth += 1;
    if (masked[end] === "}" && --depth === 0) break;
  }
  if (open < 0 || end >= masked.length) return false;
  const body = masked.slice(open + 1, end);
  // The source summary must identify a real unbounded input operation, not a
  // convenient unsupported finite literal/macro. The reviewer still owns the
  // semantic linkage; exact source digests make that assertion auditable/stale.
  return selector.kind === "configuration"
    ? /\b(?:get|as_str|as_string)\s*\(/u.test(body)
    : /\b(?:var_os|var|current_exe|is_file|exists|search_path_dirs|read_dir|metadata)\s*\(/u.test(body);
}

export async function reviewRuntimeInterfaces({repoRoot, observations, reviews, sources, sourceArtifacts, readFile, functionSource}) {
  const problems = [];
  if (!Array.isArray(reviews) || reviews.length > 256) return {reviewed: [], unreviewed: [], failures: observations, problems: ["Runtime interface review inventory must be a bounded explicit list"]};
  const valid = new Map();
  const contents = new Map([...sources].map(([file, entry]) => [file, entry.raw ?? entry.source]));
  for (const review of reviews) {
    const label = typeof review?.id === "string" ? review.id : "<missing interface id>";
    if (!review || typeof review !== "object" || Array.isArray(review) ||
        Object.keys(review).some((key) => !["id", "purpose", "selection", "provenance"].includes(key)) ||
        !/^[A-Za-z0-9_./-]+::[a-f0-9]{12}(?:#\d+)?$/u.test(label) ||
        typeof review.purpose !== "string" || review.purpose.trim().length < 40 || review.purpose.length > 1000 ||
        !review.selection || !kinds.has(review.selection.kind) || !safePath(review.selection.file) ||
        Object.keys(review.selection).some((key) => !["kind", "file", "symbol", "evidence"].includes(key)) ||
        typeof review.selection.evidence !== "string" || review.selection.evidence.trim().length < 12 || review.selection.evidence.length > 2000 ||
        (review.selection.symbol !== undefined && !/^[A-Za-z_]\w*$/u.test(review.selection.symbol)) ||
        !Array.isArray(review.provenance) || !review.provenance.length || review.provenance.length > 12 || valid.has(label)) {
      problems.push(`runtime interface ${label} has an invalid or duplicate review contract`);
      continue;
    }
    let verified = true;
    const seen = new Set();
    for (const proof of review.provenance) {
      if (!proof || Object.keys(proof).some((key) => !["file", "digest", "role"].includes(key)) ||
          !safePath(proof.file) || seen.has(proof.file) || !/^[a-f0-9]{64}$/u.test(proof.digest ?? "") ||
          typeof proof.role !== "string" || proof.role.trim().length < 12 || proof.role.length > 240) {
        problems.push(`runtime interface ${label} has invalid source provenance`); verified = false; continue;
      }
      seen.add(proof.file);
      if (!contents.has(proof.file) && sourceArtifacts.has(proof.file)) {
        try { contents.set(proof.file, await readFile(path.join(repoRoot, proof.file), "utf8")); }
        catch (error) { problems.push(`${proof.file} cannot be read for runtime-interface review (${error?.code ?? "unknown"})`); }
      }
      if (!contents.has(proof.file) || sourceDigest(contents.get(proof.file)) !== proof.digest) {
        problems.push(`runtime interface ${label} source changed or is unavailable: ${proof.file}`); verified = false;
      }
    }
    const siteFile = label.split("::")[0];
    const selectionSource = sources.get(review.selection.file)?.source;
    const evidenceOffset = selectionSource?.indexOf(review.selection.evidence) ?? -1;
    const evidenceHidden = evidenceOffset >= 0 && lexicalView(selectionSource, review.selection.file.endsWith(".dart") ? "dart" : "rust").regions
      .some((region) => region.start <= evidenceOffset && evidenceOffset < region.end);
    if (!seen.has(siteFile) || !seen.has(review.selection.file) || typeof selectionSource !== "string" ||
        evidenceOffset < 0 || evidenceHidden) {
      problems.push(`runtime interface ${label} lacks its exact site/selector evidence`); verified = false;
    }
    if (verified) valid.set(label, review);
  }
  const reviewed = [], unreviewed = [], failures = [], used = new Set();
  for (const site of observations) {
    const review = valid.get(site.id);
    const fatal = (site.failures ?? site.reasons).filter((reason) => !review || !reviewedSelectorCovers(reason, review, sources, functionSource));
    if (!site.api.split(", ").every((api) => /^(?:std::process::Command|tokio::process::Command|dart:io\.Process|source-returned Command|source-owned:run_bounded_(?:untrusted_agent_output|command_output))$/u.test(api))) {
      fatal.push("process API identity is not established");
    }
    if (fatal.length) {
      failures.push({...site, category: "analysis-failure", failures: [...new Set(fatal)]});
      continue;
    }
    if (!site.runtimeOrigins.length && !site.failures.length) continue;
    if (!review) { unreviewed.push({...site, category: "unreviewed-runtime-interface"}); continue; }
    if (site.runtimeOrigins.some((origin) => origin.kind === "materialized-script") &&
        (review.selection.kind !== "materialized-script" || !review.provenance.some((proof) => proof.file !== site.file && proof.role === "materialized-script-template" && /\.(?:rs|sh|ps1)$/u.test(proof.file)))) {
      problems.push(`runtime interface ${site.id} lacks its materialized script source`);
      unreviewed.push({...site, category: "unreviewed-runtime-interface"});
      continue;
    }
    used.add(site.id);
    reviewed.push({...site, boundedInterpretationLimits: site.failures, failures: [], category: "reviewed-runtime-interface", purpose: review.purpose, selection: review.selection,
      provenance: review.provenance, contract: contractIdentity(review)});
  }
  for (const id of valid.keys()) if (!used.has(id)) problems.push(`runtime interface review ${id} is stale or cannot resolve an analysis failure`);
  for (const site of unreviewed) problems.push(`${site.file}:${site.line} [${site.sink}] has an unresolved process target: unreviewed runtime-selected interface (${site.reasons.join("; ")})`);
  for (const site of failures) problems.push(`${site.file}:${site.line} [${site.sink}] has an unresolved process target: analysis failure (${site.failures.join("; ")})`);
  return {reviewed, unreviewed, failures, problems};
}
