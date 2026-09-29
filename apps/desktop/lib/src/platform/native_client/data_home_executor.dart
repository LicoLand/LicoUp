import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

typedef DataHomePhaseHandler = void Function(String phase);

/// Runs root-status requests through the ordinary admitted process and root
/// changes through their dedicated one-shot native process.
final class DataHomeExecutor {
  const DataHomeExecutor(this._processContext);

  final NativeCliProcessContext _processContext;

  Future<Map<String, dynamic>> relocate(
    String destinationParent, {
    DataHomePhaseHandler? onPhase,
  }) => _execute(
    ConversationProtocolMethod.dataHomeRelocate,
    <String, dynamic>{
      'destinationParent': destinationParent,
      'confirmed': true,
    },
    dedicated: true,
    onPhase: onPhase,
  );

  Future<Map<String, dynamic>> status() => _execute(
    ConversationProtocolMethod.dataHomeStatus,
    const <String, dynamic>{},
  );

  Future<Map<String, dynamic>> recover(
    String dataHome, {
    DataHomePhaseHandler? onPhase,
  }) => _execute(
    ConversationProtocolMethod.dataHomeRecover,
    <String, dynamic>{'dataHome': dataHome, 'confirmed': true},
    dedicated: true,
    onPhase: onPhase,
  );

  Future<Map<String, dynamic>> cleanupPrevious(
    String expectedPreviousRootPath, {
    DataHomePhaseHandler? onPhase,
  }) => _execute(
    ConversationProtocolMethod.dataHomeCleanup,
    <String, dynamic>{
      'confirmed': true,
      'expectedPreviousRootPath': expectedPreviousRootPath,
    },
    dedicated: true,
    onPhase: onPhase,
  );

  Future<Map<String, dynamic>> _execute(
    ConversationProtocolMethod method,
    Map<String, dynamic> params, {
    bool dedicated = false,
    DataHomePhaseHandler? onPhase,
  }) async {
    final cli = await _processContext.resolveCliBinary();
    final context = _processContext;
    final builtEnvironment =
        dedicated && context is NativeCliDataHomeMutationContext
        ? await (context as NativeCliDataHomeMutationContext)
              .buildDataHomeMutationEnvironment()
        : await context.buildEnvironment();
    final environment = dedicated
        ? environmentWithoutInheritedRoot(builtEnvironment)
        : builtEnvironment;
    final requestId = newStdioRpcWorkflowId();
    final request = encodeDataHomeRpcRequest(
      method: method,
      params: params,
      requestId: requestId,
    );
    final process = await _processContext.startProcess(
      cli?.path ?? 'licoup-cli',
      dedicated
          ? const <String>['rpc', 'data-home']
          : const <String>['rpc', 'stdio'],
      environment,
    );

    final stdoutFuture = _readBounded(
      process.stdout,
      conversationProtocolMaxResponseBytes,
    );
    final stderrFuture = _readProgress(process.stderr, onPhase);
    // Attach handlers before sending the request. The two output streams can
    // finish before the process-exit future wakes this coroutine; Future.wait
    // keeps their bounded-reader failures observed while still draining both.
    final completion = Future.wait<dynamic>(<Future<dynamic>>[
      process.exitCode,
      stdoutFuture,
      stderrFuture,
    ], eagerError: false);
    var requestSubmitted = false;
    try {
      process.stdin.add(<int>[...request, 10]);
      await process.stdin.close();
      requestSubmitted = true;
      final completed = await completion;
      final exitCode = completed[0] as int;
      final output = completed[1] as List<int>;
      if (exitCode != 0) {
        throw const LicoClientRpcException('data_home_operation_failed');
      }
      return decodeDataHomeResponse(output, requestId);
    } on Object {
      if (!requestSubmitted) process.kill();
      rethrow;
    }
  }
}

List<int> encodeDataHomeRpcRequest({
  required ConversationProtocolMethod method,
  required Map<String, dynamic> params,
  required String requestId,
}) => ConversationCommand(
  id: requestId,
  workflowId: requestId,
  method: method,
  params: params,
).encode();

Map<String, String> environmentWithoutInheritedRoot(
  Map<String, String>? environment,
) => <String, String>{
  ...?environment,
  // buildEnvironment may add its internal effective root. The one-shot
  // process must resolve the boot locator itself, after the UI has closed all
  // old-root consumers; an inherited shell override is never forwarded.
  'LICOUP_HOME': '',
  'LICOUP_PORTABLE_DIR': '',
};

Map<String, dynamic> decodeDataHomeResponse(List<int> bytes, String requestId) {
  if (bytes.isEmpty || bytes.length > conversationProtocolMaxResponseBytes) {
    throw const LicoClientRpcException('transport_failed');
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['protocol'] != conversationProtocolVersion ||
        decoded['id'] != requestId ||
        decoded['workflowId'] != requestId) {
      throw const LicoClientRpcException('transport_failed');
    }
    if (decoded['ok'] != true) {
      final error = decoded['error'];
      final code = error is Map<String, dynamic> ? error['code'] : null;
      throw LicoClientRpcException(
        code is String && validStdioRpcErrorCode(code)
            ? code
            : 'data_home_operation_failed',
      );
    }
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const LicoClientRpcException('transport_failed');
    }
    return result;
  } on LicoClientRpcException {
    rethrow;
  } on Object {
    throw const LicoClientRpcException('transport_failed');
  }
}

Future<List<int>> _readBounded(Stream<List<int>> stream, int limit) async {
  final output = BytesBuilder(copy: false);
  var oversized = false;
  await for (final chunk in stream) {
    if (oversized) continue;
    if (output.length + chunk.length > limit) {
      oversized = true;
      continue;
    }
    output.add(chunk);
  }
  if (oversized) throw const LicoClientRpcException('response_too_large');
  return output.takeBytes();
}

Future<void> _readProgress(
  Stream<List<int>> stream,
  DataHomePhaseHandler? onPhase,
) async {
  var totalBytes = 0;
  var oversized = false;
  final lineBuffer = StringBuffer();
  await for (final chunk in stream) {
    totalBytes += chunk.length;
    if (totalBytes > conversationProtocolMaxStderrBytes) oversized = true;
    if (oversized) continue;
    final text = utf8.decode(chunk, allowMalformed: true);
    for (final codeUnit in text.codeUnits) {
      if (codeUnit == 10) {
        _reportPhase(lineBuffer.toString().trim(), onPhase);
        lineBuffer.clear();
      } else {
        lineBuffer.writeCharCode(codeUnit);
      }
    }
  }
  if (oversized) throw const LicoClientRpcException('stderr_too_large');
  if (lineBuffer.isNotEmpty) {
    _reportPhase(lineBuffer.toString().trim(), onPhase);
  }
}

void _reportPhase(String line, DataHomePhaseHandler? onPhase) {
  const prefix = 'LICOUP_DATA_HOME_PHASE=';
  if (!line.startsWith(prefix)) return;
  final phase = line.substring(prefix.length);
  if (!const <String>{
    'stopping-writers',
    'stopping-conversation-host',
    'stopping-mcp-service',
    'stopping-gateway',
    'waiting-for-native-access',
    'copying-data',
    'publishing-data',
    'updating-owned-references',
    'switching-data-home',
    'cleaning-previous-root',
    'complete',
  }.contains(phase)) {
    return;
  }
  try {
    onPhase?.call(phase);
  } on Object {
    // Progress projection does not own or interrupt the native operation.
  }
}
