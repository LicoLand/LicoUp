import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_session.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_conversation_port.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

import 'transport_harness.dart';

// Shared synthetic host and assembly for the two shell control-path proofs.
//
// The substitute is the native process only. `SyntheticProcessContext` stands in
// for the CLI sidecar while the real composition, the real typed intent routing,
// the real conversation port encoding, the real multiplexed transport and its
// reserved control dispatch all stay in the path. Every frame below is built
// from the same `licoup.stdio.v1` schema the product transport uses; no product
// data, credential or real agent conversation is involved.
//
// The fixture store is this Task's declared isolated directory under
// `build/test-artifacts/control-under-output-flood`, so a failing run leaves its
// state snapshot there and nothing outside.
const String conversationFloodFixtureRoot =
    'build/test-artifacts/control-under-output-flood';

/// Fixture directory for one Node of this Task. Isolated per Node.
Directory conversationFloodFixtureDirectory(String node) =>
    Directory('$conversationFloodFixtureRoot/$node');

/// Writes the fixture and state snapshot of one proof run.
void writeFloodDiagnostics(String node, String body) {
  final directory = conversationFloodFixtureDirectory(node);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  File('${directory.path}/diagnostics.txt').writeAsStringSync(body);
}

/// Writes the evidence summary of a proof run that reached its end.
void writeFloodEvidence(String node, String body) {
  final directory = conversationFloodFixtureDirectory(node);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  File('${directory.path}/evidence.txt').writeAsStringSync(body);
}

/// Waits until [predicate] holds, yielding to the event loop between probes.
Future<void> waitForCondition(
  bool Function() predicate, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// One typed conversation operation observed at the port boundary, with the
/// bulk position it started and settled at.
final class RecordedConversationOperation {
  RecordedConversationOperation({
    required this.operation,
    required this.params,
    required this.bulkEventsAtStart,
  });

  final String operation;
  final Map<String, dynamic> params;
  final int bulkEventsAtStart;

  /// Bulk chunk events the send stream had delivered when this operation
  /// settled. Null while the operation is still outstanding.
  int? bulkEventsAtSettlement;
  int? settledAtMs;
  Map<String, dynamic>? terminal;
  Object? error;
  String? end;

  bool get settled => bulkEventsAtSettlement != null;

  @override
  String toString() =>
      'RecordedConversationOperation($operation, params=$params, '
      'start=$bulkEventsAtStart, settled=$bulkEventsAtSettlement, '
      'atMs=$settledAtMs, end=$end, error=$error)';
}

/// Transparent instrument in front of the real transport.
///
/// It delegates every call to the product client, so framing, lane choice, the
/// bounded decode pipeline and the reserved control dispatch stay owned by
/// production code, and records what the transport yielded or threw.
final class RecordingTransport implements NativeStdioRpcTransport {
  RecordingTransport(this._inner);

  final NativeStdioRpcTransport _inner;
  final Stopwatch clock = Stopwatch()..start();
  final List<String> deliveries = [];

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      _inner.execute(arguments);

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) => _inner.executeStructured(method, params);

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) async* {
    final operation = (request['_rpcOperation'] ?? 'send').toString();
    var yielded = 0;
    var completed = false;
    try {
      await for (final event in _inner.streamConversation(request)) {
        yielded += 1;
        if (yielded == 1) {
          deliveries.add(
            '$operation:firstEvent@${clock.elapsedMilliseconds}ms',
          );
        }
        yield event;
      }
      completed = true;
      deliveries.add(
        '$operation:yielded=$yielded:done@${clock.elapsedMilliseconds}ms',
      );
    } on Object catch (error) {
      deliveries.add(
        '$operation:yielded=$yielded:error=$error@${clock.elapsedMilliseconds}ms',
      );
      rethrow;
    } finally {
      if (!completed) {
        deliveries.add('$operation:cancelled@${clock.elapsedMilliseconds}ms');
      }
    }
  }

  @override
  Future<void> dispose() => _inner.dispose();
}

