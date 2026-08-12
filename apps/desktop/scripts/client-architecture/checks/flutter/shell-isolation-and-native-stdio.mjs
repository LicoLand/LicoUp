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
  } = context;
  const semanticDestinations = await readDartSourceByBasename("semantic_destination.dart");
  const appSections = collectEnumValues(semanticDestinations, "ClientSection");
  assert(sameSet(appSections, ["agents", "monitoring", "skillHub", "pluginManagement", "mobileRelay", "models", "settings"]), "ClientSection enum must contain only the current client shell modules");
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
  const nativeStdioRpcLeafPaths = new Set([
  `${nativeStdioRpcRoot}/client.dart`,
  `${nativeStdioRpcRoot}/command_exchange.dart`,
  `${nativeStdioRpcRoot}/command_round_trip.dart`,
  `${nativeStdioRpcRoot}/conversation_exchange.dart`,
  `${nativeStdioRpcRoot}/in_flight_control.dart`,
  `${nativeStdioRpcRoot}/line_framer.dart`,
  `${nativeStdioRpcRoot}/method_policy.dart`,
  `${nativeStdioRpcRoot}/operation_pending_queue.dart`,
  `${nativeStdioRpcRoot}/operation_queue.dart`,
  `${nativeStdioRpcRoot}/protocol.dart`,
  `${nativeStdioRpcRoot}/request_writer.dart`,
  `${nativeStdioRpcRoot}/response_codec.dart`,
  `${nativeStdioRpcRoot}/session.dart`,
  `${nativeStdioRpcRoot}/session_expectation.dart`,
  `${nativeStdioRpcRoot}/session_manager.dart`,
  `${nativeStdioRpcRoot}/shutdown.dart`,
]);
  const nativeStdioRpcLeaves = await collectSourceFiles(nativeStdioRpcRoot, ".dart");
  assert(
    sameSet(nativeStdioRpcLeaves, [...nativeStdioRpcLeafPaths]),
    "native stdio RPC facade must own the complete explicit ordinary-library leaf set"
  );
  const nativeStdioRpcFacadeSource = await readText(nativeStdioRpcFacadePath);
  assert(
    nativeStdioRpcFacadeSource.includes("show NativeStdioRpcClient") &&
      !nativeStdioRpcFacadeSource.includes("part ") &&
      !nativeStdioRpcFacadeSource.includes("class NativeStdioRpcClient"),
    "native stdio RPC root must remain a thin stable export facade"
  );
  for (const relativePath of nativeStdioRpcLeafPaths) {
    const source = await readText(relativePath);
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
    "agent_conversation_service.dart must delegate conversation IO to licoup CLI"
  );
  const agentServiceSource = await readText(
    "apps/desktop/lib/src/platform/native_client/agent_service.dart"
  );
  assert(
    agentServiceSource.includes("NativeStdioRpcTransport"),
    "desktop native service must retain the direct stdio transport boundary"
  );
  return { agentConversationServiceSource };
}
