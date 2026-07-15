import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:flutter_client/src/frontend/shell/client_shell.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:flutter_client/src/frontend/shared/ui/provider_brand_icon.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('mobile runtime keeps the phone shell under a desktop theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ClientController(
      portableData: _testPortableData(),
      presentationPreferencesRepository:
          _TestPresentationPreferencesRepository(),
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _OAuthRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.scannedTargets = _targets;
    controller.scannedTargets = _targets;
    await controller.layoutManager.initialize().timeout(
      const Duration(seconds: 5),
    );

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 390,
          height: 844,
          child: ClientShell(controller: controller),
        ),
      ),
    );

    await tester.pump();
    expect(
      find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile-agent-list-item-codex')),
      findsOneWidget,
    );
  });

  testWidgets('mobile empty agent list opens the add agent sheet', (
    tester,
  ) async {
    final controller = ClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: Material(child: MobileAgentsHome(controller: controller)),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('No available agents found'), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-empty-add-agent-button')),
      findsOneWidget,
    );
    expect(find.text('Refresh Agents'), findsNothing);

    await tester.tap(find.byKey(const Key('mobile-empty-add-agent-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('mobile-agent-scan-qr-option')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile-agent-provider-chatgpt')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile-agent-provider-gemini')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile-agent-provider-deepseek')),
      findsOneWidget,
    );
  });

  testWidgets(
    'mobile provider detail manages sibling accounts with confirmed deletion',
    (tester) async {
      final controller = ClientController(
        portableData: _testPortableData(),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.mobileAgentAccounts = [
        MobileAgentAccount.create(
          mobileAgentProviderFor('deepseek'),
          id: 'deepseek-account-a',
          label: 'DeepSeek A',
          authSource: MobileAgentAccount.authSourceLocalApiKey,
          credentialPresent: true,
          credentialHint: '**** 0001',
          active: true,
        ),
        MobileAgentAccount.create(
          mobileAgentProviderFor('deepseek'),
          id: 'deepseek-account-b',
          label: 'DeepSeek B',
          authSource: MobileAgentAccount.authSourceLocalApiKey,
          credentialPresent: true,
          credentialHint: '**** 0002',
        ),
        MobileAgentAccount.create(
          mobileAgentProviderFor('chatgpt'),
          id: 'chatgpt-account-a',
          label: 'ChatGPT A',
          authSource: MobileAgentAccount.authSourceLocalOAuth,
          authKind: MobileAgentAuthKind.oauthPkce,
          credentialPresent: true,
          credentialHint: 'OAuth',
          active: true,
        ),
        MobileAgentAccount.create(
          mobileAgentProviderFor('chatgpt'),
          id: 'chatgpt-account-b',
          label: 'ChatGPT B',
          authSource: MobileAgentAccount.authSourceLocalOAuth,
          authKind: MobileAgentAuthKind.oauthPkce,
          credentialPresent: true,
          credentialHint: 'OAuth',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: Material(child: MobileAgentsHome(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('2 accounts'), findsNWidgets(4));
      await tester.tap(
        find.byKey(const Key('mobile-remote-agent-deepseek-account-a')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('mobile-provider-settings-deepseek-account-a')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('mobile-remote-agent-account-row-deepseek-account-a'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('mobile-remote-agent-account-row-deepseek-account-b'),
        ),
        findsOneWidget,
      );
      final refreshAccount = find.byKey(
        const Key('mobile-remote-agent-refresh-deepseek-account-a'),
      );
      await tester.scrollUntilVisible(
        refreshAccount,
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(refreshAccount, findsOneWidget);
      final deleteAccountA = find.byKey(
        const Key('mobile-remote-agent-delete-deepseek-account-a'),
      );
      await tester.scrollUntilVisible(
        deleteAccountA,
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(deleteAccountA, findsOneWidget);

      final accountRowB = find.byKey(
        const Key('mobile-remote-agent-account-row-deepseek-account-b'),
      );
      await tester.scrollUntilVisible(
        accountRowB,
        -180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(accountRowB);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('mobile-remote-agent-set-active-deepseek-account-b'),
        ),
        findsOneWidget,
      );
      final deleteAccountB = find.byKey(
        const Key('mobile-remote-agent-delete-deepseek-account-b'),
      );
      await tester.scrollUntilVisible(
        deleteAccountB,
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(deleteAccountB);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('mobile-remote-agent-confirm-delete')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('mobile-remote-agent-cancel-delete')),
      );
      await tester.pumpAndSettle();
      expect(
        controller.mobileAgentAccounts.any(
          (account) => account.id == 'deepseek-account-b',
        ),
        isTrue,
      );
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform uses the focused mobile agent shell', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-mobile-shell-',
      );
      addTearDown(() async {
        if (await dataDirectory.exists()) {
          await dataDirectory.delete(recursive: true);
        }
      });
      final relayService = _OAuthRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: _targets),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) {
          controller.dispose();
        }
      });
      controller.currentSection = ClientSection.agents;
      controller.scannedTargets = _targets;
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'codex-latest',
            agentId: 'codex',
            title: 'Latest Codex session',
            createdAt: '2026-07-01T10:00:00Z',
            updatedAt: '2026-07-02T08:30:00Z',
            messages: const [
              AgentConversationMessage(
                id: 'codex-message-latest',
                role: 'assistant',
                text: 'Latest Codex response from relay',
                createdAt: '2026-07-02T08:30:00Z',
              ),
            ],
          ),
        ],
      };
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        pcClientName: 'Lico Arc',
        pairingId: 'pairing_test',
        mobileTokenPresent: true,
        paired: true,
      );
      final pairedDeviceKey = Key(
        'mobile-paired-device-${controller.mobileRelayConfig.deviceTabs.single.id}',
      );
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: platform),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );

      await tester.pump();
      expect(find.byTooltip('Refresh Agents'), findsNothing);
      expect(find.byTooltip('Add Agent'), findsOneWidget);
      expect(find.byTooltip('Runtime'), findsNothing);
      expect(find.byTooltip('Skill Hub'), findsNothing);
      expect(find.byTooltip('Token Usage'), findsNothing);
      expect(
        find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-agent-list-item-codex')),
        findsNothing,
      );
      expect(find.byKey(pairedDeviceKey), findsOneWidget);
      expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
      expect(
        find.byKey(const Key('mobile-home-pin-target:codex')),
        findsNothing,
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
      expect(find.byIcon(Icons.qr_code_rounded), findsNothing);
      expect(find.byIcon(Icons.qr_code_2_outlined), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner_outlined), findsNothing);
      expect(find.text('Arc Desktop'), findsOneWidget);
      expect(find.text('Codex'), findsNothing);
      expect(find.text('Latest Codex response from relay'), findsNothing);
      expect(find.textContaining('2026'), findsNothing);
      expect(find.text('Add target'), findsNothing);
      expect(find.text('Unpaired Device'), findsNothing);
      expect(find.text('Runtime'), findsNothing);
      expect(find.text('Skill Hub'), findsNothing);
      final reorderableList = tester.widget<SliverReorderableList>(
        find.byType(SliverReorderableList),
      );
      reorderableList.onReorderItem?.call(1, 0);
      await tester.pumpAndSettle();

      expect(controller.mobileHomeLayout.order, isEmpty);

      await tester.drag(find.byKey(pairedDeviceKey), const Offset(-180, 0));
      await tester.pumpAndSettle();

      expect(
        controller.mobileHomeLayout.pinnedEntryIds,
        isNot(
          contains(
            'device:${controller.mobileRelayConfig.deviceTabs.single.id}',
          ),
        ),
      );
      final pinButton = find.byKey(
        Key(
          'mobile-home-pin-device:${controller.mobileRelayConfig.deviceTabs.single.id}',
        ),
      );
      expect(pinButton, findsOneWidget);
      expect(
        tester.getCenter(pinButton).dx,
        greaterThan(tester.getCenter(find.byKey(pairedDeviceKey)).dx),
      );

      await tester.tap(pinButton);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 50 &&
              !controller.mobileHomeLayout.pinnedEntryIds.contains(
                'device:${controller.mobileRelayConfig.deviceTabs.single.id}',
              );
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(
        controller.mobileHomeLayout.pinnedEntryIds,
        contains('device:${controller.mobileRelayConfig.deviceTabs.single.id}'),
      );
      expect(find.byType(ReorderableDelayedDragStartListener), findsOneWidget);
      expect(find.text('Pinned · Not configured · cli'), findsNothing);
      expect(find.text('Latest Codex response from relay'), findsNothing);

      await tester.tap(find.byKey(pairedDeviceKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('mobile-desktop-agent-codex')),
        findsOneWidget,
      );
      expect(find.text('Codex'), findsOneWidget);

      await tester.tap(find.byKey(const Key('mobile-desktop-agent-codex')));
      await tester.pumpAndSettle();

      expect(find.text('Latest Codex response from relay'), findsOneWidget);

      await _selectAgentsFromLayout(tester);

      await tester.tap(find.byKey(const Key('mobile-add-agent-button')));
      await tester.pumpAndSettle();

      expect(find.text('Add Agent'), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-agent-scan-qr-option')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-agent-provider-chatgpt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-agent-provider-gemini')),
        findsOneWidget,
      );
      expect(
        find.text('Configure API Key / Google OAuth Authorization'),
        findsNothing,
      );
      expect(find.text('Configure API Key'), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-agent-provider-kimi')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-agent-provider-deepseek')),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const Key('mobile-agent-scan-qr-option')))
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const Key('mobile-agent-provider-chatgpt')),
              )
              .dy,
        ),
      );
      expect(find.byType(ProviderBrandIcon), findsNWidgets(4));
      expect(find.byIcon(Icons.auto_awesome_rounded), findsNothing);
      expect(find.byIcon(Icons.diamond_outlined), findsNothing);
      expect(find.byIcon(Icons.nights_stay_outlined), findsNothing);
      expect(find.byIcon(Icons.bubble_chart_outlined), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.runAsync(() => controller.addMobileAgentProvider('chatgpt'));
      await tester.pump();

      final chatgptAccountId = controller.mobileAgentAccounts
          .firstWhere((account) => account.providerId == 'chatgpt')
          .id;
      expect(
        find.byKey(Key('mobile-remote-agent-$chatgptAccountId')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(Key('mobile-remote-agent-$chatgptAccountId')),
      );
      await tester.pump();

      expect(
        find.byKey(Key('mobile-provider-new-conversation-$chatgptAccountId')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('mobile-provider-settings-$chatgptAccountId')),
        findsOneWidget,
      );

      await tester.runAsync(
        () => controller.authorizeMobileAgentOAuth(
          'chatgpt',
          mobileAccountId: chatgptAccountId,
        ),
      );
      await tester.pump();

      expect(relayService.loginOAuthCalls, 1);
      expect(controller.mobileAgentAccounts.single.credentialPresent, isTrue);
      expect(controller.mobileAgentAccounts.single.credentialHint, 'OAuth');
      final authorizedAccountId = controller.mobileAgentAccounts.single.id;
      expect(
        find.byKey(Key('mobile-remote-agent-api-key-$authorizedAccountId')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          Key('mobile-provider-new-conversation-$authorizedAccountId'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('mobile-remote-agent-composer-$authorizedAccountId')),
        findsOneWidget,
      );
      expect(find.text('Connected'), findsWidgets);
      expect(
        find.text(
          'ChatGPT OAuth authorized. This phone can use ChatGPT web conversation directly.',
        ),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('mobile-remote-agent-open-configuration')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('mobile-remote-agent-model-$authorizedAccountId')),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('mobile-remote-agent-reasoning-$authorizedAccountId')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(Key('mobile-remote-agent-model-$authorizedAccountId')),
      );
      await tester.tap(
        find.byKey(Key('mobile-remote-agent-model-$authorizedAccountId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT-5.4 Mini').last);
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          if (controller.mobileAgentAccounts.single.selectedModel ==
              'gpt-5.4-mini') {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(Key('mobile-remote-agent-reasoning-$authorizedAccountId')),
      );
      await tester.tap(
        find.byKey(Key('mobile-remote-agent-reasoning-$authorizedAccountId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          if (controller.mobileAgentAccounts.single.reasoningEffort == 'high') {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      final configuredAccount = controller.mobileAgentAccounts.single;
      expect(configuredAccount.selectedModel, 'gpt-5.4-mini');
      expect(configuredAccount.reasoningEffort, 'high');

      await tester.dragFrom(const Offset(80, 420), const Offset(210, 0));
      await tester.pump();

      expect(
        find.byKey(
          Key('mobile-provider-new-conversation-$authorizedAccountId'),
        ),
        findsOneWidget,
      );

      await tester.dragFrom(const Offset(80, 420), const Offset(210, 0));
      await tester.pump();

      expect(
        find.byKey(Key('mobile-remote-agent-$authorizedAccountId')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(pairedDeviceKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mobile-desktop-agent-codex')));
      await tester.pumpAndSettle();

      expect(controller.selectedConversationAgentId, 'codex');
      expect(
        find.byKey(const Key('mobile-agent-open-configuration')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsNothing);

      await tester.dragFrom(const Offset(330, 420), const Offset(-210, 0));
      await tester.pump();

      expect(find.text('Agent Configuration'), findsOneWidget);
      expect(find.text('Config path'), findsNothing);
      expect(find.byIcon(Icons.open_in_new_outlined), findsOneWidget);

      await tester.dragFrom(const Offset(80, 420), const Offset(210, 0));
      await tester.pump();

      expect(
        find.byKey(const Key('mobile-agent-open-configuration')),
        findsOneWidget,
      );

      await tester.dragFrom(const Offset(80, 420), const Offset(210, 0));
      await tester.pump();

      expect(
        find.byKey(const Key('mobile-desktop-agent-codex')),
        findsOneWidget,
      );
      controller.dispose();
      disposed = true;
    });
  }

  testWidgets('mobile uses provider authorization from paired computer', (
    tester,
  ) async {
    final controller = ClientController(
      portableData: _testPortableData(),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
      pcClientName: 'ARC Desktop',
      pairingId: 'pairing_desktop',
      mobileTokenPresent: true,
      paired: true,
      authorizedProviders: const [
        MobileRelayAuthorizedProvider(
          providerId: 'chatgpt',
          label: 'ChatGPT',
          credentialPresent: true,
          source: 'desktop-model-profile',
        ),
      ],
    );
    controller.syncMobileAgentAccountsWithDesktopRelay();

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: Material(child: MobileAgentsHome(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    final chatGptAccount = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    final chatGptKey = Key('mobile-remote-agent-${chatGptAccount.id}');
    expect(chatGptAccount.usesDesktopRelay, isTrue);
    expect(find.byKey(chatGptKey), findsNothing);
    expect(find.text('Available Through ARC Desktop'), findsNothing);
  });

  testWidgets('mobile synced DeepSeek API key is shown as locally authorized', (
    tester,
  ) async {
    final controller = ClientController(
      presentationPreferencesRepository:
          _TestPresentationPreferencesRepository(),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.mobileAgentAccounts = [
      MobileAgentAccount.create(
        mobileAgentProviderFor('deepseek'),
        id: 'mobile-synced:deepseek:deepseek-default',
        label: 'DeepSeek',
        authSource: MobileAgentAccount.authSourceMobileSynced,
        credentialPresent: true,
        credentialHint: '**** 4321',
        relayDeviceLabel: 'ARC Desktop',
        relayProfileId: 'deepseek-default',
      ),
    ];
    await controller.layoutManager.initialize();

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: ClientShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    const deepSeekKey = Key(
      'mobile-remote-agent-mobile-synced:deepseek:deepseek-default',
    );
    expect(find.byKey(deepSeekKey), findsOneWidget);
    expect(find.text('Synced From ARC Desktop To This Phone'), findsOneWidget);

    await tester.tap(find.byKey(deepSeekKey));
    await tester.pump();

    expect(
      find.byKey(
        const Key(
          'mobile-provider-new-conversation-mobile-synced:deepseek:deepseek-default',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'mobile-remote-agent-composer-mobile-synced:deepseek:deepseek-default',
        ),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(
        const Key(
          'mobile-provider-new-conversation-mobile-synced:deepseek:deepseek-default',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      controller.activeMobileProviderConversationsFor(
        controller.mobileAgentAccounts.single,
      ),
      hasLength(1),
    );

    expect(
      find.byKey(
        const Key(
          'mobile-remote-agent-composer-mobile-synced:deepseek:deepseek-default',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('Configure API Key'), findsNothing);
    expect(
      find.byKey(const Key('mobile-remote-agent-auth-deepseek')),
      findsNothing,
    );

    await tester.dragFrom(const Offset(330, 420), const Offset(-210, 0));
    await tester.pump();

    expect(find.text('Direct API Key'), findsOneWidget);
    expect(
      find.text(
        'Authorized. The API key has been synced from ARC Desktop to this phone.',
      ),
      findsOneWidget,
    );
    expect(find.text('Configure API Key'), findsNothing);
  });

  testWidgets('mobile provider conversation delete requires confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dataDirectory = Directory.systemTemp.createTempSync(
      'lico-mobile-delete-confirm-',
    );
    addTearDown(() => dataDirectory.deleteSync(recursive: true));
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    await tester.runAsync(() async {
      await controller.addMobileAgentProvider('deepseek');
      await controller.configureMobileAgentApiKey(
        providerId: 'deepseek',
        apiKey: ['test', 'deepseek', 'api', 'key', '4321'].join('-'),
      );
      await controller.startMobileProviderConversation(
        controller.mobileAgentAccounts.single,
      );
    });
    final account = controller.mobileAgentAccounts.single;
    final session = controller
        .activeMobileProviderConversationsFor(account)
        .single
        .session;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: Material(child: MobileAgentsHome(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    final accountTile = find.byKey(Key('mobile-remote-agent-${account.id}'));
    expect(accountTile, findsOneWidget);
    tester
        .widget<InkWell>(
          find.descendant(of: accountTile, matching: find.byType(InkWell)),
        )
        .onTap
        ?.call();
    await tester.pumpAndSettle();

    final sessionTile = find.byKey(
      Key('mobile-provider-session-open-${session.id}'),
    );
    expect(sessionTile, findsOneWidget);
    await tester.drag(sessionTile, const Offset(-210, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-provider-session-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this conversation?'), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-provider-confirm-delete-conversation')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(
      controller.activeMobileProviderConversationsFor(account),
      hasLength(1),
    );
    expect(controller.trashedMobileProviderConversationsFor(account), isEmpty);

    await tester.drag(sessionTile, const Offset(-210, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-provider-session-delete')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile-provider-confirm-delete-conversation')),
    );
    await tester.pumpAndSettle();

    expect(controller.activeMobileProviderConversationsFor(account), isEmpty);
    expect(
      controller
          .trashedMobileProviderConversationsFor(account)
          .single
          .session
          .id,
      session.id,
    );
  });

  testWidgets(
    'mobile synced Gemini account stays relay-shaped without local OAuth',
    (tester) async {
      final relayService = _OAuthRelayService();
      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      controller.mobileAgentAccounts = [
        MobileAgentAccount.create(
          mobileAgentProviderFor('gemini'),
          id: 'mobile-synced:gemini:gemini-oauth',
          label: 'Gemini',
          authSource: MobileAgentAccount.authSourceMobileSynced,
          credentialPresent: true,
          credentialHint: 'OAuth',
          relayDeviceLabel: 'ARC Desktop',
          relayProfileId: 'gemini-oauth',
        ),
      ];
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );
      await tester.pump();

      const geminiKey = Key(
        'mobile-remote-agent-mobile-synced:gemini:gemini-oauth',
      );
      expect(find.byKey(geminiKey), findsOneWidget);
      expect(
        find.textContaining('Synced From ARC Desktop To This Phone'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(geminiKey));
      await tester.pump();
      await tester.dragFrom(const Offset(330, 420), const Offset(-210, 0));
      await tester.pump();

      expect(find.text('Direct API Key'), findsNothing);
      expect(find.text('Configure API Key'), findsNothing);
      expect(find.text('Google OAuth Authorization'), findsNothing);
      expect(
        find.byKey(const Key('mobile-remote-agent-paste-oauth-gemini')),
        findsNothing,
      );
      expect(relayService.loginOAuthCalls, 0);
      expect(relayService.credentialSyncCalls, 0);
    },
  );

  testWidgets('mobile OAuth chat failure prompts reauthorization', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dataDirectory = Directory.systemTemp.createTempSync(
      'lico-mobile-oauth-recovery-chatgpt-',
    );
    addTearDown(() => dataDirectory.deleteSync(recursive: true));
    final relayService = _OAuthRelayService()
      ..localProviderStatusCodeQueue = [0, 403]
      ..localProviderProxyMode = 'android-system-proxy';
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: Material(child: MobileAgentsHome(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    await tester.runAsync(() async {
      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');
    });
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: MobileAgentsHome(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final account = controller.mobileAgentAccounts.firstWhere(
      (account) => account.providerId == 'chatgpt' && account.usesLocalOAuth,
    );
    final accountTile = find.byKey(Key('mobile-remote-agent-${account.id}'));
    await tester.scrollUntilVisible(accountTile, 160);
    tester
        .widget<InkWell>(
          find.descendant(of: accountTile, matching: find.byType(InkWell)),
        )
        .onTap
        ?.call();
    await tester.pump();
    final newConversationButton = find.byKey(
      Key('mobile-provider-new-conversation-${account.id}'),
    );
    expect(newConversationButton, findsOneWidget);
    tester.widget<IconButton>(newConversationButton).onPressed?.call();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => controller.sendMobileProviderMessage(account: account, text: 'hi'),
    );
    await tester.pumpAndSettle();

    expect(relayService.localProviderMessageCalls, 2);
    final messages =
        controller.mobileProviderConversationFor(account)?.messages ?? const [];
    expect(messages.map((message) => message.role), ['user']);
    expect(messages.last.text, 'hi');
    expect(find.text('Authorization Verification Failed'), findsOneWidget);
    expect(
      find.byKey(Key('mobile-remote-agent-oauth-recovery-${account.id}')),
      findsOneWidget,
    );

    final recoveryButton = find.byKey(
      Key('mobile-remote-agent-oauth-recovery-${account.id}'),
    );
    final reauthorize = tester.widget<FilledButton>(recoveryButton).onPressed;
    expect(reauthorize, isNotNull);
    await tester.runAsync(() async {
      reauthorize?.call();
      for (var attempt = 0; attempt < 20; attempt++) {
        if (relayService.loginOAuthCalls >= 2) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 100));

    expect(relayService.loginOAuthCalls, 2);
    expect(
      relayService.loginOAuthMobileAccountIds.last,
      startsWith('mpa-chatgpt-'),
    );
  });

  testWidgets(
    'mobile synced DeepSeek API key chat failure does not prompt OAuth',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-mobile-deepseek-api-key-failure-',
      );
      addTearDown(() => dataDirectory.deleteSync(recursive: true));
      final relayService = _OAuthRelayService()
        ..localProviderStatusCode = 401
        ..localProviderProxyMode = 'android-system-proxy';
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'ARC Desktop',
        mobileToken: 'mobile-token',
        mobileTokenPresent: true,
        paired: true,
        relayEnabled: true,
        authorizedProviders: const [
          MobileRelayAuthorizedProvider(
            providerId: 'deepseek',
            label: 'DeepSeek',
            credentialPresent: true,
            profileId: 'deepseek',
            credentialKind: 'api-key',
            source: 'desktop-model-profile',
          ),
        ],
      );
      controller.mobileAgentAccounts = [
        MobileAgentAccount.create(
          mobileAgentProviderFor('deepseek'),
          id: 'mobile-synced:deepseek:deepseek',
          label: 'DeepSeek',
          authSource: MobileAgentAccount.authSourceMobileSynced,
          credentialPresent: true,
          credentialHint: '**** 1234',
          relayDeviceLabel: 'ARC Desktop',
          relayProfileId: 'deepseek',
        ),
      ];
      controller.syncMobileAgentAccountsWithDesktopRelay();
      expect(
        controller.mobileAgentAccounts.any(
          (account) =>
              account.providerId == 'deepseek' &&
              account.usesDesktopRelay &&
              account.relayProfileId == 'deepseek',
        ),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: Material(child: MobileAgentsHome(controller: controller)),
          ),
        ),
      );
      await tester.pump();

      final account = controller.mobileAgentAccounts.firstWhere(
        (account) =>
            account.providerId == 'deepseek' && account.usesMobileSynced,
      );
      final accountTile = find.byKey(Key('mobile-remote-agent-${account.id}'));
      expect(accountTile, findsOneWidget);
      tester
          .widget<InkWell>(
            find.descendant(of: accountTile, matching: find.byType(InkWell)),
          )
          .onTap
          ?.call();
      await tester.pump();
      final newConversationButton = find.byKey(
        Key('mobile-provider-new-conversation-${account.id}'),
      );
      expect(newConversationButton, findsOneWidget);
      tester.widget<IconButton>(newConversationButton).onPressed?.call();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      await tester.runAsync(
        () =>
            controller.sendMobileProviderMessage(account: account, text: 'hi'),
      );
      await tester.pumpAndSettle();

      expect(relayService.localProviderMessageCalls, 1);
      expect(
        controller.mobileProviderConversationFor(account)?.messages.last.text,
        'oauth_chat_failed (401, proxy: android-system-proxy)',
      );
      expect(
        controller.mobileAgentAccounts.any(
          (account) =>
              account.providerId == 'deepseek' &&
              account.usesDesktopRelay &&
              account.relayProfileId == 'deepseek',
        ),
        isTrue,
      );
      expect(find.text('OAuth Authorization Needs Refresh'), findsNothing);
      expect(find.text('Refresh Synced Authorization'), findsNothing);
      expect(find.text('Reauthorize'), findsNothing);
      expect(
        find.byKey(Key('mobile-remote-agent-oauth-recovery-${account.id}')),
        findsNothing,
      );
      expect(relayService.loginOAuthCalls, 0);
      expect(relayService.credentialSyncCalls, 0);
    },
  );

  testWidgets(
    'mobile OAuth prompt shows waiting until status polling succeeds',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-mobile-oauth-waiting-',
      );
      addTearDown(() => dataDirectory.deleteSync(recursive: true));
      final loginCompleter = Completer<Map<String, dynamic>>();
      final relayService = _OAuthRelayService()
        ..oauthStatusCredentialPresent = false
        ..loginOAuthCompleter = loginCompleter;
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      controller.mobileAgentAccounts = [
        MobileAgentAccount.create(
          mobileAgentProviderFor('chatgpt'),
          id: 'chatgpt-oauth-local',
          label: 'ChatGPT',
          authSource: MobileAgentAccount.authSourceLocalOAuth,
          credentialPresent: true,
          credentialHint: 'OAuth',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: Material(child: MobileAgentsHome(controller: controller)),
          ),
        ),
      );
      await tester.pump();

      const accountId = 'chatgpt-oauth-local';
      final accountTile = find.byKey(Key('mobile-remote-agent-$accountId'));
      expect(accountTile, findsOneWidget);
      tester
          .widget<InkWell>(
            find.descendant(of: accountTile, matching: find.byType(InkWell)),
          )
          .onTap
          ?.call();
      await tester.pump();
      final newConversationButton = find.byKey(
        Key('mobile-provider-new-conversation-$accountId'),
      );
      expect(newConversationButton, findsOneWidget);
      tester.widget<IconButton>(newConversationButton).onPressed?.call();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      late Future<void> authFuture;
      await tester.runAsync(() async {
        authFuture = controller.authorizeMobileAgentOAuth(
          'chatgpt',
          mobileAccountId: accountId,
        );
        for (var attempt = 0; attempt < 20; attempt++) {
          if (relayService.loginOAuthCalls >= 1) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(relayService.loginOAuthCalls, 1);
      final waitingAccount = controller.mobileAgentAccounts.firstWhere(
        (account) => account.id == accountId,
      );
      expect(controller.mobileAgentOAuthAuthorizationPrompts, isNotEmpty);
      expect(
        controller
            .mobileAgentOAuthAuthorizationPromptFor(waitingAccount)
            ?.isWaiting,
        isTrue,
      );
      expect(find.text('Waiting For Web Authorization'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final waitingButton = find.byKey(
        Key('mobile-remote-agent-oauth-recovery-$accountId'),
      );
      expect(tester.widget<FilledButton>(waitingButton).onPressed, isNull);

      relayService.oauthStatusCredentialPresent = true;
      await tester.runAsync(
        () => controller.refreshPendingMobileAgentOAuthAuthorizations(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Authorization Successful'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(waitingButton).onPressed, isNotNull);
      expect(find.text('Close'), findsOneWidget);
      final closeButton = find.byKey(
        Key('mobile-remote-agent-oauth-recovery-close-$accountId'),
      );
      expect(closeButton, findsOneWidget);
      tester.widget<IconButton>(closeButton).onPressed?.call();
      await tester.pumpAndSettle();

      expect(find.text('Authorization Successful'), findsNothing);
      expect(
        controller
            .mobileAgentOAuthAuthorizationPromptFor(
              controller.mobileAgentAccounts.firstWhere(
                (account) => account.id == accountId,
              ),
            )
            ?.isDismissed,
        isTrue,
      );

      loginCompleter.complete({
        'ok': true,
        'providerId': 'chatgpt',
        'mobileAccountId': accountId,
        'credentialPresent': true,
        'credentialKind': 'oauth-pkce',
        'credentialHint': 'OAuth',
      });
      await tester.runAsync(() => authFuture);
      await tester.pumpAndSettle();

      expect(relayService.localProviderMessageCalls, 1);
      expect(find.text('Authorization Successful'), findsNothing);
      final backButton = find.ancestor(
        of: find.byIcon(Icons.chevron_left_rounded),
        matching: find.byType(IconButton),
      );
      expect(backButton, findsOneWidget);
      tester.widget<IconButton>(backButton).onPressed?.call();
      await tester.pumpAndSettle();
      expect(newConversationButton, findsOneWidget);
      tester.widget<IconButton>(newConversationButton).onPressed?.call();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('Authorization Successful'), findsNothing);
    },
  );

  testWidgets(
    'mobile Arc Desktop agent conversation sends through paired computer',
    (tester) async {
      final relayService = _ProviderChatRelayService();
      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: _targets),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        pcClientName: 'ARC Desktop',
        pairingId: 'pairing_desktop',
        mobileTokenPresent: true,
        paired: true,
      );
      controller.scannedTargets = _targets;
      controller.selectedConversationAgentId = 'codex';
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );
      await tester.pump();

      final pairedDeviceKey = Key(
        'mobile-paired-device-${controller.mobileRelayConfig.deviceTabs.single.id}',
      );

      await tester.tap(find.byKey(pairedDeviceKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('mobile-desktop-agent-codex')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('mobile-desktop-agent-codex')));
      await tester.pumpAndSettle();

      expect(controller.mobileClientRuntimePlatform, isTrue);
      expect(controller.selectedConversationAgentId, 'codex');
      expect(controller.lastError, isEmpty);
      final composer = find.widgetWithText(TextField, 'Message Codex');
      expect(composer, findsOneWidget);

      await tester.enterText(composer, 'hello');
      await tester.pump();
      final sendButton = find.byKey(
        const Key('agent-conversation-composer-send'),
      );
      expect(sendButton, findsOneWidget);
      expect(tester.widget<InkWell>(sendButton).onTap, isNotNull);
      await tester.tap(sendButton);
      await tester.pumpAndSettle();

      expect(
        relayService.agentMessageCalls,
        1,
        reason: 'send status=${controller.lastError}',
      );
      expect(relayService.lastAgentId, 'codex');
      expect(relayService.lastAgentText, 'hello');
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Codex relay reply'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile home keeps profile navigation without manual target entry',
    (tester) async {
      final controller = ClientController(
        portableData: _testPortableData(),
        presentationPreferencesRepository:
            _TestPresentationPreferencesRepository(),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = ClientSection.agents;
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: SizedBox(
            width: 390,
            height: 844,
            child: ClientShell(controller: controller),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workbench-mobile-medium-contextual-navigation')),
        findsOneWidget,
      );
      expect(find.byTooltip('Pair Device'), findsNothing);
      expect(find.text('No available agents found'), findsOneWidget);
      expect(find.text('Add target'), findsNothing);
    },
  );

  testWidgets('pair device dialog fits above the soft keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewInsets: EdgeInsets.only(bottom: 360),
          ),
          child: SizedBox(
            width: 390,
            height: 844,
            child: PairDeviceDialog(
              scannerPreviewOverride: const ColoredBox(color: Colors.black),
              onClaim: (_) async {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('配对设备'), findsOneWidget);
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('pair device dialog automatically claims detected QR capture', (
    tester,
  ) async {
    const invite = 'licoarc://pair?invite=test-token';
    final claims = <String>[];
    final claimGate = Completer<void>();
    late Future<void> Function(BarcodeCapture capture) submitCapture;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: PairDeviceDialog(
            scannerPreviewBuilder: (context, onDetect) {
              submitCapture = onDetect;
              return const ColoredBox(color: Colors.black);
            },
            onClaim: (value) async {
              claims.add(value);
              await claimGate.future;
            },
          ),
        ),
      ),
    );

    await tester.pump();
    final detectFuture = submitCapture(
      const BarcodeCapture(
        barcodes: [Barcode(format: BarcodeFormat.qrCode, rawValue: invite)],
      ),
    );
    await tester.pump();

    expect(claims, [invite]);
    expect(find.text('已识别二维码，正在配对...'), findsOneWidget);

    claimGate.complete();
    await tester.pump(const Duration(milliseconds: 360));
    await detectFuture;
    await tester.pump();

    expect(find.text('扫描成功，设备已配对。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reselecting the agents destination returns to the home list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ClientController(
      portableData: _testPortableData(),
      presentationPreferencesRepository:
          _TestPresentationPreferencesRepository(),
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _OAuthRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;
    controller.scannedTargets = _targets;
    controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
      pcClientName: 'Lico Arc',
      pairingId: 'pairing_test',
      mobileTokenPresent: true,
      paired: true,
    );
    final pairedDeviceKey = Key(
      'mobile-paired-device-${controller.mobileRelayConfig.deviceTabs.single.id}',
    );
    await controller.layoutManager.initialize();

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: SizedBox(
          width: 390,
          height: 844,
          child: ClientShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(pairedDeviceKey), findsOneWidget);
    expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsNothing);

    await tester.tap(find.byKey(pairedDeviceKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsOneWidget);

    expect(
      find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
      findsOneWidget,
    );
  });
}

Future<void> _selectAgentsFromLayout(WidgetTester tester) async {
  final mediumItem = find.byKey(
    const Key('workbench-mobile-medium-navigation-agents'),
  );
  if (mediumItem.evaluate().isNotEmpty) {
    await tester.tap(mediumItem);
    await tester.pumpAndSettle();
    return;
  }
  await tester.tap(
    find.byKey(const Key('workbench-mobile-compact-navigation-trigger')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const Key('workbench-mobile-compact-navigation-agents')),
  );
  await tester.pumpAndSettle();
}

PortableDataRoot _testPortableData() {
  final directory = Directory.systemTemp.createTempSync(
    'lico-client-shell-layout-',
  );
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  return PortableDataRoot(dataDirectoryOverride: directory);
}

final class _TestPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences _preferences = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('workbench'),
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences = _preferences.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      _preferences = _preferences.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences = _preferences.copyWith(localePreference: preference);
}

final List<TargetCandidate> _targets = [
  TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.72,
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationReadiness': 'ready'},
    supportedActions: ['runtime.message.send'],
  ),
];

class _NoopAgentService extends AgentService {
  _NoopAgentService({this.scanTargetsResponse = const []})
    : super(runCliExecutable: null);

  final List<TargetCandidate> scanTargetsResponse;
  int agentUsageScanCalls = 0;

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    return scanTargetsResponse;
  }

  @override
  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    final id = targetId.trim();
    for (final target in scanTargetsResponse) {
      if (target.target == id) {
        return target;
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> stopOpencodeServe() async {
    return const {'ok': true, 'status': 'stopped'};
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      agentUsageScanCalls++;
      final agentArgIndex = args.indexOf('--agent');
      final agentId = agentArgIndex >= 0 && agentArgIndex + 1 < args.length
          ? args[agentArgIndex + 1]
          : 'codex';
      final allowanceKind = agentId == 'claude-code'
          ? 'claude-weekly-limit'
          : 'chatgpt-weekly-limit';
      final allowanceLabel = agentId == 'claude-code'
          ? 'Claude weekly limit'
          : 'ChatGPT weekly limit';
      final provider = agentId == 'claude-code'
          ? 'Claude'
          : agentId == 'kilo-code'
          ? 'Kilo'
          : 'ChatGPT';
      final allowances = agentId == 'codex'
          ? const [
              {
                'kind': 'chatgpt-session-limit',
                'label': 'ChatGPT session limit',
                'provider': 'ChatGPT',
                'period': 'session',
                'status': 'available',
                'value': '98%',
                'unit': '',
                'source': 'codex-oauth:system',
                'message': 'ChatGPT quota window · resets in 4h 48m',
              },
              {
                'kind': 'chatgpt-weekly-limit',
                'label': 'ChatGPT weekly limit',
                'provider': 'ChatGPT',
                'period': 'week',
                'status': 'available',
                'value': '73%',
                'unit': '',
                'source': 'codex-oauth:system',
                'message': 'ChatGPT quota window · resets in 5d 1h',
              },
              {
                'kind': 'chatgpt-limit-reset-credits',
                'label': 'ChatGPT limit reset credits',
                'provider': 'ChatGPT',
                'period': 'reset-credits',
                'status': 'available',
                'value': '1 available',
                'unit': '',
                'source': 'codex-oauth:system',
                'message': 'ChatGPT limit reset credits.',
              },
              {
                'kind': 'gpt-5-3-codex-spark-session-limit',
                'label': 'GPT-5.3-Codex-Spark session limit',
                'provider': 'GPT-5.3-Codex-Spark',
                'period': 'session',
                'status': 'available',
                'value': '100%',
                'unit': '',
                'source': 'codex-oauth:system',
                'message': 'GPT-5.3-Codex-Spark quota window · resets in 5h',
              },
              {
                'kind': 'gpt-5-3-codex-spark-weekly-limit',
                'label': 'GPT-5.3-Codex-Spark weekly limit',
                'provider': 'GPT-5.3-Codex-Spark',
                'period': 'week',
                'status': 'available',
                'value': '100%',
                'unit': '',
                'source': 'codex-oauth:system',
                'message': 'GPT-5.3-Codex-Spark quota window · resets in 7d',
              },
            ]
          : agentId == 'kilo-code'
          ? const [
              {
                'kind': 'kilo-pass-limit',
                'label': 'Kilo Pass',
                'provider': 'Kilo Pass',
                'period': 'month',
                'status': 'available',
                'value': '75%',
                'unit': '',
                'source': 'direct-provider:kilo',
                'message': 'Kilo Pass · \$5.00 / \$20.00.',
              },
              {
                'kind': 'kilo-recharge-credits',
                'label': 'Recharge credits',
                'provider': 'Kilo',
                'period': 'balance',
                'status': 'available',
                'value': '12.50',
                'unit': 'credits',
                'source': 'direct-provider:kilo',
                'message': 'Kilo recharge credits · 12.50 / 20.00 credits.',
              },
            ]
          : [
              {
                'kind': allowanceKind,
                'label': allowanceLabel,
                'provider': provider,
                'period': 'week',
                'status': 'available',
                'value': '73%',
                'unit': '',
                'source': 'direct-provider:test',
                'message': '$provider quota window.',
              },
            ];
      return {
        'schemaVersion': AgentUsageReport.currentSchemaVersion,
        'ok': true,
        'generatedAt': '2026-07-02T00:00:00Z',
        'summary': {
          'agentCount': 1,
          'totalTokens': 84,
          'meteredTotalBytes': 2048,
          'estimatedHistoricalBytes': 4096,
          'attribution': 'mixed',
          'confidence': 'medium',
        },
        'agents': [
          {
            'agentId': agentId,
            'label': provider,
            'status': 'detected',
            'history': {
              'sessionCount': 2,
              'messageCount': 8,
              'totalTokens': 84,
            },
            'traffic': {
              'meteredTotalBytes': 2048,
              'estimatedHistoricalBytes': 4096,
              'attribution': 'mixed',
            },
            'allowances': allowances,
            'confidence': 'medium',
          },
        ],
      };
    }
    return {'ok': true};
  }
}

class _NoopConversationService extends AgentConversationService {
  const _NoopConversationService();

  @override
  Stream<AgentConversationSession> streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) {
    return const Stream.empty();
  }

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) async {
    return const [];
  }

  @override
  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) async {
    return const AgentDispatchTurnResult(
      ok: true,
      sessionId: 'noop-session',
      raw: <String, dynamic>{'ok': true},
    );
  }
}

class _ProviderChatRelayService extends MobileRelayService {
  int providerMessageCalls = 0;
  int agentMessageCalls = 0;
  String lastProviderId = '';
  String lastAgentId = '';
  String lastAgentText = '';

  @override
  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': const <Map<String, dynamic>>[],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': const <Map<String, dynamic>>[],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    agentMessageCalls++;
    lastAgentId = agentId;
    lastAgentText = text;
    final nativeSessionId = sessionId.trim().isNotEmpty
        ? sessionId.trim()
        : 'native-$agentId-relay';
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': true,
                'adapterId': agentId,
                'nativeSessionId': nativeSessionId,
                'threadId': nativeSessionId,
                'sessionId': nativeSessionId,
                'effective': {
                  'model': model.isEmpty ? null : model,
                  'reasoningEffort': reasoningEffort.isEmpty
                      ? null
                      : reasoningEffort,
                },
                'content': 'Codex relay reply',
                'output': 'Codex relay reply',
              },
            },
          },
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    providerMessageCalls++;
    lastProviderId = providerId;
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'provider.chat.send',
              'output': {
                'ok': true,
                'providerId': providerId,
                'content': 'DeepSeek relay reply',
                'output': 'DeepSeek relay reply',
              },
            },
          },
        },
      },
    };
  }
}

