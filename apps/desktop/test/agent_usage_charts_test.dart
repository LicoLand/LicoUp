import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
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
              windowDays: 30,
              windowBusy: false,
              onWindowChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Codex'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('By Model'));
    await tester.pumpAndSettle();
    expect(find.text('GPT 5.5'), findsAtLeastNWidgets(1));
  });

  testWidgets('usage share combines forms from the same source product', (
    tester,
  ) async {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {'totalTokens': 120},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'kimi-code-cli',
          label: 'Kimi Code - CLI',
          status: 'detected',
          history: {'totalTokens': 70},
          confidence: 'high',
        ),
        AgentUsageAgentSummary(
          agentId: 'kimi-code-plugin',
          label: 'Kimi Code - Plugin',
          status: 'detected',
          history: {'totalTokens': 50},
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
              detectedAgentIds: const {'kimi-code-cli', 'kimi-code-plugin'},
              windowDays: 30,
              windowBusy: false,
              onWindowChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final tokenShare = find.byKey(const ValueKey('agent-usage-token-share'));
    expect(
      find.descendant(of: tokenShare, matching: find.text('Kimi Code')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('120')),
      findsNWidgets(2),
    );
    expect(find.text('Kimi Code - CLI'), findsNothing);
    expect(find.text('Kimi Code - Plugin'), findsNothing);
  });

  testWidgets('usage share lists every detected agent beyond the old row cap', (
    tester,
  ) async {
    const fallbackAgents = <(String, String)>[
      ('antigravity', 'Antigravity'),
      ('copilot', 'GitHub Copilot'),
      ('cursor', 'Cursor'),
      ('pi', 'Pi Agent'),
    ];
    const unavailableAgents = <(String, String)>[
      ('claude-code', 'Claude Code'),
      ('hermes', 'Hermes Agent'),
      ('kilo-code', 'Kilo Code'),
      ('openclaw', 'OpenClaw'),
      ('opencode', 'OpenCode'),
    ];
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {'totalTokens': 140},
      agents: [
        const AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {'totalTokens': 120},
          confidence: 'high',
        ),
        for (final agent in fallbackAgents)
          AgentUsageAgentSummary(
            agentId: agent.$1,
            label: agent.$2,
            status: 'detected',
            history: const {'totalTokens': 5},
            confidence: 'low',
          ),
        for (final agent in unavailableAgents)
          AgentUsageAgentSummary(
            agentId: agent.$1,
            label: agent.$2,
            status: 'detected',
            history: const {},
            confidence: 'unavailable',
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
              detectedAgentIds: {
                'codex',
                for (final agent in fallbackAgents) agent.$1,
                for (final agent in unavailableAgents) agent.$1,
              },
              windowDays: 30,
              windowBusy: false,
              onWindowChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final tokenShare = find.byKey(const ValueKey('agent-usage-token-share'));
    for (final agent in [...fallbackAgents, ...unavailableAgents]) {
      expect(
        find.descendant(of: tokenShare, matching: find.text(agent.$2)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: tokenShare, matching: find.text('5')),
      findsNWidgets(fallbackAgents.length),
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Unavailable')),
      findsNWidgets(unavailableAgents.length),
    );
    expect(
      find.descendant(
        of: tokenShare,
        matching: find.textContaining('Estimate'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.textContaining('≈')),
      findsNothing,
    );
  });
}

String _todayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}
