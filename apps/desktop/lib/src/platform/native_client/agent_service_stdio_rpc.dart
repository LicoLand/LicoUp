part of 'package:flutter_client/src/platform/native_client/agent_service.dart';

const String _stdioRpcProtocol = 'lico-client.stdio.v1';
const int _stdioRpcMaxFrameBytes = 16 * 1024 * 1024;
const int _stdioRpcMaxStderrBytes = 512 * 1024;
const int _stdioRpcMaxErrorCodeBytes = 64;
const int _stdioRpcMaxArgs = 256;
const int _stdioRpcMaxArgumentCodeUnits = 1024 * 1024;
const Duration _stdioRpcShutdownTimeout = Duration(seconds: 2);

int _stdioRpcWorkflowSequence = 0;

String _newStdioRpcWorkflowId() {
  _stdioRpcWorkflowSequence = (_stdioRpcWorkflowSequence + 1) & 0x7fffffff;
  final instant = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'lico-arc-$instant-${_stdioRpcWorkflowSequence.toRadixString(36)}';
}

mixin AgentServiceStdioRpc {
  AgentService get _stdioRpcAgentService => this as AgentService;

  late final String _stdioRpcWorkflowId = _newStdioRpcWorkflowId();
  Future<void> _stdioRpcQueue = Future<void>.value();
  Future<void>? _stdioRpcDisposeFuture;
  _StdioRpcSession? _stdioRpcSession;
  var _stdioRpcRequestSequence = 0;
  var _stdioRpcProcessGeneration = 0;
  var _stdioRpcClosing = false;

  Future<Map<String, dynamic>> _runCliOverStdioRpc(List<String> args) {
    if (_stdioRpcClosing) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('service_disposed'),
      );
    }
    if (_stdioRpcAgentService._privateRuntimeTimeout <= Duration.zero) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_timeout'),
      );
    }
    if (!_validStdioRpcArgs(args)) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_request'),
      );
    }
    final requestArgs = List<String>.unmodifiable(args);
    return _serializeStdioRpc(
      () => _executeStdioRpc(requestArgs).timeout(
        _stdioRpcAgentService._privateRuntimeTimeout,
        onTimeout: () async {
          _stdioRpcProcessGeneration += 1;
          await _discardStdioRpcSession(kill: true);
          throw const LicoClientRpcException('timeout');
        },
      ),
    );
  }

  Stream<Map<String, dynamic>> _streamConversationOverStdioRpc(
    Map<String, dynamic> params,
  ) {
    if (_stdioRpcClosing) {
      return Stream<Map<String, dynamic>>.error(
        const LicoClientRpcException('service_disposed'),
      );
    }
    if (_stdioRpcAgentService._privateRuntimeTimeout <= Duration.zero) {
      return Stream<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_timeout'),
      );
    }
    final controller = StreamController<Map<String, dynamic>>();
    final previous = _stdioRpcQueue;
    final completed = Completer<void>();
    _stdioRpcQueue = previous
        .then<void>((_) => completed.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    unawaited(() async {
      try {
        await previous;
        await for (final event in _executeConversationStdioRpc(
          params,
        ).timeout(_stdioRpcAgentService._privateRuntimeTimeout)) {
          controller.add(event);
        }
        await controller.close();
      } on TimeoutException catch (_, stackTrace) {
        _stdioRpcProcessGeneration += 1;
        await _discardStdioRpcSession(kill: true);
        controller.addError(
          const LicoClientRpcException('timeout'),
          stackTrace,
        );
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
        await controller.close();
      } finally {
        if (!completed.isCompleted) {
          completed.complete();
        }
      }
    }());
    return controller.stream;
  }

  Stream<Map<String, dynamic>> _executeConversationStdioRpc(
    Map<String, dynamic> params,
  ) async* {
    final requestId = 'request-${++_stdioRpcRequestSequence}';
    final request = <String, dynamic>{
      'protocol': _stdioRpcProtocol,
      'id': requestId,
      'workflowId': _stdioRpcWorkflowId,
      'method': 'agent.conversation.send',
      'params': params,
    };
    final encoded = _encodeStdioRpcFrame(request);
    final session = await _ensureStdioRpcSession();
    late Stream<_StdioRpcFrame> frames;
    try {
      frames = session.expectFrames(
        requestId: requestId,
        workflowId: _stdioRpcWorkflowId,
      );
      session.process.stdin.add(encoded);
      session.process.stdin.add(const [0x0a]);
      await session.process.stdin.flush();
    } on Object {
      session.abandonExpectedFrame();
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('transport_failed');
    }

    var expectedSequence = 1;
    var terminalSeen = false;
    try {
      await for (final frame in frames) {
        final bytes = frame.bytes;
        if (bytes == null) {
          throw const LicoClientRpcException('transport_failed');
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic> ||
            decoded['protocol'] != _stdioRpcProtocol ||
            decoded['id'] != requestId ||
            decoded['workflowId'] != _stdioRpcWorkflowId ||
            decoded['sequence'] != expectedSequence) {
          throw const LicoClientRpcException('invalid_response');
        }
        expectedSequence += 1;
        final kind = decoded['kind'];
        if (kind == 'event' && !terminalSeen) {
          final event = decoded['event'];
          if (event is! Map<String, dynamic> ||
              (event['event'] ?? '').toString().trim().isEmpty ||
              (event['sessionId'] ?? '').toString().trim().isEmpty ||
              (event['turnId'] ?? '').toString().trim().isEmpty) {
            throw const LicoClientRpcException('invalid_response');
          }
          yield Map<String, dynamic>.from(event);
          continue;
        }
        if (kind != 'terminal' || terminalSeen || decoded['ok'] is! bool) {
          throw const LicoClientRpcException('invalid_response');
        }
        terminalSeen = true;
        session.completeExpectedFrames();
        if (decoded['ok'] == true) {
          final result = decoded['result'];
          if (result is! Map<String, dynamic>) {
            throw const LicoClientRpcException('invalid_response');
          }
          yield <String, dynamic>{...result, 'event': 'done'};
          return;
        }
        final error = decoded['error'];
        final rawCode = error is Map<String, dynamic> ? error['code'] : null;
        final code = rawCode is String && _validStdioRpcErrorCode(rawCode)
            ? rawCode
            : 'command_failed';
        throw LicoClientRpcException(code);
      }
      if (!terminalSeen) {
        throw const LicoClientRpcException('transport_failed');
      }
    } on Object {
      session.abandonExpectedFrame();
      await _discardStdioRpcSession(session: session, kill: true);
      rethrow;
    }
  }

  Future<T> _serializeStdioRpc<T>(Future<T> Function() operation) {
    final result = _stdioRpcQueue.then<T>((_) => operation());
    _stdioRpcQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, dynamic>> _executeStdioRpc(List<String> args) async {
    final requestId = 'request-${++_stdioRpcRequestSequence}';
    final request = <String, dynamic>{
      'protocol': _stdioRpcProtocol,
      'id': requestId,
      'workflowId': _stdioRpcWorkflowId,
      'method': 'execute',
      'args': args,
    };
    final encoded = _encodeStdioRpcFrame(request);
    final session = await _ensureStdioRpcSession();
    late Future<_StdioRpcFrame> responseFuture;
    try {
      responseFuture = session.expectFrame();
    } on Object {
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('transport_failed');
    }

    // A write may have reached native code even if flush later fails. Never
    // replay this request on a replacement process because commands can mutate
    // client state.
    try {
      session.process.stdin.add(encoded);
      session.process.stdin.add(const [0x0a]);
      await session.process.stdin.flush();
    } on Object {
      session.abandonExpectedFrame();
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('transport_failed');
    }

    late _StdioRpcFrame responseFrame;
    try {
      responseFrame = await responseFuture;
    } on Object {
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('transport_failed');
    }
    final responseBytes = responseFrame.bytes;
    if (responseBytes == null) {
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('transport_failed');
    }
    return _decodeStdioRpcResponse(
      responseBytes,
      requestId: requestId,
      session: session,
    );
  }

  Uint8List _encodeStdioRpcFrame(Map<String, dynamic> request) {
    late Uint8List encoded;
    try {
      encoded = Uint8List.fromList(utf8.encode(jsonEncode(request)));
    } on Object {
      throw const LicoClientRpcException('invalid_request');
    }
    if (encoded.length + 1 > _stdioRpcMaxFrameBytes) {
      throw const LicoClientRpcException('request_too_large');
    }
    return encoded;
  }

  Future<_StdioRpcSession> _ensureStdioRpcSession() async {
    final processGeneration = _stdioRpcProcessGeneration;
    final current = _stdioRpcSession;
    if (current != null && current.usable) {
      return current;
    }
    if (current != null) {
      await _discardStdioRpcSession(session: current, kill: true);
    }

    late File? cli;
    late Map<String, String>? environment;
    try {
      cli = await _stdioRpcAgentService._resolveCliBinary();
      environment = await _stdioRpcAgentService._cliEnvironment();
    } on Object {
      throw const LicoClientRpcException('setup_failed');
    }
    if (processGeneration != _stdioRpcProcessGeneration) {
      throw const LicoClientRpcException('transport_failed');
    }
    final executable = cli?.path ?? 'lico-client';
    late Process process;
    try {
      process = await Process.start(executable, const [
        'rpc',
        'stdio',
      ], environment: environment);
    } on Object {
      throw const LicoClientRpcException('start_failed');
    }
    if (processGeneration != _stdioRpcProcessGeneration) {
      process.kill();
      try {
        await process.exitCode.timeout(_stdioRpcShutdownTimeout);
      } on Object {
        // A superseded process is never admitted into the active session.
      }
      throw const LicoClientRpcException('transport_failed');
    }
    late _StdioRpcSession session;
    try {
      session = _StdioRpcSession(process);
    } on Object {
      process.kill();
      throw const LicoClientRpcException('transport_failed');
    }
    _stdioRpcSession = session;
    return session;
  }

  Future<Map<String, dynamic>> _decodeStdioRpcResponse(
    Uint8List bytes, {
    required String requestId,
    required _StdioRpcSession session,
  }) async {
    late dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('invalid_response');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['protocol'] != _stdioRpcProtocol ||
        decoded['id'] != requestId ||
        decoded['workflowId'] != _stdioRpcWorkflowId ||
        decoded['ok'] is! bool) {
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('invalid_response');
    }
    if (decoded['ok'] == true) {
      final result = decoded['result'];
      if (result is Map<String, dynamic>) {
        return result;
      }
      await _discardStdioRpcSession(session: session, kill: true);
      throw const LicoClientRpcException('invalid_response');
    }

    final error = decoded['error'];
    final rawCode = error is Map<String, dynamic> ? error['code'] : null;
    final code = rawCode is String && _validStdioRpcErrorCode(rawCode)
        ? rawCode
        : 'command_failed';
    throw LicoClientRpcException(code);
  }

  Future<void> _discardStdioRpcSession({
    _StdioRpcSession? session,
    required bool kill,
  }) async {
    final target = session ?? _stdioRpcSession;
    if (target == null) {
      return;
    }
    if (identical(_stdioRpcSession, target)) {
      _stdioRpcSession = null;
    }
    try {
      await target.close(kill: kill);
    } on Object {
      target.process.kill();
    }
  }

  Future<void> dispose() {
    final existing = _stdioRpcDisposeFuture;
    if (existing != null) {
      return existing;
    }
    _stdioRpcClosing = true;
    final disposeFuture = _stdioRpcQueue.then<void>((_) async {
      _stdioRpcProcessGeneration += 1;
      final session = _stdioRpcSession;
      _stdioRpcSession = null;
      if (session == null) {
        return;
      }
      final requestId = 'request-${++_stdioRpcRequestSequence}';
      final frame = _encodeStdioRpcFrame({
        'protocol': _stdioRpcProtocol,
        'id': requestId,
        'workflowId': _stdioRpcWorkflowId,
        'method': 'shutdown',
      });
      var acknowledged = false;
      Future<_StdioRpcFrame>? responseFuture;
      try {
        responseFuture = session.expectFrame();
        session.process.stdin.add(frame);
        session.process.stdin.add(const [0x0a]);
        await session.process.stdin.flush();
        final responseFrame = await responseFuture.timeout(
          _stdioRpcShutdownTimeout,
        );
        final response = responseFrame.bytes;
        final decoded = response == null
            ? null
            : jsonDecode(utf8.decode(response));
        acknowledged =
            decoded is Map<String, dynamic> &&
            decoded['protocol'] == _stdioRpcProtocol &&
            decoded['id'] == requestId &&
            decoded['workflowId'] == _stdioRpcWorkflowId &&
            decoded['ok'] == true;
      } on Object {
        if (responseFuture != null) {
          session.abandonExpectedFrame();
        }
        acknowledged = false;
      }
      await session.close(kill: !acknowledged);
    });
    _stdioRpcDisposeFuture = disposeFuture.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _stdioRpcQueue = _stdioRpcDisposeFuture!;
    return _stdioRpcDisposeFuture!;
  }
}

