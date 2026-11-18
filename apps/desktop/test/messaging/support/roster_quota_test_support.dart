import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Widget buildQuotaTestApp(Key boundaryKey, Widget child) {
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

Map<String, ProviderQuotaSnapshot> quotaTestSnapshots() {
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

ProviderQuotaSnapshot quotaUsageCardTestSnapshot(DateTime fixedNow) =>
    ProviderQuotaSnapshot(
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

ClientConversation quotaTestConversation() =>
    ClientConversation.fromJson(const {
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

List<TargetCandidate> quotaTestTargets() => [
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
