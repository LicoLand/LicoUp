import path from "node:path";
import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256File,
  stableHashFileSnapshot,
} from "../../lib/client-release-artifact-digest.mjs";
import { repoRoot, maxJsonBytes, SHA256 } from "../constants.mjs";
import { sanitizeArtifactBinding } from "../sanitize-binding.mjs";
import { artifactFileByteLimit, requireValue, text } from "../util.mjs";
import { verifyAndroidArtifact } from "./android.mjs";
import { verifyMacosArtifact } from "./macos.mjs";

export function verifySelectedArtifacts(config, selectedTargets, clientVersion, receiptContext) {
  return Object.fromEntries(selectedTargets.map((target) => {
    const spec = config.artifacts?.[target.id];
    if (!spec) return [target.id, sanitizeArtifactBinding({ targetId: target.id })];
    if (spec.artifactKind === "macos-distribution-archive") {
      return [target.id, verifyMacosArtifact(target, spec, clientVersion, receiptContext)];
    }
    if (spec.artifactKind === "android-apk") {
      return [target.id, verifyAndroidArtifact(target, spec, clientVersion, receiptContext)];
    }
    return [target.id, sanitizeArtifactBinding({ targetId: target.id })];
  }));
}

export function artifactBindingMapsEqual(left, right, selectedTargets) {
  return selectedTargets.every((target) =>
    JSON.stringify(sanitizeArtifactBinding(left?.[target.id])) ===
      JSON.stringify(sanitizeArtifactBinding(right?.[target.id])));
}

export function captureSelectedArtifactInputState(config, selectedTargets) {
  const buildRoot = path.join(repoRoot, "build");
  return Object.fromEntries(selectedTargets.map((target) => {
    const spec = config.artifacts[target.id];
    const artifactPath = resolveContainedExistingPath(
      buildRoot,
      path.join(repoRoot, spec.ref),
      { expectedKind: "file" },
    );
    const state = {
      artifactDigest: sha256File(artifactPath, {
        maxBytes: artifactFileByteLimit(spec),
      }),
    };
    if (spec.artifactKind === "macos-distribution-archive") {
      state.entitlementsDigest = sha256File(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.entitlementsRef),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
      state.installArtifactDigest = artifactTreeDigest(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.installArtifactRef),
        { expectedKind: "directory" },
      ));
      state.distributionManifestDigest = sha256File(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.distributionManifestRef),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
    } else if (spec.artifactKind === "android-apk") {
      state.buildManifestDigest = sha256File(resolveContainedExistingPath(
        path.dirname(artifactPath),
        path.join(path.dirname(artifactPath), "build-manifest.json"),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
    } else {
      requireValue(false, `unsupported release artifact kind: ${spec.artifactKind}`);
    }
    return [target.id, state];
  }));
}

export function artifactInputStatesEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}
