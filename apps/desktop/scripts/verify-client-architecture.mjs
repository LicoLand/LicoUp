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
import * as nativeChecks from "./client-architecture/checks/native.mjs";
import * as platformChecks from "./client-architecture/checks/platform.mjs";
import * as privacyChecks from "./client-architecture/checks/privacy.mjs";
import * as ratchetChecks from "./client-architecture/checks/ratchet.mjs";

const defaultChecks = Object.freeze({
  ...compositionChecks,
  ...foundationChecks,
  ...flutterChecks,
  ...nativeChecks,
  ...platformChecks,
  ...privacyChecks,
  ...ratchetChecks,
});

export const CLIENT_ARCHITECTURE_PHASE_IDS = Object.freeze([
  "foundations.packaging-and-target-projection",
  "privacy.product-contracts-and-portable-data",
  "flutter.physical-layers-and-libraries",
  "foundations.package-dry-runs",
  "native.crate-core-and-facade-bounds",
  "native.domain-and-crypto-boundaries",
  "platform.runtime-drivers-and-local-service",
  "privacy.file-security-and-client-state",
  "platform.target-serve-and-gateway",
  "native.secure-mesh-foundations-and-local-archive",
  "flutter.shell-isolation-and-native-stdio",
  "native.conversation-domain",
  "composition.conversation-bridges",
  "native.secure-mesh-authority-and-custody",
  "platform.ios-secure-mesh",
  "platform.android-secure-mesh",
  "native.command-and-file-transport",
  "flutter.mobile-relay-bridges",
  "flutter.presentation-boundary",
  "composition.client-root-and-shell",
  "native.target-readiness-reducer",
  "architecture.ratchet-metrics",
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
  (context, checks) => checks.checkCrateCoreAndFacadeBounds(context),
  (context, checks) => checks.checkDomainAndCryptoBoundaries(context),
  (context, checks, state) => checks.checkRuntimeDriversAndLocalService(context, {
    reviewedRustUnsafeFiles: state.reviewedRustUnsafeFiles,
  }),
  (context, checks) => checks.checkFileSecurityAndClientState(context),
  (context, checks, state) => checks.checkTargetServeAndGateway(context, {
    localServiceSource: state.localServiceSource,
  }),
  (context, checks) => checks.checkSecureMeshFoundationsAndLocalArchive(context),
  (context, checks) => checks.checkShellIsolationAndNativeStdio(context),
  (context, checks, state) => checks.checkConversationDomain(context, {
    agentConversationServiceSource: state.agentConversationServiceSource,
  }),
  (context, checks, state) => checks.checkConversationBridges(context, {
    conversationSourceCatalogRustSource: state.conversationSourceCatalogRustSource,
    packagedTargets: state.packagedTargets,
  }),
  (context, checks) => checks.checkSecureMeshAuthorityAndCustody(context),
  (context, checks) => checks.checkIosSecureMesh(context),
  (context, checks) => checks.checkAndroidSecureMesh(context),
  (context, checks, state) => checks.checkCommandAndFileTransport(context, {
    secureMeshMobileFfiRoot: state.secureMeshMobileFfiRoot,
  }),
  (context, checks, state) => checks.checkMobileRelayBridges(context, {
    secureMeshMobileFfiSource: state.secureMeshMobileFfiSource,
  }),
  (context, checks) => checks.checkPresentationBoundary(context),
  (context, checks, state) => checks.checkClientRootAndShell(context, {
    agentConversationServiceSource: state.agentConversationServiceSource,
    mobileRelayClientAdapterSource: state.mobileRelayClientAdapterSource,
    mobileRelayPanelFacadeSource: state.mobileRelayPanelFacadeSource,
    mobileRelayPanelSources: state.mobileRelayPanelSources,
    mobileRelayServiceSource: state.mobileRelayServiceSource,
    secureMeshControllerSource: state.secureMeshControllerSource,
  }),
  (context, checks) => checks.checkTargetReadinessReducer(context),
  (context, checks) => checks.checkArchitectureRatchet(context),
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
    metrics: state.ratchetMetrics,
    ratchet: state.ratchetReport,
  });
  emitArchitectureResult(result, output);
  return result;
}

export async function recordArchitectureRatchetBaseline({
  repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url))),
  output,
} = {}) {
  const outcome = await ratchetChecks.recordArchitectureRatchet({ repoRoot });
  const result = {
    ok: outcome.ok,
    text: JSON.stringify(
      outcome.ok
        ? { ok: true, baseline: outcome.path, metrics: outcome.record }
        : { ok: false, failures: [outcome.message, ...(outcome.regressions ?? [])] },
      null,
      2,
    ),
  };
  emitArchitectureResult(result, output);
  return result;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--record-ratchet-baseline")) {
    await recordArchitectureRatchetBaseline();
  } else {
    await runClientArchitectureVerification();
  }
}
