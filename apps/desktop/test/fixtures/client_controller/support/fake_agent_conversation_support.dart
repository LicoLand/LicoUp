import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_conversation_fixture.dart';
import 'fake_agent_state_support.dart';

mixin FakeAgentConversationSupport on AgentService, FakeAgentStateSupport {
  int conversationListCalls = 0;
  int conversationStreamCalls = 0;
  int conversationAppendCalls = 0;
  int conversationDeleteCalls = 0;

  Map<String, List<Map<String, dynamic>>> conversationSessions = {};
  final Map<String, Completer<void>> conversationStreamGates = {};
  List<Map<String, dynamic>> conversationStdinRequests = const [];

  void recordConversationStdinRequest(Map<String, dynamic> request) {
    conversationStdinRequests = [
      ...conversationStdinRequests,
      Map<String, dynamic>.unmodifiable(request),
    ];
  }

  List<Map<String, dynamic>> fakeConversationSessionRequestPage(
    Map<String, dynamic> request,
  ) {
    final agent = (request['agent'] ?? '').toString();
    final offset = switch (request['offset']) {
      final int value => value,
      final Object value => int.tryParse(value.toString()) ?? 0,
      null => 0,
    };
    final limit = switch (request['limit']) {
      final int value => value,
      final Object value => int.tryParse(value.toString()),
      null => null,
    };
    final sessionId = (request['sessionId'] ?? '').toString();
    final source =
        conversationSessions[agent] ?? const <Map<String, dynamic>>[];
    final filtered = sessionId.isEmpty
        ? source
        : source
              .where(
                (session) =>
                    (session['id'] ?? '').toString() == sessionId ||
                    (session['nativeSessionId'] ?? '').toString() == sessionId,
              )
              .toList(growable: false);
    final skipped = filtered.skip(offset < 0 ? 0 : offset);
    return (limit == null || limit <= 0 ? skipped : skipped.take(limit)).toList(
      growable: false,
    );
  }

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
