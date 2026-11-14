#!/usr/bin/env node
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  createArchitectureContext,
  emitArchitectureResult,
  formatArchitectureResult,
} from "./client-architecture/context.mjs";
import * as compositionChecks from "./client-architecture/checks/composition.mjs";
import * as foundationChecks from "./client-architecture/checks/foundations.mjs";
import * as flutterChecks from "./client-architecture/checks/flutter.mjs";
import * as privacyChecks from "./client-architecture/checks/privacy.mjs";

const defaultChecks = Object.freeze({
  ...compositionChecks,
  ...foundationChecks,
  ...flutterChecks,
  ...privacyChecks,
});

export const CLIENT_ARCHITECTURE_PHASE_IDS = Object.freeze([
  "foundations.packaging-and-target-projection",
  "privacy.product-contracts-and-portable-data",
  "flutter.physical-layers-and-libraries",
  "foundations.package-dry-runs",
  "flutter.shell-isolation-and-native-stdio",
  "composition.conversation-bridges",
  "flutter.presentation-boundary",
  "composition.client-root-and-shell",
]);

const phasePlan = Object.freeze([
  (context, checks) => checks.checkPackagingAndTargetProjection(context),
  (context, checks, state) => checks.checkProductContractsAndPortableData(context, {
    modules: state.modules,
  }),
  (context, checks) => checks.checkFlutterPhysicalLayersAndLibraries(context),
  (context, checks, state) => checks.checkPackageDryRuns(context, {
    futureModules: state.futureModules,
    modules: state.modules,
  }),
  (context, checks) => checks.checkShellIsolationAndNativeStdio(context),
  (context, checks) => checks.checkConversationBridges(context),
  (context, checks) => checks.checkPresentationBoundary(context),
  (context, checks, state) => checks.checkClientRootAndShell(context, {
    agentConversationServiceSource: state.agentConversationServiceSource,
  }),
]);

export async function runClientArchitecturePhases(context, checks = defaultChecks) {
  const state = {};
  for (const runPhase of phasePlan) {
    const update = await runPhase(context, checks, state);
    if (update) {
      Object.assign(state, update);
    }
  }
  return state;
}

export async function runClientArchitectureVerification({
  repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url))),
  checks = defaultChecks,
  output,
} = {}) {
  const context = createArchitectureContext({ repoRoot });
  const state = await runClientArchitecturePhases(context, checks);
  const result = formatArchitectureResult({
    failures: context.failures,
    futureModules: state.futureModules,
    packagedTargets: state.packagedTargets,
    packagePlanCheckedPlatforms: state.packagePlanCheckedPlatforms,
  });
  emitArchitectureResult(result, output);
  return result;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  await runClientArchitectureVerification();
}
