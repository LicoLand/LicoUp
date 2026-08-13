import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  test('GroupConversationRecord round-trips agent session bindings', () {
    final record = GroupConversationRecord(
      id: defaultLicoGroupConversationId,
      title: 'Lico',
      roster: GroupRoster.empty.ensureHuman('You').copyWithMainAgent('antigravity'),
      turnTaking: TurnTakingPolicy.flywheelMainDispatch,
      transcriptPath: '/tmp/transcript.jsonl',
      agentSessions: {
        'antigravity': const GroupAgentSessionBinding(
          agentId: 'antigravity',
          nativeSessionId: 'native-main',
          sourcePath: '/tmp/main.json',
          workingDirectory: '/tmp/project',
          updatedAtUnixMs: 10,
        ),
        'codex': const GroupAgentSessionBinding(
          agentId: 'codex',
          nativeSessionId: 'native-peer',
          sourcePath: '/tmp/peer.json',
          updatedAtUnixMs: 11,
        ),
      },
      lastLocalOrchestrationSessionId: 'lico-local-1',
    );

    final restored = GroupConversationRecord.fromJson(record.toJson());
    expect(restored.lastLocalOrchestrationSessionId, 'lico-local-1');
    expect(restored.bindingFor('antigravity')?.nativeSessionId, 'native-main');
    expect(restored.bindingFor('codex')?.sourcePath, '/tmp/peer.json');
  });

  test('upsertAgentSession preserves roster and remembers resume handles', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-group-binding-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portable = PortableDataRoot(dataDirectoryOverride: directory);
    final store = GroupConversationStore();
    await store.syncRosterFromFlywheel(
      portableData: portable,
      mainAgentId: 'antigravity',
      agents: [(id: 'antigravity', label: 'Antigravity')],
    );

    final updated = await store.upsertAgentSession(
      portableData: portable,
      agentId: 'antigravity',
      nativeSessionId: 'native-42',
      sourcePath: '/Users/me/.gemini/conversations/abc',
      workingDirectory: '/Users/me/project',
      localOrchestrationSessionId: 'lico-local-9',
    );

    expect(updated.roster.mainAgentId, 'antigravity');
    expect(updated.bindingFor('antigravity')?.nativeSessionId, 'native-42');
    expect(
      updated.bindingFor('antigravity')?.sourcePath,
      '/Users/me/.gemini/conversations/abc',
    );
    expect(updated.lastLocalOrchestrationSessionId, 'lico-local-9');

    final peer = await store.upsertAgentSession(
      portableData: portable,
      agentId: 'codex',
      sourcePath: '/tmp/codex-session.jsonl',
    );
    expect(peer.bindingFor('antigravity')?.nativeSessionId, 'native-42');
    expect(peer.bindingFor('codex')?.sourcePath, '/tmp/codex-session.jsonl');
    expect(peer.lastLocalOrchestrationSessionId, 'lico-local-9');
  });
}
