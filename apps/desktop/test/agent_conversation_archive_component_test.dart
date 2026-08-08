import 'dart:io';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'conversation facade delegates archive work to injected component',
    () async {
      final archive = _RecordingArchiveService();
      final service = AgentConversationService(archiveService: archive);

      final result = await service.createArchiveJob(
        agentService: _NoopAgentCommandRunner(),
        selectionMode: 'exact-keyword',
        query: 'bounded topic',
        path: 'workspace/archive',
        planBinding: 'sha256:bounded-plan',
        archiveParallelism: 3,
        maxAttempts: 4,
      );

      expect(result, {'ok': true, 'status': 'injected'});
      expect(archive.calls, 1);
      expect(archive.lastQuery, 'bounded topic');
    },
  );

  test('archive component is a normal one-way dependency', () {
    const root = 'lib/src/backend/features/agents/services';
    final facade = File(
      '$root/agent_conversation_service.dart',
    ).readAsStringSync();
    final archive = File(
      '$root/agent_conversation_archive_service.dart',
    ).readAsStringSync();

    for (final source in [facade, archive]) {
      expect(
        RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
        isFalse,
      );
    }
    expect(archive, isNot(contains('agent_conversation_service.dart')));
    expect(facade, contains('AgentConversationArchiveService archiveService'));
    expect(facade, contains('_archiveService.createArchiveJob'));
  });
}

final class _RecordingArchiveService extends AgentConversationArchiveService {
  int calls = 0;
  String lastQuery = '';

  @override
  Future<Map<String, dynamic>> createArchiveJob({
    required AgentCommandRunner agentService,
    required String selectionMode,
    required String path,
    required String planBinding,
    String query = '',
    String sourceAgentId = '',
    int? archiveParallelism,
    int maxAttempts = 2,
  }) async {
    calls++;
    lastQuery = query;
    return const {'ok': true, 'status': 'injected'};
  }
}

final class _NoopAgentCommandRunner implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) {
    throw UnimplementedError();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    return const Stream.empty();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    return const Stream.empty();
  }
}
