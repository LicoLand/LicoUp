import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_agent_account_service.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_agent_account_store.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

void main() {
  group('mobile provider account system', () {
    test('accountId is independent from providerId for new accounts', () async {
      final portableData = await _tempPortableData();
      const service = MobileAgentAccountService(
        store: PlatformMobileAgentAccountStore(),
      );

      final first = await service.configureApiCredential(
        portableData,
        'deepseek',
        'deepseek-test-key-0001',
        label: 'One',
      );
      final second = await service.addProvider(portableData, 'deepseek');

      expect(first, hasLength(1));
      expect(second, hasLength(2));
      expect(first.single.id, isNot(equals('deepseek')));
      expect(first.single.providerId, 'deepseek');
      expect(second.map((account) => account.id).toSet(), hasLength(2));
      expect(
        second.every((account) => account.providerId == 'deepseek'),
        isTrue,
      );
      expect(second.where((account) => account.active), hasLength(1));
    });

    test('provider descriptors encode auth and capability boundaries', () {
      final chatgpt = mobileAgentProviderFor('chatgpt');
      final deepseek = mobileAgentProviderFor('deepseek');
      final gemini = mobileAgentProviderFor('gemini');
      final kimi = mobileAgentProviderFor('kimi');

      expect(chatgpt.authKind, MobileAgentAuthKind.oauthPkce);
      expect(chatgpt.supportsDirectChat, isTrue);
      expect(chatgpt.supportsDesktopRelay, isTrue);
      expect(chatgpt.supportsPhoneAssistant, isTrue);
      expect(chatgpt.requiresOAuthDescriptor, isTrue);
      expect(chatgpt.oauthDescriptor.isUsable, isTrue);
      expect(chatgpt.supportsLocalOAuthLogin, isTrue);
      expect(
        chatgpt.localOAuthAvailability,
        MobileAgentLocalOAuthAvailability.supported,
      );

      expect(deepseek.authKind, MobileAgentAuthKind.apiKey);
      expect(deepseek.requiresOAuthDescriptor, isFalse);

      expect(gemini.authKind, MobileAgentAuthKind.oauthPkce);
      expect(gemini.requiresOAuthDescriptor, isFalse);
      expect(gemini.oauthDescriptor.isUsable, isFalse);
      expect(gemini.oauthDescriptor.clientIdRef, isEmpty);
      expect(gemini.supportsLocalOAuthLogin, isFalse);
      expect(gemini.localOAuthDeferred, isTrue);

      expect(kimi.authKind, MobileAgentAuthKind.oauthPkce);
      expect(kimi.oauthDescriptor.isUsable, isFalse);
      expect(kimi.oauthDescriptor.clientIdRef, isEmpty);
      expect(kimi.supportsLocalOAuthLogin, isFalse);
      expect(kimi.localOAuthDeferred, isTrue);
    });

    test('migrates provider-shaped records into account metadata', () async {
      final portableData = await _tempPortableData();
      const store = PlatformMobileAgentAccountStore();
      const service = MobileAgentAccountService(store: store);

      await store.write(portableData, {
        'schemaVersion': 1,
        'accounts': [
          {
            'id': 'deepseek',
            'providerId': 'deepseek',
            'label': 'DeepSeek',
            'authState': 'configured',
            'credentialPresent': true,
            'credentialHint': '**** 9999',
            'authSource': 'local-api-key',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
          },
          {
            'id': 'chatgpt',
            'providerId': 'chatgpt',
            'label': 'ChatGPT',
            'authState': 'configured',
            'credentialPresent': true,
            'credentialHint': 'OAuth',
            'authSource': 'local-oauth',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
          },
        ],
      });

      final loaded = await service.load(portableData);
      expect(loaded, hasLength(2));
      final deepseek = loaded.firstWhere(
        (account) => account.providerId == 'deepseek',
      );
      final chatgpt = loaded.firstWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(deepseek.id, 'deepseek');
      expect(deepseek.credentialRef, contains('secure-ref:'));
      expect(deepseek.sourceMode, MobileAgentSourceMode.mobileLocal);
      expect(deepseek.authKind, MobileAgentAuthKind.apiKey);
      expect(deepseek.active, isTrue);
      expect(chatgpt.authKind, MobileAgentAuthKind.oauthPkce);
      expect(chatgpt.sourceMode, MobileAgentSourceMode.mobileLocal);
      expect(chatgpt.credentialRef, contains('oauth'));

      final raw = await store.read(portableData) as Map;
      expect(raw['schemaVersion'], MobileAgentAccount.currentSchemaVersion);
      final encoded = jsonEncode(raw);
      expect(encoded.contains('sk-'), isFalse);
      expect(encoded.toLowerCase().contains('access_token'), isFalse);
      expect(encoded.toLowerCase().contains('refresh_token'), isFalse);
      expect(encoded.contains('@'), isFalse);
    });

    test(
      'persists multiple accounts, active switch, and sibling deletion',
      () async {
        final portableData = await _tempPortableData();
        const service = MobileAgentAccountService(
          store: PlatformMobileAgentAccountStore(),
        );

        await service.configureApiCredential(
          portableData,
          'deepseek',
          'deepseek-test-key-1111',
          label: 'Work',
        );
        await service.configureApiCredential(
          portableData,
          'deepseek',
          'deepseek-test-key-2222',
          label: 'Personal',
        );
        var accounts = await service.load(portableData);
        expect(accounts.where((a) => a.providerId == 'deepseek'), hasLength(2));
        final work = accounts.firstWhere((account) => account.label == 'Work');
        final personal = accounts.firstWhere(
          (account) => account.label == 'Personal',
        );
        expect(personal.active, isTrue);
        expect(work.active, isFalse);

        accounts = await service.setActiveAccount(portableData, work.id);
        expect(
          accounts.firstWhere((account) => account.id == work.id).active,
          isTrue,
        );
        expect(
          accounts.firstWhere((account) => account.id == personal.id).active,
          isFalse,
        );

        accounts = await service.removeAccounts(portableData, [personal.id]);
        expect(accounts.map((account) => account.id), [work.id]);
        expect(accounts.single.active, isTrue);
        expect(accounts.single.credentialHint, '**** 1111');
      },
    );

    test('portable save never writes raw secrets', () async {
      final portableData = await _tempPortableData();
      const store = PlatformMobileAgentAccountStore();
      const service = MobileAgentAccountService(store: store);

      await service.configureApiCredential(
        portableData,
        'deepseek',
        ['sk', 'very', 'secret', 'api', 'key', 'abcdef'].join('-'),
      );
      await service.markOAuthCredentialPresent(
        portableData,
        'chatgpt',
        credentialHint: 'OAuth',
      );

      final raw = await store.read(portableData) as Map;
      final encoded = jsonEncode(raw);
      expect(encoded.contains('sk-very-secret'), isFalse);
      expect(encoded.contains('abcdef'), isFalse);
      expect(encoded.toLowerCase().contains('refresh_token'), isFalse);
      expect(encoded.toLowerCase().contains('access_token'), isFalse);
    });

    test('assistant grants default off and stay account-scoped', () async {
      final portableData = await _tempPortableData();
      const service = MobileAgentAccountService(
        store: PlatformMobileAgentAccountStore(),
      );

      await service.configureApiCredential(
        portableData,
        'deepseek',
        'deepseek-test-key-3333',
        label: 'A',
      );
      await service.configureApiCredential(
        portableData,
        'deepseek',
        'deepseek-test-key-4444',
        label: 'B',
      );
      final accounts = await service.load(portableData);
      final a = accounts.firstWhere((account) => account.label == 'A');
      final b = accounts.firstWhere((account) => account.label == 'B');
      expect(a.assistantGrants.localInfo, isFalse);
      expect(a.assistantGrants.accessibility, isFalse);

      final updated = await service.updateAssistantGrants(
        portableData,
        a.id,
        const MobileAgentAssistantGrants(localInfo: true, accessibility: true),
      );
      final nextA = updated.firstWhere((account) => account.id == a.id);
      final nextB = updated.firstWhere((account) => account.id == b.id);
      expect(nextA.assistantGrants.localInfo, isTrue);
      expect(nextA.assistantGrants.accessibility, isTrue);
      expect(nextB.assistantGrants.localInfo, isFalse);
      expect(nextB.assistantGrants.accessibility, isFalse);

      final reloaded = await service.load(portableData);
      expect(
        reloaded
            .firstWhere((account) => account.id == a.id)
            .assistantGrants
            .localInfo,
        isTrue,
      );
      expect(
        reloaded
            .firstWhere((account) => account.id == b.id)
            .assistantGrants
            .localInfo,
        isFalse,
      );
    });

    test('desktop relay echo preserves account metadata without secrets', () {
      final local = MobileAgentAccount.create(
        mobileAgentProviderFor('deepseek'),
        id: 'mpa-deepseek-local',
        label: 'Phone DeepSeek',
        authSource: MobileAgentAccount.authSourceLocalApiKey,
        credentialPresent: true,
        credentialHint: '**** 1234',
        active: true,
      );
      final relayConfig = MobileRelayConfig.fromJson({
        'schemaVersion': 1,
        'pcClientName': 'Desk',
        'pairingId': 'pair-1',
        'pcClientId': 'pc-1',
        'paired': true,
        'pcTokenPresent': true,
        'mobileTokenPresent': true,
        'authorizedProviders': [
          {
            'providerId': 'deepseek',
            'label': 'Desk DeepSeek',
            'credentialPresent': true,
            'accountId': 'desk-ds-1',
            'profileId': 'profile-ds',
            'credentialKind': 'api-key',
            'authKind': 'api-key',
            'sourceMode': 'desktop-relay',
          },
          {
            'providerId': 'chatgpt',
            'label': 'Desk ChatGPT',
            'credentialPresent': true,
            'accountId': 'desk-cg-1',
            'credentialKind': 'oauth-pkce',
            'authKind': 'oauth-pkce',
            'sourceMode': 'desktop-relay',
          },
        ],
      });

      final merged = mobileAgentAccountsWithDesktopRelay([local], relayConfig);
      expect(
        merged.any(
          (account) => account.id == local.id && account.usesMobileLocal,
        ),
        isTrue,
      );
      final relayDeepseek = merged.firstWhere(
        (account) =>
            account.providerId == 'deepseek' && account.usesDesktopRelay,
      );
      final relayChatgpt = merged.firstWhere(
        (account) =>
            account.providerId == 'chatgpt' && account.usesDesktopRelay,
      );
      expect(relayDeepseek.authKind, MobileAgentAuthKind.desktopRelay);
      expect(relayDeepseek.sourceMode, MobileAgentSourceMode.desktopRelay);
      expect(relayDeepseek.credentialRef.startsWith('secure-ref:'), isTrue);
      expect(relayDeepseek.credentialRef.contains('sk-live'), isFalse);
      expect(relayChatgpt.label, 'Desk ChatGPT');

      final encoded = jsonEncode({
        'accounts': merged.map((account) => account.toJson()).toList(),
      });
      expect(encoded.toLowerCase().contains('access_token'), isFalse);
      expect(encoded.toLowerCase().contains('refresh_token'), isFalse);
      expect(encoded.contains('"apiKey"'), isFalse);
      expect(encoded.contains('sk-live'), isFalse);
    });

    test('rename and touch update metadata only', () async {
      final portableData = await _tempPortableData();
      const service = MobileAgentAccountService(
        store: PlatformMobileAgentAccountStore(),
      );
      final configured = await service.configureApiCredential(
        portableData,
        'deepseek',
        'deepseek-test-key-5555',
      );
      final accountId = configured.single.id;
      final renamed = await service.renameAccount(
        portableData,
        accountId,
        'Lab Key',
      );
      expect(renamed.single.label, 'Lab Key');
      expect(renamed.single.credentialHint, '**** 5555');

      final touched = await service.touchAccount(
        portableData,
        accountId,
        lastUsedAt: '2026-07-11T00:00:00.000Z',
      );
      expect(touched.single.lastUsedAt, '2026-07-11T00:00:00.000Z');
    });
  });
}

Future<PortableDataRoot> _tempPortableData() async {
  final directory = await Directory.systemTemp.createTemp(
    'lico-mobile-provider-account-',
  );
  addTearDown(() => directory.delete(recursive: true));
  return PortableDataRoot(dataDirectoryOverride: directory);
}
