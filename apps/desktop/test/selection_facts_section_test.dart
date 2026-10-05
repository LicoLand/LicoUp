import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/models/selection/selection_facts_section.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/model_selection/model_selection_projection.dart';

/// The document the native catalogue renders, with the two facts this surface
/// exists to keep apart: the same Agent is allowed for a direct request and
/// blocked for a workflow turn.
Map<String, dynamic> _document() => <String, dynamic>{
  'schemaVersion': 1,
  'scopes': ['direct', 'workflow'],
  'agent': 'kimi-code',
  'generation': 'generation-1',
  'observedAtUnixMs': 1726000000000,
  'entries': [
    {
      'agent': 'kimi-code',
      'model': 'k3-256k',
      'canonicalId': 'moonshotai/kimi-k3',
      'canonicalDisplayName': 'Kimi K3',
      'evidence': 'observed',
      'support': {'state': 'supported', 'reason': 'declared_identity'},
      'availability': {
        'state': 'observed',
        'reason': 'observed_by_live_source',
        'observedAtUnixMs': 1726000000000,
      },
      'credentials': {
        'state': 'present',
        'reason': 'provider_credential_present',
      },
      'providers': ['kimi-for-coding'],
      'scopes': [
        {
          'scope': 'direct',
          'state': 'allowed',
          'reason': 'direct_request_admitted',
        },
        {
          'scope': 'workflow',
          'state': 'blocked',
          'reason': 'workflow_policy_disallows_agent',
        },
      ],
    },
  ],
};

Future<void> _pump(WidgetTester tester, ModelSelectionProjection projection) =>
    tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SelectionFactsSection(projection: projection),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the four dimensions are rendered with their reason codes', (
    tester,
  ) async {
    await _pump(
      tester,
      ModelSelectionProjection.fromDocument(_document(), agent: 'kimi-code'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selection-facts-title')), findsOneWidget);
    // Support, availability, credential and each scope keep their own reason
    // code; none is collapsed into one readiness badge.
    expect(find.textContaining('declared_identity'), findsOneWidget);
    expect(find.textContaining('observed_by_live_source'), findsOneWidget);
    expect(find.textContaining('provider_credential_present'), findsOneWidget);
    expect(find.textContaining('direct_request_admitted'), findsOneWidget);
    expect(find.textContaining('workflow_policy_disallows_agent'), findsOneWidget);
  });

  testWidgets('an unreadable document renders a failure, not an empty success', (
    tester,
  ) async {
    await _pump(
      tester,
      ModelSelectionProjection.fromDocument(null, agent: 'kimi-code'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selection-facts-notice')), findsOneWidget);
    expect(
      find.textContaining('model_selection_unavailable'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selection-facts-empty')), findsNothing);
  });

  testWidgets('a read in progress renders a loading state', (tester) async {
    await _pump(
      tester,
      ModelSelectionProjection(
        agent: 'kimi-code',
        entries: const [],
        phase: PresentationPhase.loading,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selection-facts-loading')), findsOneWidget);
  });

  testWidgets('an empty but readable projection says so', (tester) async {
    await _pump(
      tester,
      ModelSelectionProjection(
        agent: 'kimi-code',
        entries: const [],
        phase: PresentationPhase.ready,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selection-facts-empty')), findsOneWidget);
  });
}
