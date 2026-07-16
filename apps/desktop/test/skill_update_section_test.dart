import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_update_section.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'update section exposes repository, mirror and explicit actions',
    (tester) async {
      final agent = TextEditingController(text: 'codex');
      final root = TextEditingController();
      addTearDown(agent.dispose);
      addTearDown(root.dispose);

      await tester.pumpWidget(
        _App(
          child: SkillUpdateSection(
            controller: _UpdateViewModel(),
            agentController: agent,
            installRootController: root,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('skill-update-github')), findsOneWidget);
      expect(find.byKey(const ValueKey('skill-update-mirror')), findsOneWidget);
      expect(find.text('Preview update'), findsOneWidget);
      expect(find.text('Confirm update'), findsOneWidget);
      expect(find.text('Enable automatic updates'), findsOneWidget);
      expect(find.text('Run configured updates now'), findsOneWidget);
    },
  );
}

class _App extends StatelessWidget {
  const _App({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

class _UpdateViewModel implements SkillUpdateViewModel {
  @override
  bool isSkillUpdateBusy = true;

  @override
  Map<String, dynamic>? skillUpdatePlan;

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
}
