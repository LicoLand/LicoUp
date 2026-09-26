import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Synthetic native side for the V7-F4 transport fixtures.
///
/// Every frame below is generated in-process from the same wire schema the
/// product transport uses; no product data, credential or real CLI binary is
/// involved. The fixtures plant decode backlogs by writing bytes directly on
/// [SyntheticNativeProcess.sendFrameBytes].
String stdioRpcCommandReply({
  required Map<String, dynamic> request,
  required Map<String, dynamic> result,
}) => jsonEncode({
  'protocol': 'licoup.stdio.v1',
  'id': request['id'],
  'workflowId': request['workflowId'],
  'ok': true,
  'result': result,
});

String stdioRpcConversationEvent({
  required String requestId,
  required String workflowId,
  required int sequence,
  required int cursor,
  required String turnHandle,
  required String conversationId,
  String filler = '',
}) => jsonEncode({
  'protocol': 'licoup.stdio.v1',
  'id': requestId,
  'workflowId': workflowId,
  'kind': 'event',
  'sequence': sequence,
  'event': {
    'event': 'agent.message.chunk',
    'turnHandle': turnHandle,
    'conversationId': conversationId,
    'cursor': cursor,
    'payload': {'text': filler.isEmpty ? 'chunk-$cursor' : filler},
  },
});

String stdioRpcConversationTerminal({
  required String requestId,
  required String workflowId,
  required int sequence,
}) => jsonEncode({
  'protocol': 'licoup.stdio.v1',
  'id': requestId,
  'workflowId': workflowId,
  'kind': 'terminal',
  'sequence': sequence,
  'ok': true,
  'result': {'ok': true, 'event': 'done'},
});

/// One parsed client request as seen by the synthetic native side.
final class SyntheticNativeRequest {
  SyntheticNativeRequest(this.process, this.frame);

  final SyntheticNativeProcess process;
  final Map<String, dynamic> frame;

  String get id => frame['id'] as String;
  String get workflowId => frame['workflowId'] as String;
  String get method => (frame['method'] ?? '').toString();
  List<String> get args => (frame['args'] as List?)?.cast<String>() ?? const [];
  Map<String, dynamic> get params =>
      Map<String, dynamic>.from(frame['params'] as Map? ?? const {});

  /// Answers this request with one ordinary (non-control) command reply.
  void reply(Map<String, dynamic> result) {
    process.sendFrame(stdioRpcCommandReply(request: frame, result: result));
  }

  void replyError() {
    process.sendFrame(
      jsonEncode({
        'protocol': 'licoup.stdio.v1',
        'id': frame['id'],
        'workflowId': frame['workflowId'],
        'ok': false,
        'error': {
          'code': 'command_failed',
          'stage': 'stdio_rpc/response',
          'component': 'native_cli',
          'retryable': false,
          'recovery': 'retry_or_review_request',
        },
      }),
    );
  }
}

/// In-process stand-in for one native CLI sidecar process.
final class SyntheticNativeProcess implements Process {
  SyntheticNativeProcess(this._onRequest) {
    stdin = IOSink(_input.sink);
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          final frame = jsonDecode(line) as Map<String, dynamic>;
          final request = SyntheticNativeRequest(this, frame);
          if (frame['method'] == 'shutdown') {
            request.reply(const {});
            unawaited(_close());
            _exited.complete(0);
            return;
          }
          _onRequest(request);
        });
  }

  final void Function(SyntheticNativeRequest request) _onRequest;
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final _exited = Completer<int>();
  var killed = false;

  /// Frames written by the client, in arrival order.
  final List<Map<String, dynamic>> received = [];

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _output.stream;

  @override
  Stream<List<int>> get stderr => _errors.stream;

  @override
  Future<int> get exitCode => _exited.future;

  @override
  int get pid => 1;

  void sendFrame(String frame) => sendFrameBytes(utf8.encode('$frame\n'));

  void sendFrameBytes(List<int> bytes) => _output.add(bytes);

  Future<void> _close() async {
    await _output.close();
    await _errors.close();
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exited.isCompleted) {
      unawaited(_close());
      _exited.complete(-1);
    }
    return true;
  }
}

/// Process context that hands every transport session its own synthetic peer.
final class SyntheticProcessContext implements NativeCliProcessContext {
  SyntheticProcessContext(
    this.onRequest, {
    this.requestTimeout = const Duration(seconds: 30),
  });

  final void Function(SyntheticNativeRequest request) onRequest;

  @override
  final Duration requestTimeout;

  final List<SyntheticNativeProcess> processes = [];

  int get startCount => processes.length;

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => null;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    late final SyntheticNativeProcess process;
    process = SyntheticNativeProcess((request) {
      process.received.add(request.frame);
      onRequest(request);
    });
    processes.add(process);
    return process;
  }
}
