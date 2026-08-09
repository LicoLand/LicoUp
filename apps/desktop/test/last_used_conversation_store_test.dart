import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_last_used_conversation.dart';
import 'package:licoup/src/platform/agents/last_used_conversation_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PortableDataRoot portableData;
  const store = PlatformLastUsedConversationStore();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'lico-last-used-conversation-',
    );
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('round-trips the persisted last-used conversation', () async {
    expect(await store.load(portableData), isNull);

    await store.save(
      portableData,
      const LastUsedConversationRef(
        agentId: 'codex',
        sessionId: 'native-session-42',
      ),
    );

    final restored = await store.load(portableData);
    expect(restored, isNotNull);
    expect(restored!.agentId, 'codex');
    expect(restored.sessionId, 'native-session-42');
  });

  test('keeps an empty session id as the agent home', () async {
    await store.save(
      portableData,
      const LastUsedConversationRef(agentId: 'claude-code', sessionId: ''),
    );

    final restored = await store.load(portableData);
    expect(restored, isNotNull);
    expect(restored!.agentId, 'claude-code');
    expect(restored.sessionId, isEmpty);
  });

  test('refuses to persist an empty reference', () async {
    await store.save(
      portableData,
      const LastUsedConversationRef(agentId: '', sessionId: ''),
    );
    expect(await store.load(portableData), isNull);
  });

  test('loads nothing from a missing or malformed document', () async {
    final dataDir = await portableData.dataDirectory();
    final file = File('${dataDir.path}/last-used-conversation.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{"schemaVersion": 99, "agentId": "codex"}');

    expect(await store.load(portableData), isNull);
  });
}
