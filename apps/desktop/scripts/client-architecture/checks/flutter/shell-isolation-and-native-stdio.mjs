import path from "node:path";

const flutterSrcRoot = "apps/desktop/lib/src";
const guiImplementationForbiddenTokens = [
  "dart:io",
  "Clipboard.",
  "MethodChannel",
  "EventChannel",
  "Process.run",
  "Process.start",
  "Platform.is",
  "path_provider",
  "secretOverrides",
  "secretOverrideTransport"
];
const backendImplementationForbiddenUiTokens = [
  "package:flutter/",
  "package:flutter/widgets.dart",
  "package:flutter/material.dart",
  "BuildContext",
  "Widget",
  "StatelessWidget",
  "StatefulWidget",
  "TextEditingController",
  "ChangeNotifier",
  "MaterialApp",
  "Theme.of("
];

function isFlutterGuiImplementationSource(relativePath) {
  return relativePath.startsWith(`${flutterSrcRoot}/frontend/`);
}

export async function checkShellIsolationAndNativeStdio(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
    sourceLineCount,
  } = context;
  const semanticDestinations = await readDartSourceByBasename("semantic_destination.dart");
  const appSections = collectEnumValues(semanticDestinations, "ClientSection");
  assert(sameSet(appSections, ["agents", "monitoring", "skillHub", "pluginManagement", "mobileRelay", "settings"]), "ClientSection enum must contain only the current client shell modules");
  for (const relativePath of (await collectDartSourceFiles())
    .filter(isFlutterGuiImplementationSource)) {
    const source = await readText(relativePath);
    for (const token of guiImplementationForbiddenTokens) {
      assert(!source.includes(token), `${relativePath} must not implement backend/platform behavior outside the platform root via ${token}`);
    }
  }
  for (const relativePath of (await collectDartSourceFiles())
    .filter((sourcePath) => sourcePath.startsWith(`${flutterSrcRoot}/backend/`))) {
    const source = await readText(relativePath);
    for (const token of backendImplementationForbiddenUiTokens) {
      assert(!source.includes(token), `${relativePath} must not depend on frontend Flutter UI via ${token}`);
    }
  }

  const nativeStdioRpcFacadePath =
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc.dart";
  const nativeStdioRpcRoot =
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc";
  const nativeStdioRpcLeafLimits = new Map([
    [`${nativeStdioRpcRoot}/client.dart`, 160],
    [`${nativeStdioRpcRoot}/command_exchange.dart`, 80],
    [`${nativeStdioRpcRoot}/command_round_trip.dart`, 85],
    [`${nativeStdioRpcRoot}/conversation_exchange.dart`, 75],
    [`${nativeStdioRpcRoot}/line_framer.dart`, 75],
    [`${nativeStdioRpcRoot}/operation_pending_queue.dart`, 40],
    [`${nativeStdioRpcRoot}/operation_queue.dart`, 90],
    [`${nativeStdioRpcRoot}/orchestrator_lane_pool.dart`, 140],
    [`${nativeStdioRpcRoot}/protocol.dart`, 75],
    [`${nativeStdioRpcRoot}/request_writer.dart`, 20],
    [`${nativeStdioRpcRoot}/response_codec.dart`, 155],
    [`${nativeStdioRpcRoot}/session.dart`, 235],
    [`${nativeStdioRpcRoot}/session_manager.dart`, 110],
    [`${nativeStdioRpcRoot}/shutdown.dart`, 50]
  ]);
  const nativeStdioRpcLeaves = await collectSourceFiles(nativeStdioRpcRoot, ".dart");
  assert(
    sameSet(nativeStdioRpcLeaves, [...nativeStdioRpcLeafLimits.keys()]),
    "native stdio RPC facade must own the complete explicit ordinary-library leaf set"
  );
  const nativeStdioRpcFacadeSource = await readText(nativeStdioRpcFacadePath);
  assert(
    sourceLineCount(nativeStdioRpcFacadeSource) <= 3 &&
      nativeStdioRpcFacadeSource.includes("show NativeStdioRpcClient") &&
      !nativeStdioRpcFacadeSource.includes("part ") &&
      !nativeStdioRpcFacadeSource.includes("class NativeStdioRpcClient"),
    "native stdio RPC root must remain a thin stable export facade"
  );
  for (const [relativePath, maxLines] of nativeStdioRpcLeafLimits) {
    const source = await readText(relativePath);
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its stdio RPC responsibility limit (${maxLines} lines maximum)`
    );
    assert(
      !source.includes("part ") &&
        !source.includes("part of") &&
        !source.includes("/agent_service_stdio_rpc.dart") &&
        !source.includes("/agent_service.dart"),
      `${relativePath} must remain an ordinary leaf without facade back-references`
    );
  }
  const nativeStdioProtocolSource = await readText(
    `${nativeStdioRpcRoot}/protocol.dart`
  );
  const nativeStdioResponseSource = await readText(
    `${nativeStdioRpcRoot}/response_codec.dart`
  );
  const nativeStdioSessionSource = await readText(
    `${nativeStdioRpcRoot}/session.dart`
  );
  const nativeStdioClientSource = await readText(
    `${nativeStdioRpcRoot}/client.dart`
  );
  for (const token of [
    "stdioRpcMaxFrameBytes",
    "stdioRpcMaxStderrBytes",
    "stdioRpcMaxErrorCodeBytes",
    "stdioRpcMaxArgs",
    "stdioRpcMaxArgumentCodeUnits",
    "validStdioRpcErrorCode",
    "validStdioRpcArgs"
  ]) {
    assert(
      nativeStdioProtocolSource.includes(token),
      `native stdio RPC protocol must retain bounded input token: ${token}`
    );
  }
  for (const token of [
    "decoded['protocol'] != stdioRpcProtocol",
    "decoded['id'] != requestId",
    "decoded['workflowId'] != workflowId",
    "decoded['sequence'] != _expectedSequence"
  ]) {
    assert(
      nativeStdioResponseSource.includes(token),
      `native stdio RPC response codec must retain identity binding: ${token}`
    );
  }
  assert(
    nativeStdioSessionSource.includes("StdioRpcLineFramer") &&
      nativeStdioSessionSource.includes("stderrBytes") &&
      nativeStdioSessionSource.includes("stderrTruncated") &&
      !nativeStdioSessionSource.includes("stderrText") &&
      !nativeStdioSessionSource.includes("utf8.decode(process.stderr"),
    "native stdio RPC session must bound stderr without projecting process content"
  );
  assert(
    nativeStdioClientSource.includes("StdioRpcOperationQueue") &&
      nativeStdioClientSource.includes("_operations.serialize") &&
      nativeStdioClientSource.includes("invalidateAndDiscard"),
    "native stdio RPC client must serialize requests and invalidate timed-out sessions"
  );
  for (const relativePath of [
    "apps/desktop/test/native_stdio_rpc_client_test.dart",
    "apps/desktop/test/native_stdio_rpc_line_framer_test.dart",
    "apps/desktop/test/native_stdio_rpc_protocol_test.dart"
  ]) {
    assert(await exists(relativePath), `${relativePath} must exist as a narrow stdio RPC regression`);
  }

  const agentServiceActionsSource = await readDartSourceByBasename("agent_service_actions.dart");
  assert(agentServiceActionsSource.includes("'agents'") && agentServiceActionsSource.includes("'pair'"), "agent_service_actions.dart must contain 'agents' and 'pair' tokens for CLI execution");
  assert(!agentServiceActionsSource.match(/\[\s*'pair'/), "GUI service layer must not use top-level 'pair' command");
  const agentConversationServiceSource = await readDartSourceByBasename("agent_conversation_service.dart");
  assert(agentConversationServiceSource.includes("'conversations'") && agentConversationServiceSource.includes("agentService.runCli"),
    "agent_conversation_service.dart must delegate conversation IO to lico-client CLI"
  );
  const nativeOrchestratorClientSource = await readText(
    "apps/desktop/lib/src/platform/native_client/orchestrator_ipc/client.dart"
  );
  const agentServiceSource = await readText(
    "apps/desktop/lib/src/platform/native_client/agent_service.dart"
  );
  assert(
    nativeOrchestratorClientSource.includes("final class NativeOrchestratorClient") &&
      nativeOrchestratorClientSource.includes("executeStructured('orchestrator.request'") &&
      nativeOrchestratorClientSource.includes("'workflow.submit'") &&
      nativeOrchestratorClientSource.includes("'workflow.status'") &&
      nativeOrchestratorClientSource.includes("'workflow.cancel'") &&
      nativeOrchestratorClientSource.includes("'workflow.approve'") &&
      nativeOrchestratorClientSource.includes("'workflow.events'") &&
      nativeOrchestratorClientSource.includes("_maximumProjectionLimit = 256") &&
      nativeOrchestratorClientSource.includes("_privacyMinimalReceipt") &&
      nativeOrchestratorClientSource.includes("_privacyMinimalEvent") &&
      !nativeOrchestratorClientSource.includes("streamCliJsonLinesWithStdin") &&
      !nativeOrchestratorClientSource.includes("Process.") &&
      agentServiceSource.includes("late final NativeOrchestratorClient orchestratorClient") &&
      agentServiceSource.includes("NativeOrchestratorClient(transport: _stdioRpcTransport)"),
    "desktop orchestration must be a bounded privacy-minimal projection over the native orchestrator request boundary"
  );
  assert(
    !agentConversationServiceSource.includes("NativeOrchestratorClient") &&
      !agentConversationServiceSource.includes("workflow.submit") &&
      !agentConversationServiceSource.includes("workflow.events"),
    "direct conversation IO must not own orchestration workflow authority"
  );
  return { agentConversationServiceSource };
}
