import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/line_framer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_expectation.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

class StdioRpcFrame {
  const StdioRpcFrame.data(this.bytes);
  const StdioRpcFrame.failure() : bytes = null;

  final Uint8List? bytes;
}

class StdioRpcTransportFailure implements Exception {
  const StdioRpcTransportFailure();
}

class StdioRpcSession {
  StdioRpcSession(this.process) {
    _stdoutSubscription = process.stdout.listen(
      _acceptStdoutChunk,
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
    unawaited(
      process.exitCode.then<void>(
        (_) => _addFrameError(),
        onError: (Object _, StackTrace _) => _addFrameError(),
      ),
    );
  }

  final Process process;
  final StdioRpcLineFramer _framer = StdioRpcLineFramer(
    maxFrameBytes: stdioRpcMaxFrameBytes,
  );
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  final Map<String, Completer<StdioRpcFrame>> _expectedFrames = {};
  final Map<String, StdioRpcConversationExpectation> _expectedConversations =
      {};
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
  }) {
    if (!_canExpectRequest(requestId)) {
      throw const StdioRpcTransportFailure();
    }
    final controller = StreamController<StdioRpcConversationFrame>();
    _expectedConversations[requestId] = StdioRpcConversationExpectation(
      controller: controller,
      decoder: StdioRpcConversationDecoder(
        requestId: requestId,
        workflowId: workflowId,
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

  void _acceptStdoutChunk(List<int> chunk) {
    if (!usable || _closed) {
      return;
    }
    if (_expectedFrames.isEmpty && _expectedConversations.isEmpty) {
      _addFrameError();
      return;
    }
    _framer.accept(
      chunk,
      onFrame: _acceptFrame,
      onOversizedFrame: _addFrameError,
    );
  }

  void _acceptFrame(Uint8List bytes) {
    if (!usable || _closed) {
      return;
    }
    final requestId = stdioRpcEnvelopeRequestId(bytes);
    if (requestId == null) {
      _addFrameError();
      return;
    }
    final expectedFrame = _expectedFrames.remove(requestId);
    if (expectedFrame != null) {
      expectedFrame.complete(StdioRpcFrame.data(bytes));
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
      frame = expectation.decoder.decode(bytes);
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
