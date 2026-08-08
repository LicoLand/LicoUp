import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('card footer shows the all-time count joined by normalized id', (
    tester,
  ) async {
    final controller = _usageController(
      skills: const [
        {
          'skillId': 'MySkill',
          'title': 'MySkill',
          'description': 'Counts.',
          'version': '1.0.0',
          'isPublic': false,
          'path': '/skills/myskill',
          'usedByAgents': <String>[],
        },
        {
          'skillId': 'quiet-skill',
          'title': 'Quiet Skill',
          'description': 'No invocations.',
          'version': 'local',
          'isPublic': false,
          'path': '/skills/quiet-skill',
          'usedByAgents': <String>[],
        },
      ],
      report: _usageReport(),
    );
    addTearDown(controller.dispose);
    await _pumpSkillHub(tester, controller: controller);

    // The ledger lowercases ids; the catalog preserves case and still joins.
    expect(find.byKey(const Key('skill-card-invocations')), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(_hasTooltip(tester, '42 invocations'), isTrue);
    // Zero-count skills never grow a noisy chip.
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card footer stays hidden while the report is absent', (
    tester,
  ) async {
    final controller = _usageController(
      skills: const [
        {
          'skillId': 'MySkill',
          'title': 'MySkill',
          'description': 'Counts.',
          'version': '1.0.0',
          'isPublic': false,
          'path': '/skills/myskill',
          'usedByAgents': <String>[],
        },
      ],
    );
    addTearDown(controller.dispose);
    await _pumpSkillHub(tester, controller: controller);

    expect(find.byKey(const Key('skill-card-invocations')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail dialog lists all-time and windowed invocations', (
    tester,
  ) async {
    final controller = _usageController(
      skills: const [
        {
          'skillId': 'MySkill',
          'title': 'MySkill',
          'description': 'Counts.',
          'version': '1.0.0',
          'isPublic': false,
          'path': '/skills/myskill',
          'usedByAgents': <String>[],
        },
      ],
      report: _usageReport(),
    );
    addTearDown(controller.dispose);
    await _pumpSkillHub(tester, controller: controller);

    await tester.tap(find.text('MySkill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const Key('skill-detail-all-time-invocations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('skill-detail-windowed-invocations')),
      findsOneWidget,
    );
    expect(find.text('All-time invocations: 42'), findsOneWidget);
    expect(find.text('Last 30 days: 7'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail dialog hides invocation rows without a report', (
    tester,
  ) async {
    final controller = _usageController(
      skills: const [
        {
          'skillId': 'MySkill',
          'title': 'MySkill',
          'description': 'Counts.',
          'version': '1.0.0',
          'isPublic': false,
          'path': '/skills/myskill',
          'usedByAgents': <String>[],
        },
      ],
    );
    addTearDown(controller.dispose);
    await _pumpSkillHub(tester, controller: controller);

    await tester.tap(find.text('MySkill'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const Key('skill-detail-all-time-invocations')),
      findsNothing,
    );
    expect(find.text('Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _usageReport() => <String, dynamic>{
  'ok': true,
  'totalInvocations': 7,
  'allTimeInvocations': 42,
  'bySkill': const [
    {'skillId': 'myskill', 'count': 7},
  ],
  'totalsBySkill': const [
    {'skillId': 'myskill', 'count': 42},
  ],
};

class _FakeUsageGateway implements SkillUsageGateway {
  @override
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async => _usageReport();

  @override
  Future<Map<String, dynamic>> scanSkillUsage({
    String agent = '',
    bool forceRefresh = false,
  }) async => {'ok': true};
}

ClientController _usageController({
  required List<Map<String, dynamic>> skills,
  Map<String, dynamic>? report,
}) {
  final controller = ClientController(skillUsageGateway: _FakeUsageGateway())
    ..isSkillHubBusy = true
    ..scannedTargets = const []
    ..skillHubSkills = skills;
  controller.skillUsageController.report = report;
  return controller;
}

Future<void> _pumpSkillHub(
  WidgetTester tester, {
  required ClientController controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 650,
          child: SkillHubPanel(controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

bool _hasTooltip(WidgetTester tester, String message) {
  return tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .any((tooltip) => tooltip.message == message);
}
