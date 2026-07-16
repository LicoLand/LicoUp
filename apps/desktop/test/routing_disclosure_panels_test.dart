import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/routing_disclosure_panels.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: LicoStrings.supportedLocales,
    theme: buildLicoTheme(platformBrightness: Brightness.dark),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  final policy = const RoutingPolicyDocument(
    schemaVersion: 2,
    id: 'policy-beta',
    label: 'Policy Beta',
    agents: [RoutingPolicyAgent(id: 'agent-b', priority: 1)],
  );

  final decision = RouteDecisionRecord(
    chosenAgentId: 'agent-b',
    chosenAgentLabel: 'Agent B',
    policyId: 'policy-beta',
    policyVersion: 2,
    alternatives: const [
      RouteCandidate(
        agentId: 'agent-b',
        agentLabel: 'Agent B',
        priority: 1,
        matchedRoles: ['implementation'],
        satisfiedCapabilities: ['tool-use'],
        reason: 'selected',
      ),
      RouteCandidate(
        agentId: 'agent-a',
        agentLabel: 'Agent A',
        priority: 2,
        matchedRoles: ['implementation'],
        satisfiedCapabilities: ['tool-use'],
        reason: 'alternative',
      ),
    ],
    excluded: const [
      RouteExclusion(
        agentId: 'agent-c',
        agentLabel: 'Agent C',
        reason: 'not_ready',
      ),
    ],
    timestamp: '2026-07-11T06:00:00Z',
  );

  final package = DistillationPackage(
    objective: 'Ship routing disclosure.',
    currentState: 'UI widgets under test.',
    decisions: const ['Render from contract types only.'],
    constraints: const ['Never show raw source transcript.'],
    openItems: const ['Final validation.'],
    sourceSessionId: 'session-a',
    sourceAgentId: 'agent-a',
    createdAt: '2026-07-11T06:00:00Z',
  );

  final history = [
    RouteHistoryEntry(
      taskId: 'task-1',
      timestamp: '2026-07-11T06:00:00Z',
      sourceAgentId: 'agent-a',
      targetAgentId: 'agent-b',
      sourceSessionHandle: 'rh_aaaaaaaaaaaaaaaaaaaaaaaa',
      targetSessionHandle: 'rh_bbbbbbbbbbbbbbbbbbbbbbbb',
      decision: decision,
      switchReason: 'policy-reload',
      distillationDigest:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
  ];

  testWidgets('V-007-A policy identity and reload state display', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        RoutingPolicyStatusPanel(
          policy: policy,
          validationError: const RoutingPolicyValidationError(
            path: '/agents',
            message: 'At least one agent entry is required.',
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('routing-policy-name')), findsOneWidget);
    expect(find.text('Policy Beta'), findsOneWidget);
    expect(find.byKey(const Key('routing-policy-version')), findsOneWidget);
    expect(find.text('version 2'), findsOneWidget);
    expect(
      find.byKey(const Key('routing-policy-validation-state')),
      findsOneWidget,
    );
    expect(find.text('Error'), findsOneWidget);
    expect(
      find.byKey(const Key('routing-policy-validation-message')),
      findsOneWidget,
    );
  });

  testWidgets('V-007-B decision record rendering with per-candidate reasons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(RoutingDecisionDisclosure(decision: decision)),
    );
    expect(find.byKey(const Key('routing-decision-chosen')), findsOneWidget);
    expect(find.textContaining('Agent B'), findsWidgets);
    expect(
      find.byKey(const Key('routing-decision-candidate-agent-b')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('routing-decision-candidate-agent-a')),
      findsOneWidget,
    );
    expect(find.textContaining('priority 1'), findsOneWidget);
    expect(find.textContaining('not_ready'), findsOneWidget);
  });

  testWidgets('V-007-C/F distillation preview honors redaction', (
    tester,
  ) async {
    const raw =
        'Goal: ship the routing module with hot reload. SECRET_RAW_LINE';
    await tester.pumpWidget(
      _wrap(RoutingDistillationPreview(package: package, rawSourceText: raw)),
    );
    expect(
      find.byKey(const Key('routing-distillation-preview')),
      findsOneWidget,
    );
    expect(find.text('Ship routing disclosure.'), findsOneWidget);
    expect(find.textContaining('SECRET_RAW_LINE'), findsNothing);
    expect(find.textContaining(raw), findsNothing);
    expect(
      find.byKey(const Key('routing-distillation-source-refs')),
      findsOneWidget,
    );
  });

  testWidgets('V-007-D per-task route history', (tester) async {
    await tester.pumpWidget(_wrap(RoutingRouteHistoryPanel(entries: history)));
    expect(find.byKey(const Key('routing-route-history')), findsOneWidget);
    expect(find.textContaining('agent-a → agent-b'), findsOneWidget);
    expect(find.textContaining('agent-b'), findsWidgets);
  });

  test('V-007-E widgets import only routing contract types for data', () {
    final source = File(
      'lib/src/frontend/features/agents/ui/routing_disclosure_panels.dart',
    ).readAsStringSync();
    expect(source.contains('contracts/routing/'), isTrue);
    expect(source.contains('resolveAgentDispatchPlan'), isFalse);
    expect(source.contains('RoutePlanner'), isFalse);
    expect(source.contains('DefaultDistillationBroker'), isFalse);
  });
}
