import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_conversation_fixture.dart';
import 'fake_agent_state_support.dart';

mixin FakeAgentConversationSupport on AgentService, FakeAgentStateSupport {
  int conversationListCalls = 0;
  int conversationStreamCalls = 0;
  int conversationAppendCalls = 0;
  int conversationDeleteCalls = 0;
  int runtimeMessageCalls = 0;
  int runtimeSteerCalls = 0;
  int runtimeCancelCalls = 0;

  String runtimeSessionIdResult = '';
  String runtimeThreadIdResult = '';
  String runtimeNativeSessionIdResult = '';
  Map<String, dynamic> lastRuntimeMessageRequest = const {};
  Map<String, dynamic> lastRuntimeSteerRequest = const {};
  Map<String, dynamic> lastRuntimeCancelRequest = const {};
  List<Map<String, dynamic>> runtimeMessageRequests = const [];
  List<Map<String, dynamic>> runtimeMessageResultQueue = const [];
  List<List<Map<String, dynamic>>> runtimeMessageStreamEventQueue = const [];
  bool recordRuntimeMessageInHistory = true;
  Completer<void>? runtimeMessageGate;
  bool runtimeSteerThrows = false;
  Map<String, dynamic> runtimeSteerResult = const {
    'ok': true,
    'status': 'steer_accepted',
  };
  Map<String, dynamic> runtimeCancelResult = const {
    'ok': true,
    'status': 'cancel_requested',
  };

  Map<String, List<Map<String, dynamic>>> conversationSessions = {};
  final Map<String, Completer<void>> conversationStreamGates = {};

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) async* {
    cliCalls = [...cliCalls, List<String>.from(args)];
    if (args.length >= 2 && args[0] == 'conversations' && args[1] == 'stream') {
      conversationStreamCalls++;
      final gate = conversationStreamGates[fakeAgentArgValue(args, '--agent')];
      if (gate != null) {
        await gate.future;
      }
      for (final session in fakeConversationSessionPage(args)) {
        await Future<void>.delayed(Duration.zero);
        yield {'event': 'session', 'ok': true, 'session': session};
      }
      yield {'event': 'done', 'ok': true};
      return;
    }
    throw Exception('unsupported stream command: ${args.join(' ')}');
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    final result = await runCliWithStdin(args, stdinText);
    final streamEvents = runtimeMessageStreamEventQueue.isEmpty
        ? const <Map<String, dynamic>>[]
        : runtimeMessageStreamEventQueue.removeAt(0);
    for (final event in streamEvents) {
      yield event;
    }
    yield {'event': 'done', ...result};
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    cliCalls = [...cliCalls, List<String>.from(args)];
    if (args.length >= 3 &&
        args[0] == 'agent' &&
        args[1] == 'conversation' &&
        args[2] == 'open') {
      final decoded = jsonDecode(stdinText);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('runtime open stdin must be a JSON object');
      }
      final sessionId = (decoded['sessionId'] ?? '').toString();
      return {
        'ok': true,
        if (sessionId.isNotEmpty) 'nativeSessionId': sessionId,
      };
    }
    if (args.length >= 3 &&
        args[0] == 'agent' &&
        args[1] == 'conversation' &&
        args[2] == 'steer') {
      if (runtimeSteerThrows) {
        throw Exception('synthetic steer outcome unknown');
      }
      final decoded = jsonDecode(stdinText);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('runtime steer stdin must be a JSON object');
      }
      runtimeSteerCalls++;
      lastRuntimeSteerRequest = Map<String, dynamic>.from(decoded);
      return {
        'nativeSessionId': (decoded['sessionId'] ?? '').toString(),
        ...runtimeSteerResult,
      };
    }
    if (args.length >= 3 &&
        args[0] == 'agent' &&
        args[1] == 'conversation' &&
        args[2] == 'cancel') {
      final decoded = jsonDecode(stdinText);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('runtime cancel stdin must be a JSON object');
      }
      runtimeCancelCalls++;
      lastRuntimeCancelRequest = Map<String, dynamic>.from(decoded);
      return runtimeCancelResult;
    }
    expect(args.take(5).toList(), [
      'agent',
      'conversation',
      'send',
      '--stdin-json',
      'true',
    ]);
    final decoded = jsonDecode(stdinText);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('runtime message stdin must be a JSON object');
    }
    runtimeMessageCalls++;
    lastRuntimeMessageRequest = Map<String, dynamic>.from(decoded);
    runtimeMessageRequests = [
      ...runtimeMessageRequests,
      Map<String, dynamic>.from(decoded),
    ];
    final messageGate = runtimeMessageGate;
    if (messageGate != null && !messageGate.isCompleted) {
      await messageGate.future;
    }
    final sessionId = runtimeSessionIdResult.isNotEmpty
        ? runtimeSessionIdResult
        : (decoded['sessionId'] ?? '').toString().isNotEmpty
        ? decoded['sessionId'].toString()
        : 'native-${decoded['agent']}-$runtimeMessageCalls';
    final threadId = runtimeThreadIdResult.isNotEmpty
        ? runtimeThreadIdResult
        : sessionId;
    final nativeSessionId = runtimeNativeSessionIdResult.isNotEmpty
        ? runtimeNativeSessionIdResult
        : threadId;
    final queued = runtimeMessageResultQueue.isEmpty
        ? const <String, dynamic>{}
        : runtimeMessageResultQueue.removeAt(0);
    final response = <String, dynamic>{
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': (decoded['agent'] ?? 'codex').toString(),
      'runtimeProtocol': 'codex-app-server',
      'sessionId': sessionId,
      'threadId': threadId,
      'nativeSessionId': nativeSessionId,
      'text': 'Agent reply $runtimeMessageCalls',
      'effective': {
        'model': decoded['model'],
        'reasoningEffort': decoded['reasoningEffort'],
      },
      ...queued,
    };
    if (response['ok'] == true && recordRuntimeMessageInHistory) {
      final agentId = (decoded['agent'] ?? 'codex').toString();
      final recorded =
          buildFakeConversationSession(
              id: nativeSessionId,
              agentId: agentId,
              agentLabel: agentId,
              text: decoded['text'].toString(),
            )
            ..['nativeSessionId'] = nativeSessionId
            ..['adapterId'] = agentId
            ..['sourceKind'] = '$agentId-native-history'
            ..['importMode'] = 'precise-adapter'
            ..['sourceTool'] = agentId;
      conversationSessions = {
        ...conversationSessions,
        agentId: [
          recorded,
          ...(conversationSessions[agentId] ?? const []).where(
            (session) =>
                (session['nativeSessionId'] ?? session['id']).toString() !=
                nativeSessionId,
          ),
        ],
      };
    }
    return response;
  }

  Future<Map<String, dynamic>?> handleFakeAgentConversationCli(
    List<String> args,
  ) async {
    if (args.length >= 2 && args.first == 'conversations') {
      switch (args[1]) {
        case 'list':
          conversationListCalls++;
          return {'ok': true, 'sessions': fakeConversationSessionPage(args)};
        case 'append':
          conversationAppendCalls++;
          final agent = fakeAgentArgValue(args, '--agent');
          final label = fakeAgentArgValue(
            args,
            '--agent-label',
            fallback: agent,
          );
          final text = fakeAgentArgValue(args, '--text').trim();
          final sessionId = fakeAgentArgValue(
            args,
            '--session-id',
            fallback: 'session-$conversationAppendCalls',
          );
          final session = buildFakeConversationSession(
            id: sessionId,
            agentId: agent,
            agentLabel: label,
            text: text,
          );
          conversationSessions = {
            ...conversationSessions,
            agent: [
              session,
              ...(conversationSessions[agent] ?? const []).where(
                (item) => item['id'] != sessionId,
              ),
            ],
          };
          return {'ok': true, 'session': session};
        case 'delete':
          conversationDeleteCalls++;
          final agent = fakeAgentArgValue(args, '--agent');
          final sessionId = fakeAgentArgValue(args, '--session-id');
          conversationSessions = {
            ...conversationSessions,
            agent: (conversationSessions[agent] ?? const [])
                .where((item) => item['id'] != sessionId)
                .toList(),
          };
          return {'ok': true};
      }
    }
    return null;
  }

  List<Map<String, dynamic>> fakeConversationSessionPage(List<String> args) {
    final agent = fakeAgentArgValue(args, '--agent');
    final offset =
        int.tryParse(fakeAgentArgValue(args, '--offset', fallback: '0')) ?? 0;
    final limit = int.tryParse(fakeAgentArgValue(args, '--limit'));
    final source =
        conversationSessions[agent] ?? const <Map<String, dynamic>>[];
    final sessionId = fakeAgentArgValue(args, '--session-id');
    final filtered = sessionId.isEmpty
        ? source
        : source
              .where(
                (session) =>
                    (session['id'] ?? '').toString() == sessionId ||
                    (session['nativeSessionId'] ?? '').toString() == sessionId,
              )
              .toList(growable: false);
    final safeOffset = offset < 0 ? 0 : offset;
    final skipped = filtered.skip(safeOffset);
    return (limit == null || limit <= 0 ? skipped : skipped.take(limit)).toList(
      growable: false,
    );
  }
}
