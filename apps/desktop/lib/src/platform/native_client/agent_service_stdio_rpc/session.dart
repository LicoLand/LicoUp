import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/line_framer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_expectation.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

class StdioRpcFrame {
  const StdioRpcFrame.data(this.envelope);
  const StdioRpcFrame.failure() : envelope = null;

  final Map<String, dynamic>? envelope;
}

class StdioRpcTransportFailure implements Exception {
  const StdioRpcTransportFailure();
}

class StdioRpcSession {
  StdioRpcSession(this.process) {
    _stdoutSubscription = process.stdout
        .asyncMap(_acceptStdoutChunk)
        .listen(
          (_) {},
          onError: (Object _, StackTrace _) => _addFrameError(),
          onDone: _addFrameError,
          cancelOnError: false,
        );
    _stderrSubscription = process.stderr.listen(
      _acceptStderrChunk,
      onError: (Object _, StackTrace _) {
        stderrTruncated = true;
      },
      cancelOnError: false,
    );
    // EOF is delivered after asyncMap drains accepted frames. An exitCode
    // callback can overtake a large final reply still being decoded.
  }

  final Process process;
  final StdioRpcLineFramer _framer = StdioRpcLineFramer(
    maxFrameBytes: stdioRpcMaxFrameBytes,
  );
  late final StreamSubscription<void> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  final Map<String, Completer<StdioRpcFrame>> _expectedFrames = {};
  final Map<String, StdioRpcConversationExpectation> _expectedConversations =
      {};
  final Map<String, StdioRpcConversationDecoder> _detachedConversations = {};
  var _closed = false;
  var usable = true;
  var stderrBytes = 0;
  var stderrTruncated = false;

  Future<StdioRpcFrame> expectFrame({required String requestId}) {
    if (!_canExpectRequest(requestId)) {
      throw const StdioRpcTransportFailure();
    }
    final completer = Completer<StdioRpcFrame>();
    _expectedFrames[requestId] = completer;
    return completer.future;
  }

  Stream<StdioRpcConversationFrame> expectConversationFrames({
    required String requestId,
    required String workflowId,
    bool executionObservation = false,
    Future<void> Function()? onCancel,
  }) {
    if (!_canExpectRequest(requestId)) {
      throw const StdioRpcTransportFailure();
    }
    final controller = StreamController<StdioRpcConversationFrame>(
      onCancel: () async {
        if (!executionObservation) return;
        final expectation = _expectedConversations.remove(requestId);
        if (expectation == null) return;
        // Retain only the decoder until native acknowledges detach; late frames
        // belong to this closed observer and cannot poison other live requests.
        _detachedConversations[requestId] = expectation.decoder;
        await onCancel?.call();
      },
    );
    _expectedConversations[requestId] = StdioRpcConversationExpectation(
      controller: controller,
      decoder: StdioRpcConversationDecoder(
        requestId: requestId,
        workflowId: workflowId,
        executionObservation: executionObservation,
      ),
    );
    return controller.stream;
  }

  bool _canExpectRequest(String requestId) =>
      usable &&
      !_closed &&
      requestId.isNotEmpty &&
      !_expectedFrames.containsKey(requestId) &&
      !_expectedConversations.containsKey(requestId) &&
      !_detachedConversations.containsKey(requestId) &&
      _expectedFrames.length + _expectedConversations.length < 64;

  void completeExpectedFrames(String requestId) {
    final controller = _expectedConversations.remove(requestId)?.controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  void abandonExpectedFrame(String requestId) {
    final expectedFrame = _expectedFrames.remove(requestId);
    if (expectedFrame != null && !expectedFrame.isCompleted) {
      expectedFrame.complete(const StdioRpcFrame.failure());
    }
    final controller = _expectedConversations.remove(requestId)?.controller;
    if (controller != null && !controller.isClosed) {
      controller.addError(const LicoClientRpcException('transport_failed'));
      unawaited(controller.close());
    }
  }

  Future<void> _acceptStdoutChunk(List<int> chunk) async {
    if (!usable || _closed) {
      return;
    }
    if (_expectedFrames.isEmpty &&
        _expectedConversations.isEmpty &&
        _detachedConversations.isEmpty) {
      _addFrameError();
      return;
    }
    final frames = <Uint8List>[];
    _framer.accept(
      chunk,
      onFrame: frames.add,
      onOversizedFrame: _addFrameError,
    );
    for (final bytes in frames) {
      if (!usable || _closed) return;
      try {
        // Large catalog/history replies leave the UI isolate. asyncMap pauses
        // stdout during decoding, preserving wire order and backpressure.
        final envelope = bytes.length >= 256 * 1024
            ? await Isolate.run(() => decodeStdioRpcEnvelope(bytes))
            : decodeStdioRpcEnvelope(bytes);
        _acceptEnvelope(envelope);
      } on StdioRpcProtocolViolation {
        _addFrameError();
      }
    }
  }

  void _acceptEnvelope(Map<String, dynamic> envelope) {
    if (!usable || _closed) {
      return;
    }
    final requestId = envelope['id'];
    if (requestId is! String || requestId.isEmpty) {
      _addFrameError();
      return;
    }
    final expectedFrame = _expectedFrames.remove(requestId);
    if (expectedFrame != null) {
      expectedFrame.complete(StdioRpcFrame.data(envelope));
      return;
    }
    final detached = _detachedConversations[requestId];
    if (detached != null) {
      try {
        if (detached.decode(envelope) is StdioRpcConversationTerminal) {
          _detachedConversations.remove(requestId);
        }
      } on StdioRpcProtocolViolation {
        // A malformed abandoned observation is isolated from live consumers.
        // Keep its identity until connection teardown to absorb its late data.
      }
      return;
    }
    final expectation = _expectedConversations[requestId];
    if (expectation == null) {
      _addFrameError();
      return;
    }
    final controller = expectation.controller;
    late StdioRpcConversationFrame frame;
    try {
      frame = expectation.decoder.decode(envelope);
    } on StdioRpcProtocolViolation {
      _expectedConversations.remove(requestId);
      if (!controller.isClosed) {
        controller.addError(const LicoClientRpcException('invalid_response'));
        unawaited(controller.close());
      }
      _addFrameError();
      return;
    }
    controller.add(frame);
    if (frame is StdioRpcConversationTerminal) {
      _expectedConversations.remove(requestId);
      unawaited(controller.close());
    }
  }

  void _acceptStderrChunk(List<int> chunk) {
    final remaining = stdioRpcMaxStderrBytes - stderrBytes;
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
    if (!usable && _expectedFrames.isEmpty && _expectedConversations.isEmpty) {
      return;
    }
    usable = false;
    _detachedConversations.clear();
    final expectedFrames = _expectedFrames.values.toList(growable: false);
    _expectedFrames.clear();
    for (final expectedFrame in expectedFrames) {
      if (!expectedFrame.isCompleted) {
        expectedFrame.complete(const StdioRpcFrame.failure());
      }
    }
    final controllers = _expectedConversations.values
        .map((expectation) => expectation.controller)
        .toList(growable: false);
    _expectedConversations.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) {
        controller.addError(const LicoClientRpcException('transport_failed'));
        unawaited(controller.close());
      }
    }
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
      // Teardown deliberately ignores and redacts process-specific details.
    }
    if (kill) {
      try {
        await process.exitCode.timeout(stdioRpcShutdownTimeout);
      } on Object {
        process.kill();
        try {
          await process.exitCode.timeout(stdioRpcShutdownTimeout);
        } on Object {
          // The process is detached from this client instance after this bound.
        }
      }
    }
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    _addFrameError();
  }
}
