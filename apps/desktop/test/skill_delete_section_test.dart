import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_delete_section.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('delete section independently exposes multi-agent selection', (
    tester,
  ) async {
    final agent = TextEditingController(text: 'codex');
    final root = TextEditingController();
    addTearDown(agent.dispose);
    addTearDown(root.dispose);

    await tester.pumpWidget(
      _App(
        child: SkillDeleteSection(
          controller: _DeleteViewModel(),
          agentController: agent,
          installRootController: root,
          agentOptions: const ['codex', 'claude-code'],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('skill-delete-skill-id')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('skill-delete-agent-codex')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('skill-delete-agent-claude-code')),
      findsOneWidget,
    );
    expect(find.text('Preview removal'), findsOneWidget);
    expect(find.text('Confirm removal'), findsOneWidget);
  });
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

class _DeleteViewModel implements SkillDeleteViewModel {
  @override
  bool isSkillDeleteBusy = true;

  @override
  Map<String, dynamic>? skillDeletePlan;

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
}