bool _validStdioRpcErrorCode(String value) {
  if (value.isEmpty || value.length > _stdioRpcMaxErrorCodeBytes) {
    return false;
  }
  for (final codeUnit in value.codeUnits) {
    final lowercase = codeUnit >= 0x61 && codeUnit <= 0x7a;
    final digit = codeUnit >= 0x30 && codeUnit <= 0x39;
    if (!lowercase && !digit && codeUnit != 0x5f) {
      return false;
    }
  }
  return true;
}

bool _validStdioRpcArgs(List<String> args) {
  if (args.isEmpty || args.length > _stdioRpcMaxArgs) {
    return false;
  }
  var codeUnits = 0;
  for (final arg in args) {
    codeUnits += arg.length;
    if (codeUnits > _stdioRpcMaxArgumentCodeUnits) {
      return false;
    }
  }
  return true;
}

class _StdioRpcSession {
  _StdioRpcSession(this.process) {
    _stdoutSubscription = process.stdout.listen(
      _acceptStdoutChunk,
      onError: (Object _, StackTrace _) {
        _addFrameError();
      },
      onDone: () {
        _addFrameError();
      },
      cancelOnError: false,
    );
    _stderrSubscription = process.stderr.listen(
      _acceptStderrChunk,
      onError: (Object _, StackTrace _) {
        stderrTruncated = true;
      },
      cancelOnError: false,
    );
    unawaited(
      process.exitCode.then<void>(
        (_) {
          _addFrameError();
        },
        onError: (Object _, StackTrace _) {
          _addFrameError();
        },
      ),
    );
  }

