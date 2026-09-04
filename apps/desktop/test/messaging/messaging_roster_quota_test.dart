import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/composition/provider_quota_gateway_adapter.dart';
import 'package:licoup/src/application/features/agents/contracts/provider_quota_gateway.dart';
import 'package:licoup/src/application/features/agents/controller/provider_quota_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_quota_ring.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_quota_usage_card.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  group('roster quota rings', () {
    testWidgets(
      'live ring clamps above 100, stale ring dims, source-less avatar has no ring',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          _testApp(
            const Key('messaging-roster-quota-qa-boundary'),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: CanonicalGroupRosterSurface(
                  child: CanonicalGroupRoster(
                    conversation: _conversation(),
                    targets: _targets(),
                    onMentionAgent: (_) {},
                    quotaSnapshots: _quotaSnapshots(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Live + stale snapshots render rings; the source-less member does
        // not — no ring widget, no track, no placeholder.
        expect(find.byType(MessagingQuotaRing), findsNWidgets(2));
        expect(
          find.byKey(const Key('messaging-quota-ring-codex')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('messaging-quota-ring-cursor')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('messaging-quota-ring-antigravity')),
          findsNothing,
        );

        // usedPercent 187 clamps to a full-arc sweep for display.
        final livePainter = _ringPainter(tester, 'codex');
        expect(livePainter.progress, 1.0);
        final stalePainter = _ringPainter(tester, 'cursor');
        expect(stalePainter.progress, closeTo(0.62, 0.001));

        // Stale paints the same arc dimmed.
        expect((livePainter.color.a * 255).round(), 255);
        expect(
          (stalePainter.color.a * 255).round(),
          MessagingDesktopMetrics.groupRosterQuotaRingStaleAlpha,
        );

        // The ring stays inside the existing 40 px member extent; the ringed
        // avatar insets by the ring band while the source-less avatar keeps
        // the full extent.
        expect(
          tester.getSize(find.byKey(const Key('messaging-quota-ring-codex'))),
          const Size.square(MessagingDesktopMetrics.groupRosterMemberExtent),
        );
        final ringedWell = tester.getRect(
          find.descendant(
            of: find.byKey(const Key('canonical-group-roster-agent-codex')),
            matching: find.byKey(const Key('messaging-agent-avatar-well')),
          ),
        );
        expect(
          ringedWell.width,
          closeTo(MessagingDesktopMetrics.groupRosterQuotaAvatarExtent, 0.1),
        );
        final bareWell = tester.getRect(
          find.descendant(
            of: find.byKey(
              const Key('canonical-group-roster-agent-antigravity'),
            ),
            matching: find.byKey(const Key('messaging-agent-avatar-well')),
          ),
        );
        expect(
          bareWell.width,
          closeTo(MessagingDesktopMetrics.conversationAvatarExtent, 0.1),
        );

        // Relay dot stays anchored to the avatar box bottom-right for every
        // member, ringed or not, and the surface keeps its stadium silhouette.
        for (final agentId in const ['codex', 'cursor', 'antigravity']) {
          expect(
            find.byKey(Key('canonical-group-roster-relay-dot-$agentId')),
            findsOneWidget,
          );
          final dotRect = tester.getRect(
            find.byKey(Key('canonical-group-roster-relay-dot-$agentId')),
          );
          final agentRect = tester.getRect(
            find.byKey(Key('canonical-group-roster-agent-$agentId')),
          );
          expect(dotRect.right, lessThanOrEqualTo(agentRect.right + 0.1));
          expect(dotRect.bottom, lessThanOrEqualTo(agentRect.bottom + 0.1));
        }
        expect(
          tester
              .widget<MessagingConversationOverlayGlass>(
                find.byKey(const Key('canonical-group-roster-glass')),
              )
              .borderRadius,
          BorderRadius.circular(999),
        );
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byKey(const Key('messaging-roster-quota-qa-boundary')),
          matchesGoldenFile('../goldens/messaging/roster_quota_rings.png'),
        );
      },
    );

    testWidgets('hover expands a floating usage card and exit collapses it', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _testApp(
          const Key('messaging-roster-quota-hover-qa-boundary'),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: CanonicalGroupRosterSurface(
                child: CanonicalGroupRoster(
                  conversation: _conversation(),
                  targets: _targets(),
                  onMentionAgent: (_) {},
                  quotaSnapshots: _quotaSnapshots(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: const Offset(8, 8));
      await tester.pump();
      expect(
        find.byKey(const Key('messaging-quota-usage-card-codex')),
        findsNothing,
      );

      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const Key('canonical-group-roster-agent-codex')),
        ),
      );
      await tester.pump();

      final cardFinder = find.byKey(
        const Key('messaging-quota-usage-card-codex'),
      );
      expect(cardFinder, findsOneWidget);
      expect(
        find.descendant(
          of: cardFinder,
          matching: find.text('Codex quota usage'),
        ),
        findsOneWidget,
      );
      // Provider identity labels.
      expect(
        find.descendant(
          of: cardFinder,
          matching: find.text('work@example.com · Pro'),
        ),
        findsOneWidget,
      );
      // Every window's percentage, progress bar, and a ticked reset
      // countdown per window.
      expect(
        find.descendant(of: cardFinder, matching: find.text('187% Used')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cardFinder, matching: find.text('63% Used')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cardFinder,
          matching: find.byKey(const Key('messaging-quota-window-bar')),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: cardFinder, matching: find.text('5h limit')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cardFinder, matching: find.text('Weekly limit')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cardFinder,
          matching: find.textContaining('Resets in'),
        ),
        findsNWidgets(2),
      );

      // The capsule itself stays a pure icon list: no text inside any member
      // well, even while the card floats beside it in the overlay (an
      // OverlayPortal child still counts as a widget-tree descendant, so the
      // assertion anchors on the capsule's own member subtree).
      for (final agentId in const ['codex', 'cursor', 'antigravity']) {
        expect(
          find.descendant(
            of: find.byKey(Key('canonical-group-roster-agent-$agentId')),
            matching: find.byType(Text),
          ),
          findsNothing,
        );
      }

      // Stale snapshot cards carry the capture age.
      await gesture.moveTo(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(cardFinder, findsNothing);
      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const Key('canonical-group-roster-agent-cursor')),
        ),
      );
      await tester.pump();
      final staleCardFinder = find.byKey(
        const Key('messaging-quota-usage-card-cursor'),
      );
      expect(staleCardFinder, findsOneWidget);
      expect(
        find.descendant(
          of: staleCardFinder,
          matching: find.textContaining('Captured'),
        ),
        findsOneWidget,
      );

      // Exit collapses the card after the shared dismiss grace.
      await gesture.moveTo(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(staleCardFinder, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('usage card renders countdown, identity, and capture age', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final fixedNow = DateTime.utc(2026, 8, 29, 12);
      final snapshot = ProviderQuotaSnapshot(
        agentId: 'codex',
        provider: 'codex',
        status: ProviderQuotaStatus.stale,
        windows: [
          ProviderQuotaWindow(
            label: '5h limit',
            usedPercent: 82.4,
            windowMinutes: 300,
            resetsAt: fixedNow
                .add(const Duration(hours: 2, minutes: 14))
                .toIso8601String(),
          ),
          const ProviderQuotaWindow(
            label: 'Weekly limit',
            usedPercent: 41,
            windowMinutes: 10080,
            resetDescription: 'Resets on Monday',
          ),
        ],
        identity: const ProviderQuotaIdentity(
          accountLabel: 'work@example.com',
          plan: 'Pro',
        ),
        capturedAt: fixedNow
            .subtract(const Duration(minutes: 42))
            .toIso8601String(),
        staleAfterSeconds: 300,
      );
      await tester.pumpWidget(
        _testApp(
          const Key('messaging-quota-usage-card-qa-boundary'),
          Center(
            child: MessagingQuotaUsageCard(
              snapshot: snapshot,
              clock: () => fixedNow,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Codex quota usage'), findsOneWidget);
      expect(find.text('work@example.com · Pro'), findsOneWidget);
      expect(find.text('82% Used'), findsOneWidget);
      expect(find.text('41% Used'), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-quota-window-bar')),
        findsNWidgets(2),
      );
      // Countdown ticked from resetsAt; resetDescription is only the fallback
      // for the window without a timestamp.
      expect(find.text('Resets in 2h 14m'), findsOneWidget);
      expect(find.text('Resets on Monday'), findsOneWidget);
      expect(find.text('Captured 42m ago'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(const Key('messaging-quota-usage-card-qa-boundary')),
        matchesGoldenFile('../goldens/messaging/roster_quota_usage_card.png'),
      );

      // Unmount so the countdown ticker is cancelled before teardown.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('provider quota controller', () {
    test('refresh projects immutable snapshots keyed by agent id', () async {
      final gateway = _FakeQuotaGateway(
        _wireReport([
          _wireSnapshot(agentId: 'codex'),
          _wireSnapshot(agentId: 'cursor', status: 'stale'),
        ]),
      );
      final controller = ProviderQuotaController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(gateway.calls, 1);
      expect(controller.snapshots.keys, containsAll(['codex', 'cursor']));
      expect(controller.snapshots['codex']!.hasQuotaWindows, isTrue);
      expect(controller.generatedAt, '2026-08-29T12:00:00Z');
      expect(
        () => controller.snapshots['x'] = controller.snapshots['codex']!,
        throwsUnsupportedError,
      );

      // A failed pull retains the previous projection.
      gateway.error = StateError('offline');
      await controller.refresh();
      expect(controller.snapshots.keys, containsAll(['codex', 'cursor']));
    });

    test(
      'refresh is single-flight and polling owners reference-count',
      () async {
        final gateway = _FakeQuotaGateway(_wireReport([]));
        final controller = ProviderQuotaController(gateway: gateway);
        addTearDown(controller.dispose);

        gateway.gate = Completer<void>();
        final first = controller.refresh();
        final second = controller.refresh();
        expect(gateway.calls, 1);
        gateway.gate!.complete();
        await Future.wait([first, second]);

        final ownerA = Object();
        final ownerB = Object();
        controller.acquirePollingOwner(ownerA);
        await controller.refresh();
        controller.acquirePollingOwner(ownerB);
        expect(controller.pollingOwnerCount, 2);
        controller.releasePollingOwner(ownerA);
        expect(controller.pollingOwnerCount, 1);
        controller.releasePollingOwner(ownerB);
        expect(controller.pollingOwnerCount, 0);
      },
    );

    test('wire contract parsing enforces the fixed schema', () {
      final report = ProviderQuotaSnapshotReport.fromJson(
        _wireReport([_wireSnapshot(agentId: 'codex')]),
      );
      final snapshot = report.byAgentId['codex']!;
      expect(snapshot.provider, 'codex');
      expect(snapshot.status, ProviderQuotaStatus.live);
      expect(snapshot.windows, hasLength(2));
      expect(snapshot.windows.first.usedPercent, 187.4);
      expect(snapshot.windows.first.windowMinutes, 300);
      expect(snapshot.identity.accountLabel, 'work@example.com');
      expect(snapshot.staleAfterSeconds, 300);

      // Unavailable snapshots and window-less entries render nothing.
      final unavailable = ProviderQuotaSnapshotReport.fromJson(
        _wireReport([_wireSnapshot(agentId: 'cursor', status: 'unavailable')]),
      ).byAgentId['cursor']!;
      expect(unavailable.hasQuotaWindows, isFalse);

      expect(
        () => ProviderQuotaSnapshotReport.fromJson({
          'schemaVersion': 'v0.0.1:other-1',
          'generatedAt': '',
          'snapshots': const [],
        }),
        throwsFormatException,
      );
    });

    test('adapter drives the fixed provider-quota snapshot command', () async {
      final runner = _RecordingRunner(
        _wireReport([_wireSnapshot(agentId: 'codex')]),
      );
      final adapter = ProviderQuotaGatewayAdapter(runner: runner);

      final report = await adapter.snapshot(
        agentId: 'codex',
        forceRefresh: true,
      );
      expect(runner.lastArgs, [
        'provider-quota',
        'snapshot',
        '--agent',
        'codex',
        '--force-refresh',
      ]);
      expect(report.byAgentId.keys, ['codex']);
    });
  });
}

MessagingQuotaRingPainter _ringPainter(WidgetTester tester, String agentId) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byKey(Key('messaging-quota-ring-$agentId')),
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.painter! as MessagingQuotaRingPainter;
}

Widget _testApp(Key boundaryKey, Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    // The golden boundary wraps the Scaffold so the dark canvas is captured
    // behind the glass chrome instead of alpha-flattening to white.
    home: RepaintBoundary(
      key: boundaryKey,
      child: Scaffold(backgroundColor: const Color(0xFF101010), body: child),
    ),
  );
}

Map<String, ProviderQuotaSnapshot> _quotaSnapshots() {
  final now = DateTime.now().toUtc();
  return {
    'codex': ProviderQuotaSnapshot(
      agentId: 'codex',
      provider: 'codex',
      status: ProviderQuotaStatus.live,
      windows: [
        ProviderQuotaWindow(
          label: '5h limit',
          usedPercent: 187.4,
          windowMinutes: 300,
          resetsAt: now
              .add(const Duration(hours: 4, minutes: 49))
              .toIso8601String(),
        ),
        ProviderQuotaWindow(
          label: 'Weekly limit',
          usedPercent: 63,
          windowMinutes: 10080,
          resetsAt: now
              .add(const Duration(days: 3, hours: 2))
              .toIso8601String(),
        ),
      ],
      identity: const ProviderQuotaIdentity(
        accountLabel: 'work@example.com',
        plan: 'Pro',
      ),
      capturedAt: now.toIso8601String(),
      staleAfterSeconds: 300,
    ),
    'cursor': ProviderQuotaSnapshot(
      agentId: 'cursor',
      provider: 'cursor',
      status: ProviderQuotaStatus.stale,
      windows: [
        ProviderQuotaWindow(
          label: 'Plan usage',
          usedPercent: 62,
          resetsAt: now
              .add(const Duration(days: 12, hours: 6))
              .toIso8601String(),
        ),
      ],
      identity: const ProviderQuotaIdentity(plan: 'Pro'),
      capturedAt: now.subtract(const Duration(minutes: 12)).toIso8601String(),
      staleAfterSeconds: 300,
    ),
    // 'antigravity' intentionally absent: no quota source, no fake data.
  };
}

ClientConversation _conversation() => ClientConversation.fromJson(const {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'isGroup': true,
  'revision': 2,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 2,
  'eventCount': 0,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'Local User',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:codex',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:codex',
        'kind': 'agent',
        'displayName': 'Codex',
        'agentId': 'codex',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:cursor',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:cursor',
        'kind': 'agent',
        'displayName': 'Cursor',
        'agentId': 'cursor',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:antigravity',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:antigravity',
        'kind': 'agent',
        'displayName': 'Antigravity',
        'agentId': 'antigravity',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
});

List<TargetCandidate> _targets() => [
  _target('codex', 'Codex'),
  _target('cursor', 'Cursor'),
  _target('antigravity', 'Antigravity'),
];

TargetCandidate _target(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'fixture',
    'conversationReadiness': 'ready',
  },
  supportedActions: const ['runtime.message.send'],
);

Map<String, dynamic> _wireReport(List<Map<String, dynamic>> snapshots) => {
  'schemaVersion': providerQuotaSnapshotsSchema,
  'generatedAt': '2026-08-29T12:00:00Z',
  'snapshots': snapshots,
};

Map<String, dynamic> _wireSnapshot({
  required String agentId,
  String status = 'live',
}) => {
  'agentId': agentId,
  'provider': agentId,
  'status': status,
  'windows': const [
    {
      'label': '5h limit',
      'usedPercent': 187.4,
      'windowMinutes': 300,
      'resetsAt': '2026-08-29T16:49:00Z',
      'resetDescription': '',
    },
    {
      'label': 'Weekly limit',
      'usedPercent': 63,
      'windowMinutes': 10080,
      'resetsAt': null,
      'resetDescription': 'Resets on Monday',
    },
  ],
  'identity': const {'accountLabel': 'work@example.com', 'plan': 'Pro'},
  'capturedAt': '2026-08-29T11:48:00Z',
  'staleAfterSeconds': 300,
};

final class _FakeQuotaGateway implements ProviderQuotaGateway {
  _FakeQuotaGateway(Map<String, dynamic> wire)
    : report = ProviderQuotaSnapshotReport.fromJson(wire);

  ProviderQuotaSnapshotReport report;
  Object? error;
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<ProviderQuotaSnapshotReport> snapshot({
    String agentId = '',
    bool forceRefresh = false,
  }) async {
    calls += 1;
    await gate?.future;
    final failure = error;
    if (failure != null) throw failure;
    return report;
  }
}

final class _RecordingRunner implements AgentCommandRunner {
  _RecordingRunner(this.response);

  final Map<String, dynamic> response;
  List<String>? lastArgs;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    lastArgs = args;
    return response;
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
