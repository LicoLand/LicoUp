import 'dart:async';
import 'dart:collection';
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

final class StdioRpcFrameExpectation {
  const StdioRpcFrameExpectation({
    required this.completer,
    this.control = false,
  });

  final Completer<StdioRpcFrame> completer;

  /// Whether this request is a single-shot control command (cancel, steer,
  /// detach). Control replies decode and dispatch ahead of an unrelated bulk
  /// frame backlog; ordinary replies keep strict wire order.
  final bool control;
}

/// One framed stdout payload waiting for decode and dispatch.
///
/// Small frames decode inline as soon as they are framed. Frames at or above
/// [stdioRpcBulkDecodeThresholdBytes] decode on a helper isolate, one at a
/// time, so bulk history or catalog work never blocks the UI isolate.
final class _PendingFrame {
  _PendingFrame({required this.bytes});

  final Uint8List bytes;

  Map<String, dynamic>? envelope;
  var decodeStarted = false;
  var decoded = false;
  var failed = false;
  var control = false;
}

/// Decodes one bulk frame on a helper isolate.
///
/// The bytes are bound by this non-async frame on purpose: a closure created
/// inside an async body would capture that body's async state (`Completer`),
/// which `SendPort.send` rejects as unsendable.
Future<Map<String, dynamic>?> _runIsolateDecode(Uint8List bytes) =>
    Isolate.run<Map<String, dynamic>?>(() => _decodeEnvelopeEntry(bytes));

Map<String, dynamic>? _decodeEnvelopeEntry(Uint8List bytes) {
  try {
    return decodeStdioRpcEnvelope(bytes);
  } on StdioRpcProtocolViolation {
    return null;
  }
}

/// Multiplexed native stdio session.
///
/// Accepted frames are decoded by a bounded pipeline and dispatched in wire
/// order, with one deliberate exception: a single-shot control request
/// (cancel/steer/detach) dispatches as soon as its own small frame decodes, so
/// a bulk decode backlog cannot delay control. Frames for one request id are
/// always dispatched in wire order, which is what the generated stream decoder
/// requires. Framed-but-undispatched bytes are bounded: stdout pauses at
/// [stdioRpcMaxDecodeBacklogBytes] and resumes below
/// [stdioRpcResumeDecodeBacklogBytes].
class StdioRpcSession {
  StdioRpcSession(this.process) {
    _stdoutSubscription = process.stdout.listen(
      _acceptStdoutChunk,
      onError: (Object _, StackTrace _) => _addFrameError(),
      onDone: _onStdoutDone,
      cancelOnError: false,
    );
    _stderrSubscription = process.stderr.listen(
      _acceptStderrChunk,
      onError: (Object _, StackTrace _) {
        stderrTruncated = true;
      },
      cancelOnError: false,
    );
  }

  final Process process;
  final StdioRpcLineFramer _framer = StdioRpcLineFramer(
    maxFrameBytes: stdioRpcMaxFrameBytes,
  );
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  final Map<String, StdioRpcFrameExpectation> _expectedFrames = {};
  final Map<String, StdioRpcConversationExpectation> _expectedConversations =
      {};
  final Map<String, StdioRpcConversationDecoder> _detachedConversations = {};

  /// Framed frames in arrival order, each decoded and dispatched once ready.
  final ListQueue<_PendingFrame> _pendingFrames = ListQueue<_PendingFrame>();
  var _pendingDecodeBytes = 0;
  var _maxObservedDecodeBacklogBytes = 0;
  var _bulkDecodeRunning = false;
  Timer? _bulkDecodeTimer;
  var _stdoutPaused = false;
  Completer<void>? _decodeIdle;
  var _closed = false;
  var usable = true;
  var stderrBytes = 0;
  var stderrTruncated = false;

  /// Framed bytes that are decoded but not yet dispatched.
  int get pendingDecodeBytes => _pendingDecodeBytes;

  /// Highest [pendingDecodeBytes] this session observed. Evidence that the
  /// decode backlog stays inside its declared bound.
  int get maxObservedDecodeBacklogBytes => _maxObservedDecodeBacklogBytes;

  /// Framed frames that are decoded but not yet dispatched.
  int get pendingDecodeFrames => _pendingFrames.length;

  /// Whether stdout is currently paused by decode backpressure.
  bool get decodeBackpressureApplied => _stdoutPaused;

  Future<StdioRpcFrame> expectFrame({
    required String requestId,
    bool control = false,
  }) {
    if (!_canExpectRequest(requestId)) {
      throw const StdioRpcTransportFailure();
    }
    final completer = Completer<StdioRpcFrame>();
    _expectedFrames[requestId] = StdioRpcFrameExpectation(
      completer: completer,
      control: control,
    );
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
    final expectedFrame = _expectedFrames.remove(requestId)?.completer;
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
    if (!usable || _closed) {
      return;
    }
    for (final bytes in frames) {
      _pendingFrames.add(_PendingFrame(bytes: bytes));
      _pendingDecodeBytes += bytes.length;
      if (_pendingDecodeBytes > _maxObservedDecodeBacklogBytes) {
        _maxObservedDecodeBacklogBytes = _pendingDecodeBytes;
      }
    }
    if (frames.isEmpty) return;
    _pumpDecodePipeline();
  }

  /// Starts every decode that can start, dispatches everything that is ready,
  /// then re-applies stdout backpressure. Runs synchronously; helper-isolate
  /// decodes resume it from their completion callback.
  void _pumpDecodePipeline() {
    _startDecodes();
    _dispatchFrames();
    _applyDecodeBackpressure();
  }

