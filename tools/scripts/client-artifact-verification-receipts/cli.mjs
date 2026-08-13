import process from "node:process";
import { ReceiptValidationError } from "./errors.mjs";
import { isPlainObject, requireValue, text } from "./util.mjs";

export function parseArgs(argv) {
  const options = {
    targets: "",
    targetsSpecified: false,
    selfTest: false,
    schemaFixture: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--schema-fixture") {
      options.schemaFixture = true;
    } else if (arg === "--targets" && next) {
      options.targets = next;
      options.targetsSpecified = true;
      index += 1;
    } else if (arg.startsWith("--targets=")) {
      options.targets = arg.slice("--targets=".length);
      options.targetsSpecified = true;
    } else {
      throw new ReceiptValidationError("receipt_option_unknown");
    }
  }
  return options;
}

export function defaultTargetId() {
  if (process.platform === "darwin" && process.arch === "arm64") {
    return "macos-direct-arm64";
  }
  throw new ReceiptValidationError("receipt_explicit_target_selection_required");
}

export function selectedTargetIds(options, config) {
  const environmentSpecified = Object.hasOwn(
    process.env,
    "LICO_CLIENT_RELEASE_TARGETS",
  );
  const explicit = options.targetsSpecified || environmentSpecified;
  const configured = options.targetsSpecified
    ? String(options.targets)
    : environmentSpecified ? String(process.env.LICO_CLIENT_RELEASE_TARGETS) : "";
  const requested = explicit
    ? configured.split(",").map(text)
    : [defaultTargetId()];
  requireValue(requested.every(Boolean), "receipt_target_selection_empty_token");
  const requestedSet = new Set(requested);
  const ids = Object.keys(config.targets).filter((id) => requestedSet.has(id));
  requireValue(ids.length > 0, "receipt_target_selection_empty");
  requireValue(requestedSet.size === requested.length,
    "receipt_target_selection_duplicate");
  requireValue(requested.every((id) => isPlainObject(config.targets[id])) &&
    ids.length === requested.length,
    "receipt_target_selection_unsupported");
  return ids;
}
