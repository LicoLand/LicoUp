import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/line_framer.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

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
  Completer<StdioRpcFrame>? _expectedFrame;
  StreamController<StdioRpcConversationFrame>? _expectedFrames;
  StdioRpcConversationDecoder? _conversationDecoder;
  var _closed = false;
  var usable = true;
  var stderrBytes = 0;
  var stderrTruncated = false;

  Future<StdioRpcFrame> expectFrame() {
    if (!_canExpectFrame) {
      throw const StdioRpcTransportFailure();
    }
    final completer = Completer<StdioRpcFrame>();
    _expectedFrame = completer;
    return completer.future;
  }

  Stream<StdioRpcConversationFrame> expectConversationFrames({
    required String requestId,
    required String workflowId,
  }) {
    if (!_canExpectFrame) {
      throw const StdioRpcTransportFailure();
    }
    final controller = StreamController<StdioRpcConversationFrame>();
    _expectedFrames = controller;
    _conversationDecoder = StdioRpcConversationDecoder(
      requestId: requestId,
      workflowId: workflowId,
    );
    return controller.stream;
  }

  bool get _canExpectFrame =>
      usable && !_closed && _expectedFrame == null && _expectedFrames == null;

  void completeExpectedFrames() {
    final controller = _expectedFrames;
    _clearExpectedConversation();
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  void abandonExpectedFrame() {
    final expectedFrame = _expectedFrame;
    _expectedFrame = null;
    if (expectedFrame != null && !expectedFrame.isCompleted) {
      expectedFrame.complete(const StdioRpcFrame.failure());
    }
    final controller = _expectedFrames;
    _clearExpectedConversation();
    if (controller != null && !controller.isClosed) {
      controller.addError(const LicoClientRpcException('transport_failed'));
      unawaited(controller.close());
    }
  }

  void _acceptStdoutChunk(List<int> chunk) {
    if (!usable || _closed) {
      return;
    }
    if (_expectedFrame == null && _expectedFrames == null) {
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
    final expectedFrame = _expectedFrame;
    if (expectedFrame != null) {
      _expectedFrame = null;
      expectedFrame.complete(StdioRpcFrame.data(bytes));
      return;
    }
    final controller = _expectedFrames;
    final decoder = _conversationDecoder;
    if (controller == null || decoder == null) {
      _addFrameError();
      return;
    }
    late StdioRpcConversationFrame frame;
    try {
      frame = decoder.decode(bytes);
    } on StdioRpcProtocolViolation {
      usable = false;
      _clearExpectedConversation();
      controller.addError(const LicoClientRpcException('invalid_response'));
      unawaited(controller.close());
      return;
    }
    controller.add(frame);
    if (frame is StdioRpcConversationTerminal) {
      _clearExpectedConversation();
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
    if (!usable && _expectedFrame == null && _expectedFrames == null) {
      return;
    }
    usable = false;
    final expectedFrame = _expectedFrame;
    _expectedFrame = null;
    if (expectedFrame != null && !expectedFrame.isCompleted) {
      expectedFrame.complete(const StdioRpcFrame.failure());
    }
    final controller = _expectedFrames;
    _clearExpectedConversation();
    if (controller != null && !controller.isClosed) {
      controller.addError(const LicoClientRpcException('transport_failed'));
      unawaited(controller.close());
    }
  }

  void _clearExpectedConversation() {
    _expectedFrames = null;
    _conversationDecoder = null;
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
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    _addFrameError();
  }
}
