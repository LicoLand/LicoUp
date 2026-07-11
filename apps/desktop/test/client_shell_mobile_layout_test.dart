import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/future_client_controller.dart';
import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/application/models/future_client_models.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/shell/client_shell.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:flutter_client/src/frontend/shared/ui/provider_brand_icon.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:flutter_client/src/frontend/shell/shell_navigation.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('desktop sidebar stays compact and exposes future modules', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.settings;
    controller.scannedTargets = _targets;

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
          width: 1200,
          height: 1000,
          child: ClientShell(controller: controller),
        ),
      ),
    );

    await tester.pump();

    expect(find.byType(ShellSidebar), findsOneWidget);
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(
      find.byKey(const Key('sidebar-control-panel-divider')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sidebar-control-panel-icon')), findsOneWidget);
    expect(find.byKey(const Key('topbar-lico-arc-logo')), findsNothing);
    expect(find.byKey(const Key('sidebar-agents-icon')), findsOneWidget);
    expect(find.byTooltip('Token Usage'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('sidebar-agents-icon'))).dx,
      closeTo(30, 0.5),
    );
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
    expect(find.byTooltip('Expand Sidebar'), findsNothing);
    expect(find.byTooltip('Collapse Sidebar'), findsNothing);
    expect(find.text('Appearance Preset'), findsOneWidget);
    expect(find.text('Lico Arc'), findsNothing);
    expect(find.text('Skill Hub'), findsNothing);

    await tester.tap(find.byTooltip('MCP Plugins'));
    await tester.pumpAndSettle();

    expect(controller.currentSection, FutureClientSection.mcpPlugins);
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.text('MCP Plugins'), findsNothing);
    expect(find.text('Skill Hub'), findsNothing);

    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();

    expect(controller.currentSection, FutureClientSection.controlPanel);
    expect(find.text('Home'), findsWidgets);
    expect(
      find.byKey(const Key('desktop-home-feed-compose-button')),
      findsOneWidget,
    );

    expect(find.byType(ShellGlobalSearch), findsOneWidget);
  });

  testWidgets('desktop shell exposes token usage as a report module', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _NoopAgentService(scanTargetsResponse: _targets);
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.settings;
    controller.scannedTargets = _targets;

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
          width: 1200,
          height: 900,
          child: ClientShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(service.agentUsageScanCalls, 0);
    expect(find.byTooltip('Token Usage'), findsOneWidget);

    await tester.tap(find.byTooltip('Token Usage'));
    await tester.pumpAndSettle();

    expect(controller.currentSection, FutureClientSection.monitoring);
    expect(find.byType(AgentUsagePanel), findsOneWidget);
    expect(service.agentUsageScanCalls, 1);
    final refresh = find.byKey(const Key('desktop-token-usage-refresh'));
    expect(refresh, findsOneWidget);
    expect(
      tester.getTopLeft(refresh).dx,
      lessThan(tester.getTopLeft(find.byType(ShellGlobalSearch)).dx),
    );

    await tester.tap(refresh);
    await tester.pumpAndSettle();

    expect(service.agentUsageScanCalls, 2);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('desktop-token-usage-refresh')), findsNothing);
  });

  testWidgets('desktop agents show allowance status in the bottom bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) {
        controller.dispose();
      }
    });
    controller.currentSection = FutureClientSection.agents;
    controller.scannedTargets = _targets;
    controller.selectedConversationAgentId = 'codex';

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
          width: 1200,
          height: 820,
          child: ClientShell(controller: controller),
        ),
      ),
    );

    await tester.pump();
    // The allowance refresh starts in a post-frame callback. Give the mocked
    // native scan future time to publish its authoritative values.
    await tester.runAsync(() => _waitForAgentAllowances(controller, 'codex'));
    await tester.pump();

    expect(find.textContaining('ChatGPT session limit'), findsNothing);
    expect(find.textContaining('ChatGPT weekly limit'), findsOneWidget);
    expect(find.textContaining('ChatGPT limit reset credits'), findsOneWidget);
    expect(
      find.byKey(
        const Key('agent-allowance-progress-track-ChatGPT weekly limit'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('usage percentage'), findsNothing);
    expect(find.byType(AgentConversationTabBar), findsOneWidget);
    expect(find.byKey(const Key('agent-usage-panel-toggle')), findsNothing);
    expect(find.text('Agent usage metering'), findsNothing);
    expect(find.byType(AgentUsagePanel), findsNothing);
    expect(controller.agentService, isA<_NoopAgentService>());
    expect(
      (controller.agentService as _NoopAgentService).agentUsageScanCalls,
      1,
    );
    final codexAllowances = controller.allowancesForAgent('codex');
    expect(codexAllowances.map((allowance) => allowance.kind), [
      'chatgpt-session-limit',
      'chatgpt-weekly-limit',
      'chatgpt-limit-reset-credits',
      'gpt-5-3-codex-spark-session-limit',
      'gpt-5-3-codex-spark-weekly-limit',
    ]);
    expect(codexAllowances[0].value, '98%');
    expect(codexAllowances[1].value, '73%');
    expect(codexAllowances[2].value, '1 available');
    final allowanceTooltip = tester.widget<Tooltip>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Tooltip &&
                (widget.message ?? '').contains('GPT-5.3-Codex-Spark'),
          )
          .first,
    );
    final tooltipMessage = allowanceTooltip.message ?? '';
    expect(tooltipMessage, contains('• ChatGPT · 73% left · resets in 5d 1h'));
    expect(
      tooltipMessage,
      contains('• GPT-5.3-Codex-Spark · 100% left · resets in 7d'),
    );
    expect(tooltipMessage, contains('• Reset credits · 1 available'));
    expect(tooltipMessage, isNot(contains('4h 48m')));
    expect(tooltipMessage, isNot(contains('resets in 5h')));

    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    expect(
      (controller.agentService as _NoopAgentService).agentUsageScanCalls,
      2,
    );

    expect(
      (controller.agentService as _NoopAgentService).agentUsageScanCalls,
      greaterThan(0),
    );
    expect(tester.getSize(find.byType(ShellStatusBar)).height, 30);
    controller.dispose();
    disposed = true;
  });

  testWidgets('kilo status shows pass progress and recharge credits as value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final targets = [
      TargetCandidate(
        target: 'kilo-code',
        label: 'Kilo Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
        adapterCapabilities: const {'conversationReadiness': 'ready'},
        supportedActions: ['runtime.message.send'],
      ),
    ];
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: targets),
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) {
        controller.dispose();
      }
    });
    controller.currentSection = FutureClientSection.agents;
    controller.scannedTargets = targets;
    controller.selectedConversationAgentId = 'kilo-code';

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
          width: 1200,
          height: 820,
          child: ClientShell(controller: controller),
        ),
      ),
    );

    await tester.pump();
    await tester.runAsync(
      () => _waitForAgentAllowances(controller, 'kilo-code'),
    );
    await tester.pump();

    expect(find.textContaining('Kilo Pass'), findsOneWidget);
    expect(find.textContaining('Recharge credits'), findsOneWidget);
    expect(
      find.byKey(const Key('agent-allowance-progress-track-Kilo Pass')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-allowance-progress-track-Recharge credits')),
      findsNothing,
    );
    final rechargeValue = tester.widget<Text>(
      find.byKey(const Key('agent-allowance-meter-value-Recharge credits')),
    );
    expect(rechargeValue.data, '12.50');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    disposed = true;
  });

  testWidgets('mobile runtime keeps the phone shell under a desktop theme', (
    tester,
  ) async {
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _OAuthRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
    controller.scannedTargets = _targets;
    controller.scannedTargets = _targets;

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

    expect(find.byType(ShellTopBar), findsNothing);
    expect(find.byType(ShellSidebar), findsNothing);
    expect(find.byType(AgentConversationTabBar), findsNothing);
    expect(find.byKey(const Key('mobile-bottom-nav-agents')), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-agent-list-item-codex')),
      findsOneWidget,
    );
  });

  testWidgets('mobile empty agent list opens the add agent sheet', (
    tester,
  ) async {
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;

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

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform uses the focused mobile agent shell', (
      tester,
    ) async {
      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-mobile-shell-',
      );
      addTearDown(() async {
        if (await dataDirectory.exists()) {
          await dataDirectory.delete(recursive: true);
        }
      });
      final relayService = _OAuthRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
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
      controller.currentSection = FutureClientSection.agents;
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

      expect(find.byType(ShellSidebar), findsNothing);
      expect(find.byType(ShellTopBar), findsNothing);
      expect(find.byType(AgentConversationTabBar), findsNothing);
      expect(find.byTooltip('Refresh Agents'), findsNothing);
      expect(find.byTooltip('Add Agent'), findsOneWidget);
      expect(find.byTooltip('Runtime'), findsNothing);
      expect(find.byTooltip('Skill Hub'), findsNothing);
      expect(find.byTooltip('Token Usage'), findsNothing);
      expect(find.byKey(const Key('mobile-bottom-nav-relay')), findsOneWidget);
      expect(find.byKey(const Key('mobile-bottom-nav-agents')), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-bottom-nav-features')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-bottom-agent-icon')), findsOneWidget);
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
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(find.text('Arc Desktop'), findsOneWidget);
      expect(find.text('Codex'), findsNothing);
      expect(find.text('Latest Codex response from relay'), findsNothing);
      expect(find.textContaining('2026'), findsNothing);
      expect(find.text('Add target'), findsNothing);
      expect(find.text('Unpaired Device'), findsNothing);
      expect(find.text('Mobile Relay'), findsWidgets);
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

      await tester.tap(find.byKey(const Key('mobile-bottom-nav-relay')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.currentSection, FutureClientSection.mobileRelay);
      expect(find.text('Mobile Relay'), findsWidgets);
      expect(
        find.byKey(const Key('mobile-agent-list-item-codex')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('mobile-bottom-nav-agents')));
      await tester.pump();
      await tester.pumpAndSettle();

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
      expect(find.text('Configure API Key'), findsNWidgets(3));
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

      expect(
        find.byKey(const Key('mobile-remote-agent-chatgpt')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('mobile-remote-agent-chatgpt')));
      await tester.pump();

      expect(
        find.byKey(const Key('mobile-provider-new-conversation-chatgpt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-provider-settings-chatgpt')),
        findsOneWidget,
      );

      await tester.runAsync(
        () => controller.authorizeMobileAgentOAuth('chatgpt'),
      );
      await tester.pump();

      expect(relayService.loginOAuthCalls, 1);
      expect(controller.mobileAgentAccounts.single.credentialPresent, isTrue);
      expect(controller.mobileAgentAccounts.single.credentialHint, 'OAuth');
      expect(
        find.byKey(const Key('mobile-remote-agent-api-key-chatgpt')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('mobile-provider-new-conversation-chatgpt')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('mobile-remote-agent-composer-chatgpt')),
        findsOneWidget,
      );
      expect(find.text('Connected'), findsWidgets);
      expect(
        find.text(
          'ChatGPT OAuth authorized. This phone can use ChatGPT web conversation directly.',
        ),
        findsNothing,
      );

      await tester.dragFrom(const Offset(330, 420), const Offset(-210, 0));
      await tester.pump();

      expect(find.text('Model'), findsOneWidget);
      expect(find.text('Reasoning Effort'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('mobile-remote-agent-model-chatgpt')),
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
      await tester.tap(
        find.byKey(const Key('mobile-remote-agent-reasoning-chatgpt')),
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
        find.byKey(const Key('mobile-provider-new-conversation-chatgpt')),
        findsOneWidget,
      );

      await tester.dragFrom(const Offset(80, 420), const Offset(210, 0));
      await tester.pump();

      expect(
        find.byKey(const Key('mobile-remote-agent-chatgpt')),
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
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
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
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
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
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
    await tester.runAsync(() async {
      await controller.addMobileAgentProvider('deepseek');
      await controller.configureMobileAgentApiKey(
        providerId: 'deepseek',
        apiKey: 'test-deepseek-api-key-4321',
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

  testWidgets('mobile synced Gemini API key is shown as direct API key', (
    tester,
  ) async {
    final relayService = _OAuthRelayService();
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
    controller.mobileAgentAccounts = [
      MobileAgentAccount.create(
        mobileAgentProviderFor('gemini'),
        id: 'mobile-synced:gemini:gemini-api-key',
        label: 'Gemini',
        authSource: MobileAgentAccount.authSourceMobileSynced,
        credentialPresent: true,
        credentialHint: '**** 1234',
        relayDeviceLabel: 'ARC Desktop',
        relayProfileId: 'gemini',
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
          child: ClientShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    const geminiKey = Key(
      'mobile-remote-agent-mobile-synced:gemini:gemini-api-key',
    );
    expect(find.byKey(geminiKey), findsOneWidget);
    expect(find.text('Synced From ARC Desktop To This Phone'), findsOneWidget);

    await tester.tap(find.byKey(geminiKey));
    await tester.pump();
    await tester.dragFrom(const Offset(330, 420), const Offset(-210, 0));
    await tester.pump();

    expect(find.text('Direct API Key'), findsOneWidget);
    expect(find.text('Google OAuth (Gemini API direct)'), findsNothing);
    expect(find.text('Google OAuth Authorization'), findsNothing);
    expect(find.text('Configure API Key'), findsNothing);
    expect(find.text('Refresh Synced Authorization'), findsNothing);
    expect(
      find.byKey(const Key('mobile-remote-agent-auth-gemini')),
      findsNothing,
    );
    expect(relayService.loginOAuthCalls, 0);
    expect(relayService.credentialSyncCalls, 0);
  });

  testWidgets('mobile local Gemini account only shows API key configuration', (
    tester,
  ) async {
    final relayService = _OAuthRelayService();
    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
    controller.mobileAgentAccounts = [
      MobileAgentAccount.create(
        mobileAgentProviderFor('gemini'),
        id: 'gemini-local',
        label: 'Gemini',
        authSource: MobileAgentAccount.authSourceLocalApiKey,
        credentialPresent: true,
        credentialHint: '**** 1234',
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

    final accountTile = find.byKey(
      const Key('mobile-remote-agent-gemini-local'),
    );
    expect(accountTile, findsOneWidget);
    tester
        .widget<InkWell>(
          find.descendant(of: accountTile, matching: find.byType(InkWell)),
        )
        .onTap
        ?.call();
    await tester.pump();

    final settingsButton = find.byKey(
      const Key('mobile-provider-settings-gemini-local'),
    );
    expect(settingsButton, findsOneWidget);
    tester.widget<IconButton>(settingsButton).onPressed?.call();
    await tester.pump();

    expect(find.text('Direct API Key'), findsOneWidget);
    expect(find.text('Google OAuth (Gemini API direct)'), findsNothing);
    expect(find.text('Refresh Synced Authorization'), findsNothing);
    expect(find.text('Google OAuth Authorization'), findsNothing);
    expect(
      find.byKey(const Key('mobile-remote-agent-paste-oauth-gemini')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('mobile-remote-agent-oauth-auth-gemini')),
      findsNothing,
    );
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Reasoning Effort'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('mobile-remote-agent-reasoning-gemini-local')),
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
    expect(controller.mobileAgentAccounts.single.reasoningEffort, 'high');

    final authButton = find.byKey(const Key('mobile-remote-agent-auth-gemini'));
    expect(tester.widget<FilledButton>(authButton).onPressed, isNotNull);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(authButton).onPressed?.call();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(relayService.loginOAuthCalls, 0);
  });

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
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
      agentService: _NoopAgentService(scanTargetsResponse: const []),
      conversationService: const _NoopConversationService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;

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
    expect(relayService.loginOAuthMobileAccountIds.last, 'chatgpt');
  });

  testWidgets(
    'mobile synced Gemini API key chat failure does not prompt OAuth',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dataDirectory = Directory.systemTemp.createTempSync(
        'lico-mobile-gemini-api-key-failure-',
      );
      addTearDown(() => dataDirectory.deleteSync(recursive: true));
      final relayService = _OAuthRelayService()
        ..localProviderStatusCode = 401
        ..localProviderProxyMode = 'android-system-proxy';
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = FutureClientSection.agents;
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
            providerId: 'gemini',
            label: 'Gemini',
            credentialPresent: true,
            profileId: 'gemini',
            credentialKind: 'api-key',
            source: 'desktop-model-profile',
          ),
        ],
      );
      controller.mobileAgentAccounts = [
        MobileAgentAccount.create(
          mobileAgentProviderFor('gemini'),
          id: 'mobile-synced:gemini:gemini',
          label: 'Gemini',
          authSource: MobileAgentAccount.authSourceMobileSynced,
          credentialPresent: true,
          credentialHint: '**** 1234',
          relayDeviceLabel: 'ARC Desktop',
          relayProfileId: 'gemini',
        ),
      ];
      controller.syncMobileAgentAccountsWithDesktopRelay();
      expect(
        controller.mobileAgentAccounts.any(
          (account) =>
              account.providerId == 'gemini' &&
              account.usesDesktopRelay &&
              account.relayProfileId == 'gemini',
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
        (account) => account.providerId == 'gemini' && account.usesMobileSynced,
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
              account.providerId == 'gemini' &&
              account.usesDesktopRelay &&
              account.relayProfileId == 'gemini',
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
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataDirectory),
        agentService: _NoopAgentService(scanTargetsResponse: const []),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = FutureClientSection.agents;
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
      final controller = FutureClientController(
        agentService: _NoopAgentService(scanTargetsResponse: _targets),
        conversationService: const _NoopConversationService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.currentSection = FutureClientSection.agents;
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        pcClientName: 'ARC Desktop',
        pairingId: 'pairing_desktop',
        mobileTokenPresent: true,
        paired: true,
      );
      controller.scannedTargets = _targets;
      controller.selectedConversationAgentId = 'codex';

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

      final composer = find.widgetWithText(TextField, 'Message Codex');
      expect(composer, findsOneWidget);

      await tester.enterText(composer, 'hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(relayService.agentMessageCalls, 1);
      expect(relayService.lastAgentId, 'codex');
      expect(relayService.lastAgentText, 'hello');
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Codex relay reply'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile home keeps bottom navigation without manual target entry',
    (tester) async {
      final controller = FutureClientController(
        agentService: _NoopAgentService(scanTargetsResponse: const []),
      );
      addTearDown(controller.dispose);

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

      expect(find.byType(ShellTopBar), findsNothing);
      expect(find.byKey(const Key('mobile-bottom-nav-relay')), findsOneWidget);
      expect(find.byKey(const Key('mobile-bottom-agent-icon')), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-bottom-nav-features')),
        findsOneWidget,
      );
      expect(find.byTooltip('Pair Device'), findsNothing);
      expect(find.byTooltip('Mobile Relay'), findsOneWidget);
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

  testWidgets('mobile agents bottom nav double-tap returns to home list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FutureClientController(
      agentService: _NoopAgentService(scanTargetsResponse: _targets),
      conversationService: const _NoopConversationService(),
      mobileRelayService: _OAuthRelayService(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.currentSection = FutureClientSection.agents;
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

    // Double-tap the agents bottom nav icon to return to the home list.
    await tester.tap(find.byKey(const Key('mobile-bottom-nav-agents')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('mobile-bottom-nav-agents')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mobile-desktop-agent-codex')), findsNothing);
    expect(find.byKey(pairedDeviceKey), findsOneWidget);
  });
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

Future<void> _waitForAgentAllowances(
  FutureClientController controller,
  String agentId,
) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (controller.allowancesForAgent(agentId).isNotEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

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
    int? limit,
    int offset = 0,
  }) {
    return const Stream.empty();
  }

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
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
