import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_management_section.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'management UI exposes sources, multi-agent removal and windows',
    (tester) async {
      final controller = _ViewModel();
      final agentController = TextEditingController(text: 'codex');
      final installRootController = TextEditingController();
      addTearDown(agentController.dispose);
      addTearDown(installRootController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Scaffold(
            body: SingleChildScrollView(
              child: SkillManagementSection(
                updateController: controller,
                deleteController: controller,
                usageController: controller,
                agentController: agentController,
                installRootController: installRootController,
                agentOptions: const ['codex', 'claude-code'],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Skill updates, removal, and usage'), findsOneWidget);
      expect(find.text('Manual and automatic updates'), findsOneWidget);
      expect(find.byKey(const ValueKey('skill-update-github')), findsOneWidget);
      expect(find.byKey(const ValueKey('skill-update-mirror')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('skill-delete-agent-codex')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('skill-delete-agent-claude-code')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('skill-usage-window')), findsOneWidget);
      expect(find.text('Run configured updates now'), findsOneWidget);
    },
  );
}

class _ViewModel
    implements SkillUpdateViewModel, SkillDeleteViewModel, SkillUsageViewModel {
  @override
  bool isSkillUpdateBusy = true;

  @override
  bool isSkillDeleteBusy = true;

  @override
  bool isSkillUsageBusy = true;

  @override
  Map<String, dynamic>? skillUpdatePlan;

  @override
  Map<String, dynamic>? skillDeletePlan;

  @override
  Map<String, dynamic>? skillUsageReport;

  @override
  Future<void> previewSkillUpdate({
    required String agent,
    required String skillId,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) async {}

  @override
  Future<void> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) async {}

  @override
  Future<void> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String githubUrl = '',
    String mirrorPath = '',
  }) async {}

  @override
  Future<void> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) async {}

  @override
  Future<void> previewSkillDelete({
    required Iterable<String> agents,
    required String skillId,
    String installRoot = '',
  }) async {}

  @override
  Future<void> applySkillDelete({
    required Iterable<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) async {}

  @override
  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async {}
}
