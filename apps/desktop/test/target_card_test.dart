import 'package:flutter/material.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/ui/target_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('TargetCard displays status labels and callbacks', (
    tester,
  ) async {
    final inspected = <String>[];
    final planned = <String>[];

    final candidates = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw',
        kind: 'cli',
        status: 'configured',
        configured: false,
        confidence: 0.2,
        adapterStatus: 'not-ready',
      ),
      TargetCandidate(
        target: 'antigravity',
        label: 'Antigravity',
        kind: 'cli',
        status: 'manual',
        configured: false,
        confidence: 0.2,
        manual: true,
        adapterStatus: 'manual',
      ),
      TargetCandidate(
        target: 'ghost',
        label: 'Ghost',
        kind: 'cli',
        status: 'missing',
        configured: false,
        confidence: 0.2,
        adapterStatus: 'missing',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final candidate in candidates)
                  TargetCard(
                    target: candidate,
                    onInspect: inspected.add,
                    onPlan: planned.add,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Detected'), findsOneWidget);
    expect(find.text('Configured'), findsAtLeastNWidgets(2));
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.byType(Image), findsAtLeastNWidgets(3));

    await tester.tap(find.text('Inspect').at(0));
    await tester.pump();
    await tester.tap(find.text('Plan').at(0));
    await tester.pump();

    expect(inspected, isNotEmpty);
    expect(planned, isNotEmpty);
    expect(inspected, ['codex']);
    expect(planned, ['codex']);
  });
}
