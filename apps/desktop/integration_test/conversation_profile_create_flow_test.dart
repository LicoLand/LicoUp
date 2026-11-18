import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_profile_create_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_registry.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import '../test/layout/fixtures/layout_destination_presentation_fixture.dart';
import '../test/support/canonical_group/canonical_group_binding_fixture.dart';

final class _ProfileOrderStore extends DashboardFeatureOrderStore {
  const _ProfileOrderStore();

  @override
  Future<List<String>> load(Object portableData) async =>
      DashboardFeatureOrder.defaultOrder;

  @override
  Future<void> save(Object portableData, List<String> order) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'creating an Agent profile materializes a direct Conversation',
    (tester) async {
      final cliPath = Platform.environment['LICO_CLIENT_PATH']?.trim() ?? '';
      expect(cliPath, isNotEmpty, reason: 'LICO_CLIENT_PATH is required');
      final portableRoot = await Directory.systemTemp.createTemp(
        'lico-profile-button-flow-',
      );
      addTearDown(() => portableRoot.delete(recursive: true));
      final service = AgentService(
        dataDirectory: () async => portableRoot.path,
        resolveCliBinary: () async => File(cliPath),
      );
      addTearDown(service.dispose);
      final native = _ObservedConversationNativePort(
        service.conversationNativePort,
      );
      final controller = ClientConversationController(native: native);
      addTearDown(controller.dispose);
      await controller.initialize();
      resetConversationProfilesForTests();
      addTearDown(resetConversationProfilesForTests);
      final captureKey = GlobalKey();

      tester.view.physicalSize = const Size(1120, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          builder: (context, child) => RepaintBoundary(
            key: captureKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: _ProfileConversationButtonHarness(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(captureKey, '01-start');

      final plus = find.byTooltip('新建');
      expect(plus, findsOneWidget);
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.text('创建智能体'), findsOneWidget);
      await _capture(captureKey, '02-create-menu');

      await tester.tap(find.text('创建智能体'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation-profile-create-dialog')),
        findsOne,
      );

      await tester.enterText(
        find.byKey(const Key('agent-profile-name-field')),
        'Nova',
      );
      await tester.ensureVisible(
        find.byKey(const Key('agent-profile-option-codex')),
      );
      await tester.tap(
        find.byKey(const Key('agent-profile-option-codex')),
      );
      await tester.pumpAndSettle();
      final modelOption = find.descendant(
        of: find.byKey(const Key('agent-profile-model-card')),
        matching: find.text('codex-mini'),
      );
      await tester.ensureVisible(modelOption.first);
      await tester.tap(modelOption.first);
      await tester.pumpAndSettle();
      await _capture(captureKey, '03-profile-ready');

      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('agent-profile-create-confirm')),
      );
      expect(confirm.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('agent-profile-create-confirm')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('conversation-profile-create-dialog'))
            .evaluate()
            .isEmpty,
      );
      await _capture(captureKey, '04-profile-created');

      final created = controller.selectedConversation;
      expect(created, isNotNull);
      expect(created!.group, isFalse);
      expect(created.title, 'Nova');
      expect(
        created.memberships
            .map((membership) => membership.principal.id)
            .toSet(),
        containsAll(<String>{'human:local'}),
      );
      final persona = created.memberships.firstWhere(
        (membership) => membership.principal.id.startsWith('profile:'),
      );
      expect(persona.principal.agentId, 'codex');
      expect(
        created.assistantMembershipId,
        persona.id,
        reason: 'the persona membership must be the assigned assistant',
      );

      final actions = native.requests
          .map((request) => request['action'])
          .toList();
      final createIndex = actions.indexOf('conversation.create');
      final assistantIndex = actions.indexOf('conversation.assistant.set');
      final profileGetIndex = actions.indexOf('conversation.profile.get');
      final profileUpdateIndex = actions.indexOf(
        'conversation.profile.update',
      );
      expect(createIndex, isNonNegative);
      expect(assistantIndex, greaterThan(createIndex));
      expect(profileGetIndex, greaterThan(assistantIndex));
      expect(profileUpdateIndex, greaterThan(profileGetIndex));

      final createRequest = native.requests[createIndex];
      expect(createRequest['isGroup'], isFalse);
      final createMembers = createRequest['members'] as List<Object?>;
      expect(createMembers, hasLength(1));
      final createPrincipal =
          (createMembers.single as Map<String, dynamic>)['principal']
              as Map<String, dynamic>;
      expect(createPrincipal['kind'], 'agent');
      expect(
        (createPrincipal['id'] ?? '').toString(),
        startsWith('profile:'),
      );
      expect(createPrincipal['agentId'], 'codex');

      final assistantRequest = native.requests[assistantIndex];
      expect(
        assistantRequest['expectedRevision'],
        1,
        reason:
            'member insertion bumps a fresh conversation to revision 1; '
            'the CAS token must come from the create echo',
      );

      final updateRequest = native.requests[profileUpdateIndex];
      expect(updateRequest['conversationId'], created.id);
      final intent = updateRequest['intent'] as Map<String, dynamic>;
      expect(intent['preferredModel'], 'codex-mini');

      final persisted = await controller.membershipProfile(persona.id);
      expect(persisted, isNotNull);
      expect(persisted!['revision'], greaterThanOrEqualTo(2));
      expect(persisted['preferredModel'], 'codex-mini');

      expect(
        conversationProfiles.value
            .where((profile) => profile.conversationId == created.id),
        hasLength(1),
      );
      expect(
        find.text('Nova'),
        findsWidgets,
        reason: 'the profile contact row renders in the sidebar',
      );
      expect(find.byKey(const Key('agent-profile-create-failure')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ProfileConversationButtonHarness extends StatefulWidget {
  const _ProfileConversationButtonHarness({required this.controller});

  final ClientConversationController controller;

  @override
  State<_ProfileConversationButtonHarness> createState() =>
      _ProfileConversationButtonHarnessState();
}

class _ProfileConversationButtonHarnessState
    extends State<_ProfileConversationButtonHarness> {
  late final CanonicalGroupBindingFixture _dialogFixture;

  static final _targets = <TargetCandidate>[
    TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/codex',
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'conversationDriver': 'native',
        'models': <String>['codex-mini'],
      },
    ),
    TargetCandidate(
      target: 'claude-code',
      label: 'Claude Code',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/claude',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'native'},
    ),
  ];

  @override
  void initState() {
    super.initState();
    _dialogFixture = CanonicalGroupBindingFixture(
      controller: widget.controller,
      targets: _targets,
    );
  }

  @override
  void dispose() {
    unawaited(_dialogFixture.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Object?>(
        stream: _dialogFixture.changes,
        builder: (context, _) => Row(
          children: [
            SizedBox(
              width: 320,
              child: FixtureLayoutPresentationScope(
                agents: const FixtureLayoutAgentsPresentation.docked(),
                child: MessagingFeatureOrderScope(
                  orderStore: const _ProfileOrderStore(),
                  child: MessagingContactList(
                targets: _targets,
                sessionsByAgent:
                    const <String, List<AgentConversationSession>>{},
                selectedAgentId: 'codex',
                activityFor: (_) => AgentConversationTabActivity.none,
                onSelectAgent: (_) {},
                onNewConversation: () {},
                groupConversations: widget.controller.groupConversations,
                directConversations: widget.controller.directConversations,
                selectedGroupConversationId:
                    widget.controller.selectedConversationId,
                onSelectGroupConversation: (conversationId) => unawaited(
                  widget.controller.selectConversation(conversationId),
                ),
                onNewGroupConversation: () {},
                onNewAgentProfile: () => unawaited(
                  showConversationProfileCreateDialog(
                    context: context,
                    intents: _dialogFixture.conversation.intents,
                    effects: _dialogFixture.conversation.effects,
                    agentsIntents: _dialogFixture.agents.intents,
                    targets: _targets,
                  ),
                ),
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: Text(
                  widget.controller.selectedConversation?.title ?? '选择一个对话',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ObservedConversationNativePort
    implements ClientConversationNativePort {
  _ObservedConversationNativePort(this.native);

  final ClientConversationNativePort native;
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    requests.add(command.payload);
    if (command.action == 'conversation.create') {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return native.executeClientConversation(command);
  }
}

Future<void> _capture(GlobalKey captureKey, String name) async {
  final outputRoot =
      Platform.environment['LICO_PROFILE_AUDIT_OUTPUT']?.trim() ?? '';
  if (outputRoot.isEmpty) return;
  final boundary = captureKey.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('capture_boundary_unavailable');
  }
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('capture_failed');
  final directory = Directory(outputRoot);
  await directory.create(recursive: true);
  await File(
    '${directory.path}/$name.png',
  ).writeAsBytes(data.buffer.asUint8List(), flush: true);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}
