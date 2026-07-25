import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_conversation_fixture.dart';
import 'fake_agent_conversation_support.dart';
import 'fake_agent_state_support.dart';

mixin FakeAgentRuntimeSupport
    on AgentService, FakeAgentStateSupport, FakeAgentConversationSupport {
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
  String runtimeMessageRpcErrorCode = '';
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

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    if (runtimeMessageRpcErrorCode.isNotEmpty) {
      throw LicoClientRpcException(runtimeMessageRpcErrorCode);
    }
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
}
