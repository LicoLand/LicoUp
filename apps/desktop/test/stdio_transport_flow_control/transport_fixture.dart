import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Native sides for the stdio transport flow-control suite.
///
/// Two fixtures share the wire schema the product transport uses and contain no
/// product data, credential or real CLI binary:
///
/// * [SyntheticNativeProcess] plants frames directly on an in-process stream,
///   which makes the bulk backlog and the control lane exactly reproducible.
/// * [NativeChildFixture] starts an executable child that writes real frames on
///   a real stdout pipe, so pausing stdout stalls the producer itself.

/// One ordinary command reply for a parsed request frame.
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

/// One conversation event for [requestId].
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

/// The terminal frame that ends one conversation stream.
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

/// Real native child that emits a bulk conversation burst on stdout.
///
/// The child is an executable `/bin/sh` sidecar that writes the same
/// `licoup.stdio.v1` frames the native CLI writes and records every frame it
/// finished writing in [progressFile]. The transport under test frames those
/// real bytes, so the fixture exercises the real pipe: while the transport
/// holds its framed backlog and stops reading stdout, the child blocks on the
/// full pipe and [writtenFrames] stops advancing.
///
/// The payload is newline-dense text, written escaped by the child and decoded
/// to real newlines by the transport. Decoding it costs more per wire byte than
/// a real pipe delivers, which is the property a bounded framed backlog exists
/// for: without the bound, the bytes a paused producer can push into the client
/// grow with everything the producer writes.
///
/// With [holdForControl] the child returns to its stdin loop after
/// [framesBeforeControl] frames; the first control request it reads is
/// acknowledged and only then does it write the remaining frames and the
/// terminal. That places the control reply on the wire between bulk phases,
/// exactly where a native sidecar acknowledges cancel or steer while a turn
/// backlog is still streaming.
final class NativeChildFixture {
  NativeChildFixture._({
    required this.directory,
    required this.executable,
    required this.payloadFile,
    required this.progressFile,
    required this.heldFile,
    required this.completedFile,
    required this.payloadText,
    required this.framesBeforeControl,
    required this.burstFrames,
    required this.holdForControl,
  });

  static const String requestId = 'request-flow-control';
  static const String workflowId = 'workflow-flow-control';

  /// Decoded payload characters of one bulk frame. The frame's wire form is
  /// half again as large, and comfortably above
  /// `stdioRpcBulkDecodeThresholdBytes`.
  static const int defaultFillerBytes = 512 * 1024;

  static Future<NativeChildFixture> create({
    required Directory directory,
    int framesBeforeControl = 64,
    int burstFrames = 85,
    int fillerBytes = defaultFillerBytes,
    bool holdForControl = true,
  }) async {
    if (framesBeforeControl < 1 || burstFrames <= framesBeforeControl) {
      throw ArgumentError('the release phase must carry at least one frame');
    }
    if (fillerBytes.isOdd || fillerBytes < 2) {
      throw ArgumentError('the payload must hold whole one-character lines');
    }
    final executable = File('${directory.path}/licoup');
    await executable.writeAsString(_childScript);
    final chmod = await Process.run('chmod', ['+x', executable.path]);
    if (chmod.exitCode != 0) {
      throw StateError('fixture child could not be made executable');
    }
    // Whole lines only: a payload that ended mid-escape would leave the closing
    // quote of the JSON string escaped, which is a broken fixture frame rather
    // than a transport result.
    final units = fillerBytes ~/ 2;
    final payloadText = _repeat(_payloadUnit, units * _payloadUnit.length);
    final payloadFile = File('${directory.path}/bulk-payload-escaped');
    await payloadFile.writeAsString(
      _repeat(_escapedPayloadUnit, units * _escapedPayloadUnit.length),
    );
    return NativeChildFixture._(
      directory: directory,
      executable: executable,
      payloadFile: payloadFile,
      progressFile: File('${directory.path}/frames-written'),
      heldFile: File('${directory.path}/burst-held'),
      completedFile: File('${directory.path}/burst-complete'),
      payloadText: payloadText,
      framesBeforeControl: framesBeforeControl,
      burstFrames: burstFrames,
      holdForControl: holdForControl,
    );
  }

  final Directory directory;
  final File executable;
  final File payloadFile;
  final File progressFile;
  final File heldFile;
  final File completedFile;

  /// Decoded payload text of one bulk frame.
  final String payloadText;
  final int framesBeforeControl;
  final int burstFrames;
  final bool holdForControl;

  /// Bulk frames the child writes after its control acknowledgement.
  int get releaseFrames => burstFrames - framesBeforeControl;

  /// Sequence of the terminal frame, which follows every bulk frame.
  int get terminalSequence => burstFrames + 1;

  /// Exact payload characters of the whole burst, including the cursor prefix
  /// of every event.
  int get expectedPayloadChars {
    var total = burstFrames * payloadText.length;
    for (var cursor = 1; cursor <= burstFrames; cursor += 1) {
      total += '$cursor:'.length;
    }
    return total;
  }