/// Transparent instrument in front of the real [ConversationNativePort].
///
/// It delegates every call to the product port, so port encoding, lane choice
/// and control classification stay owned by production code. Its only job is to
/// record which typed operation the shell requested, whether it settled, and how
/// much of the bulk output stream had been delivered when it did.
final class RecordingConversationPort
    implements ConversationNativePort, ConversationExecutionNativePort {
  RecordingConversationPort(this._inner, this.clock);

  final ConversationNativePort _inner;
  final Stopwatch clock;
  final List<RecordedConversationOperation> operations = [];

  /// `agent.message.chunk` events the send stream has delivered so far.
  int bulkEventsObserved = 0;

  Iterable<RecordedConversationOperation> named(String operation) =>
      operations.where((entry) => entry.operation == operation);

  RecordedConversationOperation _begin(
    String operation,
    Map<String, dynamic> params,
  ) {
    final entry = RecordedConversationOperation(
      operation: operation,
      params: Map<String, dynamic>.unmodifiable(params),
      bulkEventsAtStart: bulkEventsObserved,
    );
    operations.add(entry);
    return entry;
  }

  void _settle(RecordedConversationOperation entry, Object? error) {
    entry.error = error;
    entry.bulkEventsAtSettlement = bulkEventsObserved;
    entry.settledAtMs = clock.elapsedMilliseconds;
  }

  Future<Map<String, dynamic>> _track(
    RecordedConversationOperation entry,
    Future<Map<String, dynamic>> pending,
  ) async {
    try {
      final result = await pending;
      _settle(entry, null);
      return result;
    } on Object catch (error) {
      _settle(entry, error);
      rethrow;
    }
  }

  Stream<Map<String, dynamic>> _trackStream(
    RecordedConversationOperation entry,
    Stream<Map<String, dynamic>> stream,
  ) async* {
    var completed = false;
    try {
      await for (final event in stream) {
        if (event['event'] == 'agent.message.chunk') {
          bulkEventsObserved += 1;
        }
        if (event['event'] == 'done' || event.containsKey('ok')) {
          entry.terminal = Map<String, dynamic>.unmodifiable(event);
        }
        yield event;
      }
      completed = true;
    } on Object catch (error) {
      _settle(entry, error);
      rethrow;
    } finally {
      entry.end = completed ? 'completed' : 'cancelled';
      entry.bulkEventsAtSettlement ??= bulkEventsObserved;
      entry.settledAtMs ??= clock.elapsedMilliseconds;
    }
  }

  @override
  Future<Map<String, dynamic>> open(
    AgentConversationSessionScope session, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _track(
    _begin('open', {'agent': session.agentId, 'sessionId': session.sessionId}),
    _inner.open(session, bind: bind),
  );

  @override
  Stream<Map<String, dynamic>> send(
    AgentConversationSessionScope session, {
    required String text,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _trackStream(
    _begin('send', {'agent': session.agentId, 'text': text}),
    _inner.send(session, text: text, attachments: attachments, bind: bind),
  );

  @override
  Future<Map<String, dynamic>> active({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) => _track(
    _begin('active', {'agent': agentId, 'conversationId': conversationId}),
    _inner.active(
      agentId: agentId,
      sessionId: sessionId,
      conversationId: conversationId,
      waitForChange: waitForChange,
    ),
  );

  @override
  Stream<Map<String, dynamic>> attach(
    PersistentConversationTurnScope turn, {
    int afterCursor = 0,
  }) => _trackStream(
    _begin('attach', {
      'turnHandle': turn.turnHandle,
      'conversationId': turn.conversationId,
    }),
    _inner.attach(turn, afterCursor: afterCursor),
  );

  @override
  Future<Map<String, dynamic>> steer(
    AgentConversationTurnScope turn, {
    required String text,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _track(
    _begin('steer', {..._turnFields(turn), 'text': text, ..._bindFields(bind)}),
    _inner.steer(turn, text: text, bind: bind),
  );

  @override
  Future<Map<String, dynamic>> cancel(AgentConversationTurnScope turn) =>
      _track(_begin('cancel', _turnFields(turn)), _inner.cancel(turn));

  @override
  Future<Map<String, dynamic>> cleanup(AgentConversationSessionScope session) =>
      _track(
        _begin('cleanup', {'agent': session.agentId}),
        _inner.cleanup(session),
      );

  @override
  Future<Map<String, dynamic>> capabilities(
    String agentId, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _track(
    _begin('capabilities', {'agent': agentId}),
    _inner.capabilities(agentId, bind: bind),
  );

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) => _track(
    _begin('clientConversationExecute', {'action': command.action}),
    _inner.executeClientConversation(command),
  );

  @override
  Stream<Map<String, dynamic>> execution(
    ConversationExecutionReference reference, {
    int afterCursor = 0,
  }) => _trackStream(
    _begin('execution', {
      'conversationId': reference.conversationId,
      'membershipId': reference.membershipId,
      'turnHandle': reference.turnHandle,
    }),
    (_inner as ConversationExecutionNativePort).execution(
      reference,
      afterCursor: afterCursor,
    ),
  );
}

Map<String, dynamic> _turnFields(AgentConversationTurnScope turn) =>
    switch (turn) {
      AgentSessionTurnScope() => {
        'agent': turn.session.agentId,
        'sessionId': turn.session.sessionId,
        'turnId': turn.turnId,
      },
      PersistentConversationTurnScope() => {
        'turnHandle': turn.turnHandle,
        'conversationId': turn.conversationId,
      },
    };

Map<String, dynamic> _bindFields(AgentDispatchBind bind) => {
  if (bind.allowedTools.isNotEmpty)
    'allowedTools': List<String>.unmodifiable(bind.allowedTools),
};

/// Synthetic native host for one flooded conversation turn.
///
/// A `send` publishes the turn identity and the permission request, writes the
/// phase-A bulk frames, then holds both the rest of the burst and the terminal
/// until the test releases them. That makes "the burst is still being delivered"
/// a structural property of the fixture instead of a timing guess.
///
/// The turn identity on the send stream is the session/turn scope
/// (`sessionId` + `turnId`), which is the typed scope a local non-persistent turn
/// uses. The execution observation keeps its own persistent reference.
final class ConversationFloodHost {
  ConversationFloodHost({
    this.bulkFrames = 8,
    this.bulkFillerBytes = 300 * 1024,
    this.releasedBulkFrames = 2,
    this.executionRecordsPerObservation = 3,
    this.sessionId = 'session-flood',
    this.turnId = 'turn-flood',
    this.turnHandle = 'handle-flood',
    this.conversationId = 'conversation-flood',
    this.membershipId = 'membership-flood',
    this.approvalTool = 'Bash',
  });

  /// Phase-A bulk frames written as soon as the turn starts.
  final int bulkFrames;

  /// Filler bytes per bulk frame. Every frame stays above
  /// `stdioRpcBulkDecodeThresholdBytes` so it decodes off the UI isolate and
  /// forms the decode backlog the control lane has to overtake.
  final int bulkFillerBytes;

  /// Phase-B bulk frames withheld until the test releases the turn.
  final int releasedBulkFrames;
  final int executionRecordsPerObservation;
  final String sessionId;
  final String turnId;
  final String turnHandle;
  final String conversationId;
  final String membershipId;
  final String approvalTool;

  late final SyntheticProcessContext processContext = SyntheticProcessContext(
    handleRequest,
  );

  /// Frames the client wrote, in arrival order: the typed operations observed at
  /// the synthetic process seam.
  final List<Map<String, dynamic>> seamFrames = [];

  /// Phase-A bulk frames this host has written for the current turn.
  int bulkFramesWritten = 0;

  /// Phase-B bulk frames this host has released for the current turn.
  int releasedFramesWritten = 0;

  /// Bulk frames the fixture delivers for one turn.
  int get totalBulkFrames => bulkFrames + releasedBulkFrames;

  final List<String> steerTexts = [];
  final List<String> cancelRequests = [];
  final List<Map<String, dynamic>> executionRequests = [];
  final List<Map<String, dynamic>> detachRequests = [];

  /// Fixture defects observed while answering the client.
  final List<String> hostErrors = [];

  SyntheticNativeRequest? _sendRequest;
  int _sendSequence = 0;
  int _sendCursor = 0;
  bool _terminalWritten = false;

  final Map<String, int> _observationSequence = {};
  final Map<String, int> _observationCursor = {};
  final List<String> _liveObservations = [];

  bool get terminalWritten => _terminalWritten;

  List<String> get seamMethods => [
    for (final frame in seamFrames) (frame['method'] ?? '').toString(),
  ];

  Iterable<Map<String, dynamic>> framesFor(String method) =>
      seamFrames.where((frame) => (frame['method'] ?? '').toString() == method);

  int get cancelFrameCount => framesFor('agent.conversation.cancel').length;

  void handleRequest(SyntheticNativeRequest request) {
    seamFrames.add(request.frame);
    try {
      _handle(request);
    } on Object catch (error) {
      // A synthetic host that cannot answer is a fixture defect, not a product
      // result: keep the reason in the diagnostics instead of losing the test to
      // an unhandled zone error.
      hostErrors.add('$error');
    }
  }

  void _handle(SyntheticNativeRequest request) {
    switch (request.method) {
      case 'agent.conversation.send':
        _startTurn(request);
      case 'agent.conversation.steer':
        steerTexts.add((request.params['text'] ?? '').toString());
        request.reply({
          'ok': true,
          'status': 'steered',
          'turnHandle': turnHandle,
          'conversationId': conversationId,
        });
      case 'agent.conversation.cancel':
        cancelRequests.add(
          '${request.params['turnHandle'] ?? request.params['turnId']}',
        );
        request.reply(const {'ok': true, 'status': 'cancel_requested'});
      case 'agent.conversation.execution':
        _openExecutionObservation(request);
      case 'agent.conversation.execution.detach':
        _detachExecutionObservation(request);
      case 'agent.conversation.active':
        request.reply(const {'ok': true, 'turns': <Map<String, dynamic>>[]});
      default:
        request.reply(const {'ok': true});
    }
  }

  void _startTurn(SyntheticNativeRequest request) {
    _sendRequest = request;
    _sendSequence = 0;
    _sendCursor = 0;
    _terminalWritten = false;
    bulkFramesWritten = 0;
    releasedFramesWritten = 0;
    // The small identity frames dispatch inline ahead of the bulk decode
    // backlog; the permission request seeds the approval state the retry intent
    // consumes. `permission.denied` with a `toolName` is the event that arms
    // `pendingPermissionRetryTool`; `agent.approval.needed` only projects the
    // remote approval inbox and leaves that state empty.
    _writeTurnEvent('agent.turn.accepted', const {'status': 'accepted'});
    _writeTurnEvent('permission.denied', {
      'toolName': approvalTool,
      'text': 'permission denied by the native policy',
    });
    _writeBulkFrames(bulkFrames);
    bulkFramesWritten = bulkFrames;
  }

  void _writeBulkFrames(int count) {
    for (var index = 0; index < count; index += 1) {
      final cursor = _sendCursor + 1;
      _writeTurnEvent('agent.message.chunk', {
        'text': 'chunk-$cursor:${_filler(bulkFillerBytes)}',
        'messageUnit': 'answer',
      });
    }
  }

  void _writeTurnEvent(String eventName, Map<String, dynamic> payload) {
    final request = _sendRequest;
    if (request == null) {
      throw StateError('no active turn');
    }
    _sendSequence += 1;
    _sendCursor += 1;
    request.process.sendFrame(
      jsonEncode({
        'protocol': 'licoup.stdio.v1',
        'id': request.id,
        'workflowId': request.workflowId,
        'kind': 'event',
        'sequence': _sendSequence,
        'event': {
          'event': eventName,
          'sessionId': sessionId,
          'turnId': turnId,
          'membershipId': membershipId,
          'cursor': _sendCursor,
          'payload': payload,
        },
      }),
    );
  }

  /// Delivers the withheld remainder of the burst and the terminal settlement.
  ///
  /// The turn therefore stays open, and its bulk stream stays outstanding, until
  /// the test explicitly releases it.
  void releaseTurn({bool ok = true}) {
    if (_sendRequest == null || _terminalWritten) return;
    _writeBulkFrames(releasedBulkFrames);
    releasedFramesWritten = releasedBulkFrames;
    _terminalWritten = true;
    final request = _sendRequest!;
    _sendSequence += 1;
    request.process.sendFrame(
      jsonEncode({
        'protocol': 'licoup.stdio.v1',
        'id': request.id,
        'workflowId': request.workflowId,
        'kind': 'terminal',
        'sequence': _sendSequence,
        'ok': ok,
        'result': {
          'ok': ok,
          'nativeSessionId': sessionId,
          'turnId': turnId,
          'turnStatus': ok ? 'completed' : 'failed',
          'terminalTransition': {'kind': ok ? 'succeeded' : 'failed'},
          'text': 'flood turn settled',
        },
      }),
    );
  }

  void _openExecutionObservation(SyntheticNativeRequest request) {
    executionRequests.add(request.params);
    final id = request.id;
    _observationSequence[id] = 0;
    _observationCursor[id] = 0;
    _liveObservations.add(id);
    _writeExecutionEvent(id, 'agent.execution.ready', const {
      'status': 'running',
      'observationAvailable': true,
      'terminalPayloadAvailable': false,
    });
    for (var index = 0; index < executionRecordsPerObservation; index += 1) {
      _writeExecutionRecord(id);
    }
  }

  void _writeExecutionRecord(String observationId) {
    final cursor = _observationCursor[observationId]! + 1;
    _observationCursor[observationId] = cursor;
    _writeExecutionEvent(observationId, 'agent.execution.record', const {}, {
      'partIndex': 0,
      'partCount': 1,
      'record': {
        'id': 'record-$observationId-$cursor',
        'cursor': cursor,
        'kind': 'runtime',
        'timestamp': 1234567890000,
        'rawText': 'execution record $cursor',
      },
    });
  }

  void _writeExecutionEvent(
    String observationId,
    String eventName,
    Map<String, dynamic> payload, [
    Map<String, dynamic> extra = const {},
  ]) {
    final request = _sendRequest;
    if (request == null) {
      throw StateError('no active turn');
    }
    final sequence = (_observationSequence[observationId] ?? 0) + 1;
    _observationSequence[observationId] = sequence;
    request.process.sendFrame(
      jsonEncode({
        'protocol': 'licoup.stdio.v1',
        'id': observationId,
        'workflowId': request.workflowId,
        'kind': 'event',
        'sequence': sequence,
        'event': {
          'event': eventName,
          'turnHandle': turnHandle,
          'conversationId': conversationId,
          'membershipId': membershipId,
          'cursor': _observationCursor[observationId] ?? 0,
          ...extra,
          ...payload,
        },
      }),
    );
  }

  /// Publishes one more execution record to every live observation.
  ///
  /// Records written here reach the native peer after a view was closed; whether
  /// the closed view observes them is exactly what the detach proof asserts.
  void pushExecutionRecords(int count) {
    for (final observationId in [..._liveObservations]) {
      for (var index = 0; index < count; index += 1) {
        _writeExecutionRecord(observationId);
      }
    }
  }

  void _detachExecutionObservation(SyntheticNativeRequest request) {
    detachRequests.add(request.params);
    final observationId = (request.params['requestId'] ?? '').toString();
    // The host acknowledges the detach, then settles that observation's own
    // stream: observation ends, the turn itself is untouched.
    request.reply(const {'detached': true});
    if (observationId.isEmpty) return;
    _liveObservations.remove(observationId);
    _writeExecutionRecord(observationId);
    _writeExecutionEvent(observationId, 'agent.execution.ready', const {
      'status': 'running',
      'observationAvailable': false,
      'terminalPayloadAvailable': false,
      'detached': true,
    });
    final request_ = _sendRequest!;
    final sequence = (_observationSequence[observationId] ?? 0) + 1;
    _observationSequence[observationId] = sequence;
    request_.process.sendFrame(
      jsonEncode({
        'protocol': 'licoup.stdio.v1',
        'id': observationId,
        'workflowId': request_.workflowId,
        'kind': 'terminal',
        'sequence': sequence,
        'ok': true,
        'result': {
          'turnHandle': turnHandle,
          'conversationId': conversationId,
          'membershipId': membershipId,
          'cursor': _observationCursor[observationId] ?? 0,
          'status': 'running',
          'observationAvailable': false,
          'terminalPayloadAvailable': false,
          'detached': true,
        },
      }),
    );
  }
}

/// One minimum-shell assembly over the synthetic host.
final class ConversationFloodHarness {
  ConversationFloodHarness._({
    required this.host,
    required this.client,
    required this.transport,
    required this.port,
    required this.controller,
    required this.composition,
    required this.dataRoot,
  });

  static Future<ConversationFloodHarness> start({
    ConversationFloodHost? host,
    String fixtureNode = 'shared',
    String agentTarget = 'codex',
  }) async {
    final resolvedHost = host ?? ConversationFloodHost();
    final fixtureDirectory = conversationFloodFixtureDirectory(fixtureNode);
    if (!fixtureDirectory.existsSync()) {
      fixtureDirectory.createSync(recursive: true);
    }
    final dataRoot = Directory('${fixtureDirectory.path}/portable-data');
    if (!dataRoot.existsSync()) {
      dataRoot.createSync(recursive: true);
    }
    final client = NativeStdioRpcClient(
      processContext: resolvedHost.processContext,
    );
    final transport = RecordingTransport(client);
    // The substitute stays at the process seam: both instruments delegate to the
    // real client and the real stdio conversation port, so framing, lanes, the
    // bounded decode pipeline, the reserved control dispatch and the port
    // encoding are all production behaviour.
    final port = RecordingConversationPort(
      StdioConversationNativePort(transport: transport, desktopRuntime: true),
      transport.clock,
    );
    final service = AgentService(
      processContext: resolvedHost.processContext,
      stdioRpcTransport: transport,
      conversationNativePort: port,
      persistentStdioRpcEnabled: true,
    );
    final controller = ClientController(
      agentService: service,
      portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    controller.scannedTargets = [
      TargetCandidate(
        target: agentTarget,
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        binaryPath: '/synthetic/bin/$agentTarget',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
          // The shell steer action is only offered by a runtime that declares
          // interrupt/steer support.
          'conversationCapabilityMatrix': {'interruptSteer': true},
        },
      ),
    ];
    controller.selectedConversationAgentId = agentTarget;
    // The shell opens an existing local history session before it sends, so the
    // turn continues an already bound native session. That is what lets a later
    // shell input action steer the running turn instead of being queued for the
    // next one.
    controller.conversationSessionsByAgent =
        <String, List<AgentConversationSession>>{
          agentTarget: [
            AgentConversationSession(
              id: resolvedHost.sessionId,
              agentId: agentTarget,
              nativeSessionId: resolvedHost.sessionId,
              title: 'Flooded local session',
              createdAt: '2030-01-01T00:00:00Z',
              updatedAt: '2030-01-01T00:00:01Z',
              messages: const [],
              workingDirectory: fixtureDirectory.path,
            ),
          ],
        };
    controller.setSelectedConversationSessionId(
      agentTarget,
      resolvedHost.sessionId,
    );
    final composition = ConversationFeatureComposition(controller);
    return ConversationFloodHarness._(
      host: resolvedHost,
      client: client,
      transport: transport,
      port: port,
      controller: controller,
      composition: composition,
      dataRoot: dataRoot,
    );
  }

  final ConversationFloodHost host;
  final NativeStdioRpcClient client;
  final RecordingTransport transport;
  final RecordingConversationPort port;
  final ClientController controller;
  final ConversationFeatureComposition composition;
  final Directory dataRoot;

  String get composerScope => controller.conversationComposerScopeKey;

  ConversationExecutionReference get executionReference =>
      ConversationExecutionReference(
        conversationId: host.conversationId,
        membershipId: host.membershipId,
        turnHandle: host.turnHandle,
      );

  void sendIntent(ConversationIntent intent) =>
      composition.binding.intents.send(intent);

  /// Posts one shell input action for the selected local conversation.
  void postMessage(String content) => sendIntent(
    PostConversationMessage(
      conversationId: composerScope,
      content: content,
      addressedMembershipIds: const [],
    ),
  );

  /// Starts the flooded turn and waits until the shell has bound its identity.
  Future<void> startFloodedTurn({String text = 'first question'}) async {
    postMessage(text);
    await waitForCondition(
      () =>
          host.framesFor('agent.conversation.send').isNotEmpty &&
          controller.isSendingConversationMessage &&
          controller.sendingConversationTurnId == host.turnId &&
          controller.pendingPermissionRetryTool == host.approvalTool,
      reason: 'the shell to bind the flooded turn identity',
    );
  }

  Future<void> close() async {
    // A proof that failed mid-turn leaves the fixture's turn open; settle it so
    // teardown does not add an unrelated transport error to the failure.
    try {
      host.releaseTurn();
    } on Object {
      // The fixture peer may already be gone; teardown reports nothing new.
    }
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (controller.isSendingConversationMessage &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // An observation releases its native subscription when its own stream next
    // produces a frame, so closing the composition first and then publishing one
    // frame lets every deferred cancellation reach the transport before it is
    // disposed. Teardown then leaves no unrelated transport error behind.
    await composition.close();
    try {
      host.pushExecutionRecords(1);
    } on Object {
      // Teardown never reports a new failure.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await controller.close();
    await client.dispose();
    if (dataRoot.existsSync()) {
      dataRoot.deleteSync(recursive: true);
    }
  }

  /// Fixture and state snapshot for a failed proof, written next to the fixture
  /// store so a failing run is diagnosable without a live debugger.
  String diagnostics() {
    final lines = <String>[
      'sessionStarts=${host.processContext.startCount}',
      'processStates=${[for (final process in host.processContext.processes) 'killed=${process.killed}']}',
      'hostErrors=${host.hostErrors}',
      'transportDeliveries=${transport.deliveries}',
      'elapsedMs=${transport.clock.elapsedMilliseconds}',
      'seamFrames=${[for (final frame in host.seamFrames) '${frame['method']}:${jsonEncode(frame['params'] ?? frame['args'])}']}',
      'bulkFramesWritten=${host.bulkFramesWritten}/${host.bulkFrames}',
      'steerTexts=${host.steerTexts}',
      'cancelRequests=${host.cancelRequests}',
      'detachRequests=${host.detachRequests.length}',
      'bulkEventsObserved=${port.bulkEventsObserved}',
      'portOperations=${[for (final entry in port.operations) entry.toString()]}',
      'seamTerminal=${host.terminalWritten}',
      'isSending=${controller.isSendingConversationMessage}',
      'turnId=${controller.sendingConversationTurnId}',
      'nativeSessionId=${controller.sendingConversationNativeSessionId}',
      'pendingPermissionRetryTool=${controller.pendingPermissionRetryTool}',
      'lastError=${controller.lastError}',
    ];
    return lines.join('\n');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an input action, a cancellation and an approval decision each settle '
      'while a bulk output burst is still being delivered', () async {
    final harness = await ConversationFloodHarness.start(
      fixtureNode: 'NODE-014',
    );
    addTearDown(harness.close);
    try {
      await _proveControlResponsiveness(harness);
    } on Object {
      writeFloodDiagnostics('NODE-014', harness.diagnostics());
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// AC-005: each shell control action settles while the burst stays outstanding.
///
/// The three control actions are issued one at a time and each is measured
/// against the burst independently, so the proof is that a single control
/// operation overtakes an outstanding decode backlog, not that a batch of them
/// somehow completes together.
Future<void> _proveControlResponsiveness(
  ConversationFloodHarness harness,
) async {
  final host = harness.host;
  final port = harness.port;

  await harness.startFloodedTurn(text: 'approval probe question');

  // Preconditions: the burst is real and the turn is still open.
  expect(
    host.bulkFramesWritten,
    host.bulkFrames,
    reason: 'the phase-A bulk burst must already be on the wire',
  );
  expect(
    port.bulkEventsObserved,
    lessThan(host.bulkFrames),
    reason: 'the off-isolate decode backlog must still be outstanding',
  );
  expect(harness.controller.isSendingConversationMessage, isTrue);

  final phaseABulk = host.bulkFrames;

  // Input action from the shell.
  harness.postMessage('guidance while flooded');
  await waitForCondition(
    () => port.named('steer').any((entry) => entry.settled),
    reason: 'the input action to settle',
  );
  final inputSteer = port.named('steer').single;

  // Cancellation from the shell. A non-empty persistent conversation identity
  // selects the native turn-cancel branch, exactly as the renderer passes it.
  harness.sendIntent(
    InterruptConversationTurn(host.conversationId, host.membershipId),
  );
  await waitForCondition(
    () => port.named('cancel').any((entry) => entry.settled),
    reason: 'the cancellation to settle',
  );
  final cancel = port.named('cancel').single;

  // Approval decision from the shell, over the pending permission state the
  // synthetic host seeded.
  harness.sendIntent(const RetryConversationPermission());
  await waitForCondition(
    () => port.named('steer').length >= 2 && port.named('steer').last.settled,
    reason: 'the approval decision to settle',
  );
  final approval = port.named('steer').last;

  // The typed operations observed at the synthetic process seam, in order.
  final seamOrder = host.seamMethods
      .where(
        (method) =>
            method == 'agent.conversation.send' ||
            method == 'agent.conversation.steer' ||
            method == 'agent.conversation.cancel',
      )
      .toList(growable: false);
  expect(
    seamOrder.join(' | '),
    [
      'agent.conversation.send',
      'agent.conversation.steer',
      'agent.conversation.cancel',
      'agent.conversation.steer',
    ].join(' | '),
    reason: 'the typed control operations observed at the process seam',
  );
  final steerFrames = host
      .framesFor('agent.conversation.steer')
      .toList(growable: false);
  expect(
    jsonEncode(_typedIdentity(steerFrames.first)),
    jsonEncode({
      'agent': 'codex',
      'sessionId': host.sessionId,
      'turnId': host.turnId,
      'text': 'guidance while flooded',
    }),
    reason: 'the input action encoded as a typed steer operation',
  );
  expect(
    jsonEncode(_typedIdentity(steerFrames.last)),
    jsonEncode({
      'agent': 'codex',
      'sessionId': host.sessionId,
      'turnId': host.turnId,
      'text': 'approval probe question',
    }),
    reason: 'the approval decision encoded as a typed steer operation',
  );
  expect(
    jsonEncode(
      _typedIdentity(host.framesFor('agent.conversation.cancel').single),
    ),
    jsonEncode({'agent': 'codex', 'sessionId': host.sessionId}),
    reason:
        'the cancellation encoded as a typed cancel operation for the running '
        'session',
  );
  expect(host.steerTexts, hasLength(2));
  expect(host.cancelRequests, hasLength(1));
  expect(host.cancelFrameCount, 1);

  // The ordering fact that matters: each control operation overtook the bulk
  // frames already written ahead of its reply. Equality here would mean the
  // control reply had been queued behind every bulk frame on the wire.
  for (final entry in [inputSteer, cancel, approval]) {
    expect(entry.error, isNull, reason: '${entry.operation} must succeed');
    expect(entry.settled, isTrue, reason: '${entry.operation} must settle');
    expect(
      entry.bulkEventsAtSettlement,
      lessThan(phaseABulk),
      reason:
          '${entry.operation} settled after the whole delivered bulk burst '
          '(${entry.bulkEventsAtSettlement}/$phaseABulk); a control operation '
          'queued behind the bulk events fails here',
    );
  }
  expect(
    port.bulkEventsObserved,
    lessThan(phaseABulk),
    reason: 'the burst was still outstanding while the controls settled',
  );
  expect(host.bulkFramesWritten, phaseABulk);

  // The burst itself continues to be delivered after the control actions.
  host.releaseTurn();
  await waitForCondition(
    () => !harness.controller.isSendingConversationMessage,
    reason: 'the flooded turn to reach its terminal settlement',
    timeout: const Duration(minutes: 4),
  );
  await waitForCondition(
    () => port.bulkEventsObserved == host.totalBulkFrames,
    reason: 'the released burst half to be delivered',
    timeout: const Duration(minutes: 2),
  );
  expect(
    port.bulkEventsObserved,
    host.totalBulkFrames,
    reason: 'the flood continued after the control operations settled',
  );
  expect(harness.controller.lastError, isEmpty);
  final summary =
      'TASK-003 control-under-flood: bulk=$phaseABulk+${host.bulkFrames} '
      'steerAt=${inputSteer.bulkEventsAtSettlement}/$phaseABulk '
      'cancelAt=${cancel.bulkEventsAtSettlement}/$phaseABulk '
      'approvalAt=${approval.bulkEventsAtSettlement}/$phaseABulk '
      'steerMs=${inputSteer.settledAtMs} cancelMs=${cancel.settledAtMs} '
      'approvalMs=${approval.settledAtMs} '
      'delivered=${port.bulkEventsObserved}';
  writeFloodEvidence('NODE-014', '$summary\n${harness.diagnostics()}');
  // ignore: avoid_print
  print(summary);
}

/// The typed identity and text of one conversation operation frame.
Map<String, dynamic> _typedIdentity(Map<String, dynamic> frame) {
  final params = Map<String, dynamic>.from(frame['params'] as Map? ?? const {});
  return <String, dynamic>{
    for (final key in const ['agent', 'sessionId', 'turnId', 'text'])
      if (params[key] != null) key: params[key],
  };
}

String _filler(int length) {
  const unit = 'licoup-control-under-flood-payload-';
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(unit);
  }
  return buffer.toString().substring(0, length);
}
