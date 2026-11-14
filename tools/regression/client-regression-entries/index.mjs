import macos from "./platforms/macos.mjs";
import windows from "./platforms/windows.mjs";
import linux from "./platforms/linux.mjs";

export const PLATFORM_REGRESSION_ENTRIES = Object.freeze([
  macos, windows, linux,
]);

export const CLIENT_COMPATIBILITY_ENTRIES = PLATFORM_REGRESSION_ENTRIES;

export function validateClientRegressionEntries() {
  const expectedPlatforms = ["macos", "windows", "linux"];
  const actualPlatforms = PLATFORM_REGRESSION_ENTRIES.map((entry) => entry.id);
  if (JSON.stringify(actualPlatforms) !== JSON.stringify(expectedPlatforms)) {
    throw new Error("platform regression entry inventory drift");
  }
  const ids = CLIENT_COMPATIBILITY_ENTRIES.map((entry) => `${entry.kind}:${entry.id}`);
  if (new Set(ids).size !== ids.length) throw new Error("duplicate compatibility regression entry");
  for (const entry of CLIENT_COMPATIBILITY_ENTRIES) {
    if (entry.stage !== "compatibility" || typeof entry.probe !== "function") {
      throw new Error("compatibility regression entry is invalid");
    }
    if (!Array.isArray(entry.inputs) || !Object.isFrozen(entry.inputs) ||
        !Array.isArray(entry.unverifiedInputs) || !Object.isFrozen(entry.unverifiedInputs)) {
      throw new Error(`compatibility input classification is invalid: ${entry.kind}:${entry.id}`);
    }
    const classified = [...entry.inputs, ...entry.unverifiedInputs];
    if (new Set(classified).size !== classified.length) {
      throw new Error(`duplicate compatibility input classification: ${entry.kind}:${entry.id}`);
    }
  }
  return true;
}
