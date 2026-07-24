import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:licoup/src/contracts/agent_command_runner.dart';
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
    final conversationOperation = _conversationControlOperation(args);
    if (_persistentStdioRpcEnabled && conversationOperation != null) {
      late dynamic request;
      try {
        request = jsonDecode(stdinText);
      } on Object {
        throw const LicoClientRpcException('invalid_request');
      }
      if (request is! Map<String, dynamic>) {
        throw const LicoClientRpcException('invalid_request');
      }
      return _stdioRpcTransport.executeStructured(
        'agent.conversation.$conversationOperation',
        request,
      );
    }
    late Process process;
    try {
      final cli = await _processContext.resolveCliBinary();
      final environment = await _processContext.buildEnvironment();
      process = await _processContext.startProcess(
        cli?.path ?? 'licoup',
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
    if (_persistentStdioRpcEnabled &&
        args.length >= 3 &&
        args[0] == 'agent' &&
        args[1] == 'conversation' &&
        args[2] == 'send') {
      late dynamic request;
      try {
        request = jsonDecode(stdinText);
      } on Object {
        throw const LicoClientRpcException('invalid_request');
      }
      if (request is! Map<String, dynamic>) {
        throw const LicoClientRpcException('invalid_request');
      }
      yield* _stdioRpcTransport.streamConversation(request);
      return;
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
        cli?.path ?? 'licoup',
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
          throw Exception(
            'licoup private runtime output exceeded its limit.',
          );
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

String? _conversationControlOperation(List<String> args) {
  if (args.length < 3 || args[0] != 'agent' || args[1] != 'conversation') {
    return null;
  }
  const controls = <String>{
    'open',
    'history',
    'cleanup',
    'capabilities',
    'cancel',
    'steer',
  };
  return controls.contains(args[2]) ? args[2] : null;
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
