import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_usage_section.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('usage section independently exposes selectable time window', (
    tester,
  ) async {
    final agent = TextEditingController(text: 'codex');
    addTearDown(agent.dispose);

    await tester.pumpWidget(
      _App(
        child: SkillUsageSection(
          controller: _UsageViewModel(),
          agentController: agent,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('skill-usage-skill-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('skill-usage-window')), findsOneWidget);
    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('Load invocation frequency'), findsOneWidget);
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

class _UsageViewModel implements SkillUsageViewModel {
  @override
  bool isSkillUsageBusy = true;

  @override
  Map<String, dynamic>? skillUsageReport;

  @override
  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async {}
}