  final Process process;
  final BytesBuilder _currentFrame = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  Completer<_StdioRpcFrame>? _expectedFrame;
  StreamController<_StdioRpcFrame>? _expectedFrames;
  String? _expectedStreamRequestId;
  String? _expectedStreamWorkflowId;
  var _expectedStreamSequence = 1;
  var _currentFrameBytes = 0;
  var _discardingOversizedFrame = false;
  var _closed = false;
  var usable = true;
  var stderrBytes = 0;
  var stderrTruncated = false;

  Future<_StdioRpcFrame> expectFrame() {
    if (!usable ||
        _closed ||
        _expectedFrame != null ||
        _expectedFrames != null) {
      throw const _StdioRpcTransportFailure();
    }
    final completer = Completer<_StdioRpcFrame>();
    _expectedFrame = completer;
    return completer.future;
  }

  Stream<_StdioRpcFrame> expectFrames({
    required String requestId,
    required String workflowId,
  }) {
    if (!usable ||
        _closed ||
        _expectedFrame != null ||
        _expectedFrames != null) {
      throw const _StdioRpcTransportFailure();
    }
    final controller = StreamController<_StdioRpcFrame>();
    _expectedFrames = controller;
    _expectedStreamRequestId = requestId;
    _expectedStreamWorkflowId = workflowId;
    _expectedStreamSequence = 1;
    return controller.stream;
  }

