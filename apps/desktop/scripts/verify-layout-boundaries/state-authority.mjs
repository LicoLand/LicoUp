import { createHash } from "node:crypto";
import { importsFrom } from "./dart-source.mjs";
import { fail } from "./errors.mjs";
import { compareCanonical } from "./paths.mjs";

export function validateCurrentStateAuthority({ preferences, dataRoot, manifest, config }) {
  const preferencesUsesCurrentRoot =
    preferences.includes(
      "static const _fileName = 'appearance-preferences.json';",
    ) &&
    preferences.includes("final root = await _portableData.clientDirectory();") &&
    preferences.includes("return File(p.join(root.path, _fileName));") &&
    importsFrom(preferences).filter((specifier) =>
      specifier.includes("/platform/storage/"),
    ).length === 1;
  const dataRootOwnsOneCurrentWorkspace =
    dataRoot.includes("Future<Directory> clientDirectory() async") &&
    dataRoot.includes(
      "final directory = Directory(p.join(dataDir.path, 'lico-client'));",
    ) &&
    dataRoot.includes(
      "static const String _workspaceManifestFileName = '.licoarc-workspace.json';",
    ) &&
    manifest.includes("static const licoArcAppId = 'lico-client';");
  if (!preferencesUsesCurrentRoot || !dataRootOwnsOneCurrentWorkspace) {
    fail("layout_current_state_authority_invalid", config.preferencesPath);
  }
  const stateSources = `${preferences}\n${dataRoot}\n${manifest}`;
  if (
    /\b(?:discover|import|translate|prompt|migrate)[A-Za-z0-9_]*(?:Root|Preference|Namespace)\b/iu.test(
      stateSources,
    )
  ) {
    fail("layout_named_state_compatibility_behavior_present", config.preferencesPath);
  }
}

export function digestManifest(files) {
  const hash = createHash("sha256");
  for (const [relativePath, source] of [...files].sort(([left], [right]) =>
    compareCanonical(left, right),
  )) {
    hash.update(relativePath);
    hash.update("\0");
    hash.update(source);
    hash.update("\0");
  }
  return hash.digest("hex");
}