  /// Wire bytes of one bulk frame: the escaped payload plus its envelope. One
  /// decoded line of two characters costs three wire bytes.
  int get frameWireBytes => (payloadText.length ~/ 2) * 3 + 1024;

  /// Starts one child bound to this fixture's progress and marker files.
  ///
  /// A marker is absent until the child creates it, so absence is real
  /// evidence rather than a truncated leftover.
  Future<Process> start() async {
    await progressFile.writeAsString('');
    for (final marker in [heldFile, completedFile]) {
      if (marker.existsSync()) {
        await marker.delete();
      }
    }
    return Process.start(
      executable.path,
      const ['rpc', 'conversation'],
      environment: {
        'LICO_FIXTURE_PAYLOAD': payloadFile.path,
        'LICO_FIXTURE_PROGRESS': progressFile.path,
        'LICO_FIXTURE_HELD': heldFile.path,
        'LICO_FIXTURE_COMPLETED': completedFile.path,
        'LICO_FIXTURE_BEFORE_CONTROL': '$framesBeforeControl',
        'LICO_FIXTURE_BURST': '$burstFrames',
        'LICO_FIXTURE_HOLD': holdForControl ? '1' : '0',
      },
    );
  }

  /// Cursors of the bulk frames the child finished writing, in write order.
  List<int> writtenFrames() {
    if (!progressFile.existsSync()) return const [];
    return progressFile
        .readAsLinesSync()
        .where((line) => line.isNotEmpty)
        .map(int.parse)
        .toList(growable: false);
  }

  /// Whether the child wrote every bulk frame and its terminal.
  bool get burstCompleted => completedFile.existsSync();

  /// Exact payload text of the bulk event for [cursor].
  String expectedFrameText(int cursor) => '$cursor:$payloadText';
}

/// Process context that starts the real fixture child for every session.
final class NativeChildProcessContext implements NativeCliProcessContext {
  NativeChildProcessContext(
    this.fixture, {
    this.requestTimeout = const Duration(seconds: 120),
  });

  final NativeChildFixture fixture;

  @override
  final Duration requestTimeout;

  final List<Process> processes = [];

  int get startCount => processes.length;

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => fixture.executable;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final process = await fixture.start();
    processes.add(process);
    return process;
  }
}

String _repeat(String unit, int length) {
  assert(length % unit.length == 0, 'fixture payload must hold whole units');
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(unit);
  }
  return buffer.toString();
}

/// One-character lines: the decoded payload is `l` followed by a newline.
const String _payloadUnit = 'l\n';

/// The same line as it appears inside a JSON string.
const String _escapedPayloadUnit = 'l\\n';

/// Executable native child. Every frame is written by the child process itself
/// on a real stdout pipe; the Dart transport frames those bytes.
///
/// `emit_bulk` writes one `agent.message.chunk` event whose payload text is
/// `<cursor>:` followed by the escaped payload file, then records the cursor in
/// `$LICO_FIXTURE_PROGRESS`. A write that blocks on a full pipe leaves that
/// cursor unrecorded, which is what makes producer backpressure observable, and
/// `$LICO_FIXTURE_COMPLETED` appears only after the whole burst reached stdout.
const String _childScript = r'''#!/bin/sh
emit_bulk() {
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":%s,"event":{"event":"agent.message.chunk","turnHandle":"turn-1","conversationId":"conversation-1","cursor":%s,"payload":{"text":"%s:' "$bulk_id" "$bulk_workflow" "$sequence" "$1" "$1"
  cat "$LICO_FIXTURE_PAYLOAD"
  printf '"}}}\n'
  printf '%s\n' "$1" >> "$LICO_FIXTURE_PROGRESS"
}
emit_burst() {
  cursor=$1
  while [ "$cursor" -le "$2" ]; do
    emit_bulk "$cursor"
    sequence=$((sequence + 1))
    cursor=$((cursor + 1))
  done
}
emit_terminal() {
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":%s,"ok":true,"result":{"ok":true}}\n' "$bulk_id" "$bulk_workflow" "$sequence"
}
emit_release() {
  emit_burst "$cursor" "$LICO_FIXTURE_BURST"
  cursor=$((LICO_FIXTURE_BURST + 1))
  emit_terminal
  : > "$LICO_FIXTURE_COMPLETED"
}
sequence=1
cursor=1
bulk_id=
bulk_workflow=
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      bulk_id=$request_id
      bulk_workflow=$workflow_id
      emit_burst 1 "$LICO_FIXTURE_BEFORE_CONTROL"
      : > "$LICO_FIXTURE_HELD"
      if [ "$LICO_FIXTURE_HOLD" = "1" ]; then
        :
      else
        emit_release
      fi
      ;;
    *'"method":"agent.conversation.cancel"'*|*'"method":"agent.conversation.steer"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"status":"accepted"}}\n' "$request_id" "$workflow_id"
      if [ "$LICO_FIXTURE_HOLD" = "1" ] && [ -n "$bulk_id" ] && [ "$cursor" -le "$LICO_FIXTURE_BURST" ]; then
        emit_release
      fi
      ;;
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
  esac
done
''';