  void completeExpectedFrames() {
    final expectedFrames = _expectedFrames;
    _expectedFrames = null;
    _clearExpectedStreamIdentity();
    if (expectedFrames != null && !expectedFrames.isClosed) {
      unawaited(expectedFrames.close());
    }
  }

  void abandonExpectedFrame() {
    final expectedFrame = _expectedFrame;
    _expectedFrame = null;
    if (expectedFrame != null && !expectedFrame.isCompleted) {
      expectedFrame.complete(const _StdioRpcFrame.failure());
    }
    final expectedFrames = _expectedFrames;
    _expectedFrames = null;
    _clearExpectedStreamIdentity();
    if (expectedFrames != null && !expectedFrames.isClosed) {
      expectedFrames.add(const _StdioRpcFrame.failure());
      unawaited(expectedFrames.close());
    }
  }

  void _acceptStdoutChunk(List<int> chunk) {
    if (!usable || _closed) {
      return;
    }
    var start = 0;
    for (var index = 0; index < chunk.length; index += 1) {
      if (chunk[index] != 0x0a) {
        continue;
      }
      _appendFrameBytes(chunk, start, index);
      _finishFrame();
      start = index + 1;
    }
    _appendFrameBytes(chunk, start, chunk.length);
  }

  void _appendFrameBytes(List<int> chunk, int start, int end) {
    if (!usable || _closed || start >= end || _discardingOversizedFrame) {
      return;
    }
    final length = end - start;
    if (_expectedFrame == null && _expectedFrames == null) {
      _addFrameError();
      return;
    }
    if (_currentFrameBytes + length + 1 > _stdioRpcMaxFrameBytes) {
      _discardingOversizedFrame = true;
      _currentFrame.clear();
      _currentFrameBytes = 0;
      return;
    }
    _currentFrame.add(chunk.sublist(start, end));
    _currentFrameBytes += length;
  }

