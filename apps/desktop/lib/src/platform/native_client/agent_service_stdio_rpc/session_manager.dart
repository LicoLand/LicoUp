import 'dart:io';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

class StdioRpcSessionManager {
  StdioRpcSessionManager({required NativeCliProcessContext processContext})
    : _processContext = processContext;

  final NativeCliProcessContext _processContext;
  StdioRpcSession? _session;
  var _generation = 0;

  Future<StdioRpcSession> ensureSession() async {
    final processGeneration = _generation;
    final current = _session;
    if (current != null && current.usable) {
      return current;
    }
    if (current != null) {
      await discard(session: current, kill: true);
    }

    late File? cli;
    late Map<String, String>? environment;
    try {
      cli = await _processContext.resolveCliBinary();
      environment = await _processContext.buildEnvironment();
    } on Object {
      throw const LicoClientRpcException('setup_failed');
    }
    if (processGeneration != _generation) {
      throw const LicoClientRpcException('transport_failed');
    }
    final executable = cli?.path ?? 'lico-client';
    late Process process;
    try {
      process = await _processContext.startProcess(executable, const [
        'rpc',
        'stdio',
      ], environment);
    } on Object {
      throw const LicoClientRpcException('start_failed');
    }
    if (processGeneration != _generation) {
      process.kill();
      try {
        await process.exitCode.timeout(stdioRpcShutdownTimeout);
      } on Object {
        // A superseded process is never admitted into the active session.
      }
      throw const LicoClientRpcException('transport_failed');
    }
    late StdioRpcSession session;
    try {
      session = StdioRpcSession(process);
    } on Object {
      process.kill();
      throw const LicoClientRpcException('transport_failed');
    }
    _session = session;
    return session;
  }

  Future<void> invalidateAndDiscard() {
    _generation += 1;
    return discard(kill: true);
  }

  StdioRpcSession? takeForShutdown() {
    _generation += 1;
    final session = _session;
    _session = null;
    return session;
  }

  Future<void> discard({StdioRpcSession? session, required bool kill}) async {
    final target = session ?? _session;
    if (target == null) {
      return;
    }
    if (identical(_session, target)) {
      _session = null;
    }
    try {
      await target.close(kill: kill);
    } on Object {
      target.process.kill();
    }
  }
}
