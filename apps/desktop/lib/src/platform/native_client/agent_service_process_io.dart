import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

const int _privateRuntimeMaxInputBytes = 1024 * 1024;
const int _privateRuntimeMaxStdoutBytes = 20 * 1024 * 1024;
const int _privateRuntimeMaxStderrBytes = 512 * 1024;

class _BoundedProcessOutput {
  const _BoundedProcessOutput({required this.bytes, required this.truncated});

  final Uint8List bytes;
  final bool truncated;
}

class BoundedNativeProcessIo implements AgentCommandRunner {
  BoundedNativeProcessIo({
    required NativeCliProcessContext processContext,
    required NativeCommandExecutor commandExecutor,
    required NativeStdioRpcTransport stdioRpcTransport,
    required bool persistentStdioRpcEnabled,
  }) : _processContext = processContext,
       _commandExecutor = commandExecutor,
       _stdioRpcTransport = stdioRpcTransport,
       _persistentStdioRpcEnabled = persistentStdioRpcEnabled;

  final NativeCliProcessContext _processContext;
  final NativeCommandExecutor _commandExecutor;
  final NativeStdioRpcTransport _stdioRpcTransport;
  final bool _persistentStdioRpcEnabled;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    return _commandExecutor.execute(args);
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final stdinBytes = utf8.encode(stdinText);
    if (stdinBytes.length > _privateRuntimeMaxInputBytes) {
      throw Exception('licoup private runtime request is too large.');
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      throw Exception('licoup private runtime timeout is invalid.');
    }
    if (_persistentStdioRpcEnabled) {
      // Routing is driven by the schema-derived conversation protocol
      // registry: a matching CLI shape becomes a structured method frame and
      // the stdin JSON becomes structured params. No CLI argument array is
      // ever passed through the persistent RPC channel; the CLI shape only
      // selects which registered protocol method the callers mean.
      final route = conversationProtocolCliRoute(args);
      if (route != null) {
        // LLM credentials stay on the same process-local authorization context
        // as inventory reads and Gateway start. The JSON remains inside the
        // structured stdio RPC frame and is never projected to logs.
        return _stdioRpcTransport.executeStructured(
          route.method.wireName,
          _routeStdinParams(route, args, stdinText),
        );
      }
    }
    late Process process;
    try {
      final cli = await _processContext.resolveCliBinary();
      final environment = await _processContext.buildEnvironment();
      process = await _processContext.startProcess(
        cli?.path ?? 'licoup-cli',
        args,
        environment,
      );
    } on Object {
      throw Exception('licoup executable could not be started.');
    }