  void _startDecodes() {
    // Small frames decode inline and in arrival order: a control reply is
    // decodable while an earlier bulk frame is still off the UI isolate.
    for (final pending in _pendingFrames) {
      if (pending.decodeStarted) continue;
      if (pending.bytes.length >= stdioRpcBulkDecodeThresholdBytes) continue;
      pending.decodeStarted = true;
      _decodeInline(pending);
    }
    if (_bulkDecodeRunning) return;
    for (final pending in _pendingFrames) {
      if (pending.decodeStarted) continue;
      pending.decodeStarted = true;
      _bulkDecodeRunning = true;
      // Bulk decode setup starts on the next event-loop turn, so the turn that
      // accepted the bytes is never extended by helper-isolate startup.
      _bulkDecodeTimer = Timer(Duration.zero, () {
        _bulkDecodeTimer = null;
        if (!_pendingFrames.contains(pending)) {
          _bulkDecodeRunning = false;
          _notifyDecodeIdle();
          return;
        }
        _decodeOffIsolate(pending);
      });
      return;
    }
  }

  void _decodeInline(_PendingFrame pending) {
    try {
      pending.envelope = decodeStdioRpcEnvelope(pending.bytes);
    } on StdioRpcProtocolViolation {
      pending.failed = true;
    }
    pending.decoded = true;
    _classifyFrame(pending);
  }

  void _decodeOffIsolate(_PendingFrame pending) {
    unawaited(() async {
      Map<String, dynamic>? envelope;
      var failed = false;
      try {
        // Large catalog/history replies leave the UI isolate. The wire is no
        // longer held while this runs; ordering is preserved by the dispatch
        // queue instead.
        envelope = await _runIsolateDecode(pending.bytes);
      } on Object {
        failed = true;
      }
      pending.envelope = envelope;
      pending.failed = failed || envelope == null;
      pending.decoded = true;
      _classifyFrame(pending);
      _bulkDecodeRunning = false;
      _pumpDecodePipeline();
    }());
  }

  void _classifyFrame(_PendingFrame pending) {
    final envelope = pending.envelope;
    if (envelope == null) {
      pending.failed = true;
      return;
    }
    final requestId = envelope['id'];
    if (requestId is! String || requestId.isEmpty) {
      pending.failed = true;
      return;
    }
    pending.control = _expectedFrames[requestId]?.control ?? false;
  }

  void _dispatchFrames() {
    while (_pendingFrames.isNotEmpty) {
      final first = _pendingFrames.first;
      if (!first.decoded) {
        _dispatchControlFrames();
        return;
      }
      _pendingFrames.removeFirst();
      _pendingDecodeBytes -= first.bytes.length;
      _dispatchFrame(first);
      if (!usable || _closed) {
        _abandonPendingFrames();
        return;
      }
    }
    _notifyDecodeIdle();
  }

  void _dispatchControlFrames() {
    for (final pending in _pendingFrames.toList(growable: false)) {
      if (!pending.decoded || !pending.control) continue;
      _pendingFrames.remove(pending);
      _pendingDecodeBytes -= pending.bytes.length;
      _dispatchFrame(pending);
      if (!usable || _closed) {
        _abandonPendingFrames();
        return;
      }
    }
    _notifyDecodeIdle();
  }

  void _dispatchFrame(_PendingFrame pending) {
    final envelope = pending.envelope;
    if (pending.failed || envelope == null) {
      _addFrameError();
      return;
    }
    _acceptEnvelope(envelope);
  }

  void _abandonPendingFrames() {
    _pendingFrames.clear();
    _pendingDecodeBytes = 0;
    final timer = _bulkDecodeTimer;
    if (timer != null) {
      _bulkDecodeTimer = null;
      timer.cancel();
      _bulkDecodeRunning = false;
    }
    _notifyDecodeIdle();
  }

  Future<void> _whenDecodeIdle() {
    if (_pendingFrames.isEmpty && !_bulkDecodeRunning) {
      return Future<void>.value();
    }
    return (_decodeIdle ??= Completer<void>()).future;
  }

  void _notifyDecodeIdle() {
    if (_pendingFrames.isNotEmpty || _bulkDecodeRunning) return;
    final idle = _decodeIdle;
    _decodeIdle = null;
    idle?.complete();
  }

  void _applyDecodeBackpressure() {
    if (_closed || !usable) return;
    if (!_stdoutPaused &&
        _pendingDecodeBytes >= stdioRpcMaxDecodeBacklogBytes) {
      _stdoutPaused = true;
      _stdoutSubscription.pause();
      return;
    }
    if (_stdoutPaused &&
        _pendingDecodeBytes <= stdioRpcResumeDecodeBacklogBytes) {
      _stdoutPaused = false;
      _stdoutSubscription.resume();
    }
  }

  void _onStdoutDone() {
    // EOF is delivered after the framer accepted every stdout byte. Frames
    // still decoding dispatch before the transport reports the failure.
    if (_pendingFrames.isEmpty && !_bulkDecodeRunning) {
      _addFrameError();
      return;
    }
    unawaited(_whenDecodeIdle().then((_) => _addFrameError()));
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
    final expectedFrame = _expectedFrames.remove(requestId)?.completer;
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
      if (!expectedFrame.completer.isCompleted) {
        expectedFrame.completer.complete(const StdioRpcFrame.failure());
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
    _abandonPendingFrames();
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
