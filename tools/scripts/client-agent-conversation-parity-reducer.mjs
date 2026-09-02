#!/usr/bin/env node

export {
  CONTRACT_VERSION,
  EVIDENCE_SCHEMA_VERSION,
  READINESS_SCHEMA_VERSION,
  INVENTORY_SCHEMA_VERSION,
  MINIMUM_CONSECUTIVE_PASSES,
  CORE_CHECK_IDS,
  CONDITIONAL_CHECK_IDS,
} from "./client-agent-conversation-parity-reducer/constants.mjs";

export { ReducerError } from "./client-agent-conversation-parity-reducer/errors.mjs";
export { assertNoSensitiveFields } from "./client-agent-conversation-parity-reducer/privacy.mjs";
export {
  packagedAgentIds,
  registryDigestFor,
  driverInventoryDigestFor,
  capabilityMatrixDigestFor,
  adapterManifestDigestFor,
  adapterEvidenceDigestFor,
} from "./client-agent-conversation-parity-reducer/digests.mjs";
export { validateDriverInventory } from "./client-agent-conversation-parity-reducer/inventory.mjs";
export {
  reduceConversationParity,
} from "./client-agent-conversation-parity-reducer/reduce.mjs";
export { loadCanonicalInputs } from "./client-agent-conversation-parity-reducer/inputs.mjs";
export {
  assertReadinessMatchesReduction,
  assertReleaseReady,
  runCli,
} from "./client-agent-conversation-parity-reducer/cli.mjs";

import process from "node:process";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { runCli, sanitizedFailure } from "./client-agent-conversation-parity-reducer/cli.mjs";

const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (invokedDirectly) {
  try {
    process.stdout.write(`${JSON.stringify(runCli())}\n`);
  } catch (error) {
    process.stderr.write(`${JSON.stringify(sanitizedFailure(error))}\n`);
    process.exitCode = 1;
  }
}