    final stdoutFuture = _collectBoundedProcessOutput(
      process.stdout,
      _privateRuntimeMaxStdoutBytes,
    );
    final stderrFuture = _collectBoundedProcessOutput(
      process.stderr,
      _privateRuntimeMaxStderrBytes,
    );
    late int exitCode;
    late _BoundedProcessOutput stdoutOutput;
    late _BoundedProcessOutput stderrOutput;
    try {
      process.stdin.add(stdinBytes);
      await Future.wait<dynamic>([
        process.stdin.close(),
        process.exitCode,
        stdoutFuture,
        stderrFuture,
      ]).timeout(_processContext.requestTimeout);
      exitCode = await process.exitCode;
      stdoutOutput = await stdoutFuture;
      stderrOutput = await stderrFuture;
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        // The error returned to the caller stays fixed and redacted.
      }
      throw Exception('licoup private runtime request timed out.');
    } on Object {
      process.kill();
      throw Exception('licoup private runtime request failed.');
    }
    if (stdoutOutput.truncated || stderrOutput.truncated) {
      throw Exception('licoup private runtime output exceeded its limit.');
    }
    if (exitCode != 0) {
      throw Exception(
        'licoup failed while sending a private runtime request '
        '(exit code $exitCode, stderr bytes ${stderrOutput.bytes.length}).',
      );
    }
    late dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(stdoutOutput.bytes));
    } on Object {
      throw Exception('licoup returned an invalid JSON response.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception('licoup returned an invalid JSON response.');
    }
    return decoded;
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) async* {
    yield* streamCliJsonLinesWithStdin(args, '');
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    if (_persistentStdioRpcEnabled) {
      final route = conversationProtocolCliRoute(args);
      if (route != null &&
          conversationProtocolMethodIsStream(route.method.wireName)) {
        final operation =
            route.method.wireName.startsWith('agent.conversation.')
            ? route.method.wireName.substring('agent.conversation.'.length)
            : route.method.wireName;
        try {
          await for (final event in _stdioRpcTransport.streamConversation({
            ..._routeStdinParams(route, args, stdinText),
            // The default conversation exchange operation is 'send'; only
            // non-default operations need an explicit operation marker.
            if (operation != 'send') '_rpcOperation': operation,
          })) {
            yield event;
          }
        } on LicoClientRpcException catch (error) {
          throw AgentDispatchStreamException(error.code);
        } on Object {
          throw const AgentDispatchStreamException('transport_failed');
        }
        return;
      }
    }
    final stdinBytes = utf8.encode(stdinText);
    if (stdinBytes.length > _privateRuntimeMaxInputBytes) {
      throw Exception('licoup private runtime request is too large.');
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      throw Exception('licoup private runtime timeout is invalid.');
    }
    late Process process;
    try {
      final cli = await _processContext.resolveCliBinary();
      final environment = await _processContext.buildEnvironment();
      process = await _processContext.startProcess(
        cli?.path ?? 'licoup-cli',
        args,
        environment,
      );
    } on Object {
      throw Exception('licoup executable could not be started.');
    }

    final stderrFuture = _collectBoundedProcessOutput(
      process.stderr,
      _privateRuntimeMaxStderrBytes,
    );
    var stdoutBytes = 0;
    try {
      if (stdinBytes.isNotEmpty) {
        process.stdin.add(stdinBytes);
      }
      await process.stdin.close();
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(_processContext.requestTimeout)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        stdoutBytes += utf8.encode(line).length + 1;
        if (stdoutBytes > _privateRuntimeMaxStdoutBytes) {
          throw Exception('licoup private runtime output exceeded its limit.');
        }
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          yield decoded;
        }
      }
    } on TimeoutException {
      process.kill();
      throw Exception('licoup private runtime request timed out.');
    } on Object {
      process.kill();
      throw Exception('licoup private runtime stream failed.');
    }

    final exitCode = await process.exitCode;
    final stderrOutput = await stderrFuture;
    if (stderrOutput.truncated) {
      throw Exception('licoup stream output exceeded its limit.');
    }
    if (exitCode != 0) {
      throw Exception(
        'licoup stream failed '
        '(exit code $exitCode, stderr bytes ${stderrOutput.bytes.length}).',
      );
    }
  }
}

Map<String, dynamic> _routeStdinParams(
  ConversationProtocolCliRoute route,
  List<String> args,
  String stdinText,
) {
  late dynamic request;
  try {
    request = jsonDecode(stdinText);
  } on Object {
    throw const LicoClientRpcException('invalid_request');
  }
  if (request is! Map<String, dynamic>) {
    throw const LicoClientRpcException('invalid_request');
  }
  final params = Map<String, dynamic>.from(request);
  for (final alias in route.paramAliases) {
    final value = alias.argvIndex < args.length ? args[alias.argvIndex] : '';
    if (value.isNotEmpty && !params.containsKey(alias.param)) {
      params[alias.param] = value;
    }
  }
  return params;
}

Future<_BoundedProcessOutput> _collectBoundedProcessOutput(
  Stream<List<int>> stream,
  int maxBytes,
) async {
  final bytes = BytesBuilder(copy: false);
  var retained = 0;
  var truncated = false;
  await for (final chunk in stream) {
    final remaining = maxBytes - retained;
    if (remaining <= 0) {
      truncated = true;
      continue;
    }
    final take = chunk.length <= remaining ? chunk.length : remaining;
    bytes.add(chunk.sublist(0, take));
    retained += take;
    if (take != chunk.length) {
      truncated = true;
    }
  }
  return _BoundedProcessOutput(bytes: bytes.takeBytes(), truncated: truncated);
}
