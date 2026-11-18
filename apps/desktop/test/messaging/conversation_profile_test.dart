import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_registry.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_store.dart';
import 'package:licoup/src/platform/messaging/conversation_profile_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

ConversationProfile _profile({
  String id = 'nova',
  String conversationId = '',
}) => ConversationProfile(
  id: id,
  name: 'Nova',
  mascotAvatarId: 'luna',
  agentId: 'codex',
  modelId: 'gpt-5.4',
  reasoningEffort: 'high',
  permissionMode: 'auto',
  environment: '/work',
  contextWindowTokens: 64000,
  instructions: 'Answer briefly.',
  createdAtUnixMs: 7,
  conversationId: conversationId,
);

final class _FakeProfileStore extends ConversationProfileStore {
  _FakeProfileStore(this.stored);

  List<ConversationProfile> stored;
  final List<List<ConversationProfile>> saves = <List<ConversationProfile>>[];

  @override
  Future<List<ConversationProfile>> load(Object portableData) async => stored;

  @override
  Future<void> save(
    Object portableData,
    List<ConversationProfile> profiles,
  ) async {
    stored = List<ConversationProfile>.of(profiles);
    saves.add(List<ConversationProfile>.of(profiles));
  }
}

void main() {
  group('ConversationProfile', () {
    test('round-trips through JSON', () {
      final profile = _profile(conversationId: 'conversation:direct');
      final decoded = ConversationProfile.fromJson(profile.toJson());
      expect(decoded, profile);
      expect(decoded.principalId, 'profile:nova');
    });

    test('maps its preferences onto the membership intent fields', () {
      final intent = _profile().intent;
      expect(intent['preferredModel'], 'gpt-5.4');
      expect(intent['preferredReasoningEffort'], 'high');
      expect(intent['preferredPermissionMode'], 'auto');
      expect(intent['preferredEnvironment'], '/work');
      expect(intent['preferredInstructions'], 'Answer briefly.');
      expect(intent['preferredContextWindow'], 64000);
    });

    test('empty preferences serialize as null intent fields', () {
      const empty = ConversationProfile(
        id: 'blank',
        name: 'Blank',
        mascotAvatarId: 'lico',
        agentId: 'codex',
        createdAtUnixMs: 1,
      );
      final intent = empty.intent;
      expect(intent['preferredModel'], isNull);
      expect(intent['preferredReasoningEffort'], isNull);
      expect(intent['preferredInstructions'], isNull);
      expect(intent['preferredContextWindow'], isNull);
    });
  });

  group('conversation profile registry', () {
    late ConversationProfileStore Function() previousStore;
    late Object? previousData;

    setUp(() {
      previousStore = ClientPlatformPorts.conversationProfileStore;
      previousData = ClientPlatformPorts.portableData;
      ClientPlatformPorts.portableData = const Object();
      resetConversationProfilesForTests();
    });

    tearDown(() {
      ClientPlatformPorts.conversationProfileStore = previousStore;
      ClientPlatformPorts.portableData = previousData;
      resetConversationProfilesForTests();
    });

    test('hydrates the stored registry once', () async {
      final store = _FakeProfileStore([_profile()]);
      ClientPlatformPorts.conversationProfileStore = () => store;

      await hydrateConversationProfiles();
      await hydrateConversationProfiles();

      expect(conversationProfiles.value.single.id, 'nova');
      expect(store.saves, isEmpty);
    });

    test('a new profile persists through the listener', () async {
      final store = _FakeProfileStore(const []);
      ClientPlatformPorts.conversationProfileStore = () => store;
      await hydrateConversationProfiles();

      addConversationProfile(_profile());
      await Future<void>.value();

      expect(store.saves.single.single.id, 'nova');
      expect(conversationProfileById('nova')?.agentId, 'codex');
      expect(conversationProfileForPrincipal('profile:nova')?.name, 'Nova');
      expect(conversationProfileForPrincipal('agent:codex'), isNull);
    });

    test('attachConversationProfileConversation rewrites the record', () {
      addConversationProfile(_profile());

      attachConversationProfileConversation('nova', 'conversation:direct');
      attachConversationProfileConversation('nova', '');

      expect(
        conversationProfileById('nova')?.conversationId,
        'conversation:direct',
      );
      expect(conversationProfileById('missing'), isNull);
    });
  });

  group('PlatformConversationProfileStore', () {
    late Directory temporaryRoot;
    late PortableDataRoot portableData;

    setUp(() async {
      temporaryRoot = await Directory.systemTemp.createTemp(
        'conversation-profiles-test-',
      );
      portableData = PortableDataRoot(dataDirectoryOverride: temporaryRoot);
    });

    tearDown(() async {
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    });

    test('a missing document loads an empty registry', () async {
      const store = PlatformConversationProfileStore();
      expect(await store.load(portableData), isEmpty);
    });

    test('saved profiles round-trip through a fresh store instance', () async {
      const store = PlatformConversationProfileStore();
      await store.save(portableData, [
        _profile(),
        _profile(id: 'mochi').copyWith(conversationId: 'conversation:x'),
      ]);

      const reopened = PlatformConversationProfileStore();
      final loaded = await reopened.load(portableData);
      expect(loaded.map((entry) => entry.id), ['nova', 'mochi']);
      expect(loaded.last.conversationId, 'conversation:x');
      expect(loaded.first, _profile());
    });

    test('malformed entries are skipped, not fatal', () async {
      const store = PlatformConversationProfileStore();
      await store.save(portableData, [_profile()]);
      final file = File(
        '${temporaryRoot.path}/client-state/conversation-profiles.json',
      );
      final decoded = file.readAsStringSync();
      file.writeAsStringSync(
        decoded.replaceFirst('"agentId": "codex"', '"agentId": ""'),
      );

      expect(await store.load(portableData), isEmpty);
    });
  });
}
