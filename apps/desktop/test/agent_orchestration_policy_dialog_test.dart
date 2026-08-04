import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'adaptive flywheel shows shared Designer and lane-specific Worker and Reviewer roles',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [_codexTarget()];
      AgentOrchestrationPolicy? result;

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
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showDialog<AgentOrchestrationPolicy>(
                    context: context,
                    builder: (context) =>
                        AgentOrchestrationPolicyDialog(controller: controller),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('适应性飞轮'), findsOneWidget);
      expect(find.text('主智能体'), findsOneWidget);
      expect(find.text('代码工程'), findsOneWidget);
      expect(find.text('Designer'), findsOneWidget);
      expect(find.text('Worker'), findsOneWidget);
      expect(find.text('Reviewer'), findsOneWidget);
      expect(find.text('后端线'), findsNWidgets(2));
      expect(find.text('前端线'), findsNWidgets(2));
      for (final role in CodeEngineeringRoleSlot.values) {
        expect(
          find.byKey(Key('agent-orchestration-code-${role.configKey}-agent')),
          findsOneWidget,
        );
      }

      await tester.tap(find.byKey(const Key('main-agent-save')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.codeEngineeringConfigured, isTrue);
    },
  );
}

TargetCandidate _codexTarget() {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/synthetic/bin/codex',
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationDriver': 'implemented'},
    modelCatalog: const {
      'models': [
        {
          'name': 'gpt-5',
          'displayName': 'GPT-5',
          'reasoningEfforts': ['medium', 'high'],
        },
      ],
    },
  );
}
