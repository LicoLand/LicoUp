import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('usage charts switch between agent and model summaries', (
    tester,
  ) async {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {'totalTokens': 120},
      agents: [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 120,
            'dailyUsage': [
              {
                'date': _todayKey(),
                'totalTokens': 120,
                'modelUsage': {'gpt-5.5': 120},
              },
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: SingleChildScrollView(
          child: SizedBox(
            width: 900,
            child: AgentUsageCharts(
              report: report,
              detectedAgentIds: const {'codex'},
            ),
          ),
        ),
      ),
    );

    expect(find.text('ChatGPT - Desktop'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('By Model'));
    await tester.pumpAndSettle();
    expect(find.text('GPT 5.5'), findsAtLeastNWidgets(1));
  });
}

String _todayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}
