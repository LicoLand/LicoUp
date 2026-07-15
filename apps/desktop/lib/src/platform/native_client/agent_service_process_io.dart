part of 'package:flutter_client/src/platform/native_client/agent_service.dart';

const int _privateRuntimeMaxInputBytes = 1024 * 1024;
const int _privateRuntimeMaxStdoutBytes = 20 * 1024 * 1024;
const int _privateRuntimeMaxStderrBytes = 512 * 1024;

class _BoundedProcessOutput {
  const _BoundedProcessOutput({required this.bytes, required this.truncated});

  final Uint8List bytes;
  final bool truncated;
}

mixin AgentServiceProcessIo implements AgentCommandRunner {
  AgentService get _agentService => this as AgentService;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final stdinBytes = utf8.encode(stdinText);
    if (stdinBytes.length > _privateRuntimeMaxInputBytes) {
      throw Exception('lico-client private runtime request is too large.');
    }
    if (_agentService._privateRuntimeTimeout <= Duration.zero) {
      throw Exception('lico-client private runtime timeout is invalid.');
    }
    final cli = await _agentService._resolveCliBinary();
    final env = await _agentService._cliEnvironment();
    final executable = cli?.path ?? 'lico-client';
    late Process process;
    try {
      process = await _agentService._startCliExecutable(executable, args, env);
    } catch (_) {
      throw Exception('lico-client executable could not be started.');
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
      ]).timeout(_agentService._privateRuntimeTimeout);
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
      throw Exception('lico-client private runtime request timed out.');
    } on Object {
      process.kill();
      throw Exception('lico-client private runtime request failed.');
    }
    if (stdoutOutput.truncated || stderrOutput.truncated) {
      throw Exception('lico-client private runtime output exceeded its limit.');
    }
    if (exitCode != 0) {
      throw Exception(
        'lico-client failed while sending a private runtime request '
        '(exit code $exitCode, stderr bytes ${stderrOutput.bytes.length}).',
      );
    }
    late dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(stdoutOutput.bytes));
    } on Object {
      throw Exception('lico-client returned an invalid JSON response.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception('lico-client returned an invalid JSON response.');
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
    if (_agentService._persistentStdioRpcEnabled &&
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
      yield* _agentService._streamConversationOverStdioRpc(request);
      return;
    }
    final stdinBytes = utf8.encode(stdinText);
    if (stdinBytes.length > _privateRuntimeMaxInputBytes) {
      throw Exception('lico-client private runtime request is too large.');
    }
    if (_agentService._privateRuntimeTimeout <= Duration.zero) {
      throw Exception('lico-client private runtime timeout is invalid.');
    }
    final cli = await _agentService._resolveCliBinary();
    final env = await _agentService._cliEnvironment();
    final executable = cli?.path ?? 'lico-client';
    late Process process;
    try {
      process = await _agentService._startCliExecutable(executable, args, env);
    } catch (_) {
      throw Exception('lico-client executable could not be started.');
    }

    final stderrFuture = _collectBoundedProcessOutput(
      process.stderr,
      _privateRuntimeMaxStderrBytes,
    );
    try {
      if (stdinBytes.isNotEmpty) {
        process.stdin.add(stdinBytes);
      }
      await process.stdin.close();
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(_agentService._privateRuntimeTimeout)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          yield decoded;
        }
      }
    } on TimeoutException {
      process.kill();
      throw Exception('lico-client private runtime request timed out.');
    } on Object {
      process.kill();
      rethrow;
    }

    final exitCode = await process.exitCode;
    final stderrOutput = await stderrFuture;
    if (stderrOutput.truncated) {
      throw Exception('lico-client stream output exceeded its limit.');
    }
    if (exitCode != 0) {
      throw Exception(
        'lico-client stream failed '
        '(exit code $exitCode, stderr bytes ${stderrOutput.bytes.length}).',
      );
    }
  }
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