  void _finishFrame() {
    if (_discardingOversizedFrame) {
      _discardingOversizedFrame = false;
      _addFrameError();
      return;
    }
    var bytes = _currentFrame.takeBytes();
    _currentFrameBytes = 0;
    if (bytes.isNotEmpty && bytes.last == 0x0d) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    final expectedFrame = _expectedFrame;
    final expectedFrames = _expectedFrames;
    if (expectedFrame == null && expectedFrames == null) {
      _addFrameError();
      return;
    }
    if (expectedFrame != null) {
      _expectedFrame = null;
      expectedFrame.complete(_StdioRpcFrame.data(bytes));
    } else {
      if (!_acceptStreamingFrame(expectedFrames!, bytes)) {
        _addFrameError();
      }
    }
  }

  void _acceptStderrChunk(List<int> chunk) {
    final remaining = _stdioRpcMaxStderrBytes - stderrBytes;
    if (remaining <= 0) {
      stderrTruncated = true;
      return;
    }
    final accepted = chunk.length <= remaining ? chunk.length : remaining;
    stderrBytes += accepted;
    if (accepted != chunk.length) {
      stderrTruncated = true;
    }
  }

  void _addFrameError() {
    if (!usable && _expectedFrame == null && _expectedFrames == null) {
      return;
    }
    usable = false;
    final expectedFrame = _expectedFrame;
    _expectedFrame = null;
    if (expectedFrame != null && !expectedFrame.isCompleted) {
      expectedFrame.complete(const _StdioRpcFrame.failure());
    }
    final expectedFrames = _expectedFrames;
    _expectedFrames = null;
    _clearExpectedStreamIdentity();
    if (expectedFrames != null && !expectedFrames.isClosed) {
      expectedFrames.add(const _StdioRpcFrame.failure());
      unawaited(expectedFrames.close());
    }
  }

  bool _acceptStreamingFrame(
    StreamController<_StdioRpcFrame> controller,
    Uint8List bytes,
  ) {
    late dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      return _failStreamingProtocol(controller, bytes);
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['protocol'] != _stdioRpcProtocol ||
        decoded['id'] != _expectedStreamRequestId ||
        decoded['workflowId'] != _expectedStreamWorkflowId ||
        decoded['sequence'] != _expectedStreamSequence) {
      return _failStreamingProtocol(controller, bytes);
    }
    final kind = decoded['kind'];
    if (kind != 'event' && kind != 'terminal') {
      return _failStreamingProtocol(controller, bytes);
    }
    _expectedStreamSequence += 1;
    controller.add(_StdioRpcFrame.data(bytes));
    if (kind == 'terminal') {
      _expectedFrames = null;
      _clearExpectedStreamIdentity();
      unawaited(controller.close());
    }
    return true;
  }

  bool _failStreamingProtocol(
    StreamController<_StdioRpcFrame> controller,
    Uint8List bytes,
  ) {
    usable = false;
    _expectedFrames = null;
    _clearExpectedStreamIdentity();
    controller.add(_StdioRpcFrame.data(bytes));
    unawaited(controller.close());
    return true;
  }

  void _clearExpectedStreamIdentity() {
    _expectedStreamRequestId = null;
    _expectedStreamWorkflowId = null;
    _expectedStreamSequence = 1;
  }

  Future<void> close({required bool kill}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    usable = false;
    if (kill) {
      process.kill();
    }
    try {
      await process.stdin.close();
    } on Object {
      // Close errors are intentionally redacted and ignored during teardown.
    }
    try {
      await process.exitCode.timeout(_stdioRpcShutdownTimeout);
    } on Object {
      process.kill();
      try {
        await process.exitCode.timeout(_stdioRpcShutdownTimeout);
      } on Object {
        // The process is already detached from this service instance.
      }
    }
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    _addFrameError();
  }
}

class _StdioRpcTransportFailure implements Exception {
  const _StdioRpcTransportFailure();
}

class _StdioRpcFrame {
  const _StdioRpcFrame.data(this.bytes);
  const _StdioRpcFrame.failure() : bytes = null;

  final Uint8List? bytes;
}