class _OAuthRelayService extends MobileRelayService {
  int loginOAuthCalls = 0;
  int credentialSyncCalls = 0;
  int localProviderMessageCalls = 0;
  int oauthStatusCalls = 0;
  int? localProviderStatusCode;
  List<int> localProviderStatusCodeQueue = const [];
  bool oauthStatusCredentialPresent = true;
  String localProviderProxyMode = 'direct';
  Completer<Map<String, dynamic>>? loginOAuthCompleter;
  final List<String> loginOAuthMobileAccountIds = [];
  final List<String> credentialSyncMobileAccountIds = [];
  final List<String> credentialSyncProfileIds = [];

  @override
  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': [
        {
          'id': '$agentId-latest',
          'nativeSessionId': '$agentId-native-latest',
          'agentId': agentId,
          'adapterId': agentId,
          'native': true,
          'readOnly': true,
          'title': 'Latest agent session',
          'createdAt': '2026-07-01T10:00:00Z',
          'updatedAt': '2026-07-02T08:30:00Z',
          'messages': [
            {
              'id': '$agentId-message-latest',
              'role': 'assistant',
              'text': 'Latest Codex response from relay',
              'createdAt': '2026-07-02T08:30:00Z',
            },
          ],
        },
      ],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    return {'ok': false, 'errorCode': 'native_session_readback_missing'};
  }

  @override
  Future<Map<String, dynamic>> loginMobileProviderOAuth({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    loginOAuthCalls++;
    loginOAuthMobileAccountIds.add(mobileAccountId);
    final completer = loginOAuthCompleter;
    if (completer != null) {
      return completer.future;
    }
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
    };
  }

  @override
  Future<Map<String, dynamic>> mobileProviderOAuthStatus({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    oauthStatusCalls++;
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': oauthStatusCredentialPresent,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
      if (!oauthStatusCredentialPresent) 'status': 'oauth_credential_missing',
      'updatedAtEpochMillis': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  @override
  Future<Map<String, dynamic>> sendLocalProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    localProviderMessageCalls++;
    final queuedStatusCode = localProviderStatusCodeQueue.isNotEmpty
        ? localProviderStatusCodeQueue.removeAt(0)
        : 0;
    final statusCode = queuedStatusCode > 0
        ? queuedStatusCode
        : localProviderStatusCode;
    if (statusCode != null) {
      return {
        'ok': false,
        'providerId': providerId,
        'mobileAccountId': mobileAccountId,
        'status': 'oauth_chat_failed',
        'statusCode': statusCode,
        'proxyMode': localProviderProxyMode,
      };
    }
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'content': '$providerId phone reply',
      'output': '$providerId phone reply',
    };
  }

  @override
  Future<Map<String, dynamic>> syncMobileProviderCredentialFromRelay({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    credentialSyncCalls++;
    credentialSyncMobileAccountIds.add(mobileAccountId);
    credentialSyncProfileIds.add(profileId);
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialKind': 'api-key',
      'credentialHint': '**** 0000',
    };
  }
}
