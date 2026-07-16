import path from "node:path";
import { repoRoot } from "./constants.mjs";
import { requireValue, text } from "./util.mjs";

export function buildRelativeRef(ref) {
  const normalized = text(ref).replaceAll("\\", "/");
  requireValue(normalized.startsWith("build/") && !normalized.includes("../"),
    "client release report reference is invalid");
  return normalized.slice("build/".length);
}

export function reportSelectedForTargets(spec, selectedTargetIdSet) {
  if (!Array.isArray(spec.targetIds)) return true;
  return spec.targetIds.length > 0 &&
    spec.targetIds.some((targetId) => selectedTargetIdSet.has(targetId));
}

export function closureRedactionSeedRefs(
  config,
  selectedTargets,
  artifactContext,
  targetConfig,
) {
  return [
    config.artifactReceipt.ref,
    ...selectedTargets.map((target) => targetConfig.targets?.[target.id]?.evidenceRef),
    ...(artifactContext?.ok === true
      ? (artifactContext.payload?.receipts || []).flatMap((receipt) =>
          (receipt?.dependencies || []).map((dependency) => dependency?.ref))
      : []),
  ].map(text).filter(Boolean);
}
