import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/plan_document_reader.dart';
import 'package:licoup/src/frontend/features/agents/ui/lico_plan_document_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('plan panel renders injected platform content and refreshes', (
    tester,
  ) async {
    final reader = _PlanReader(['first plan', 'second plan']);

    await tester.pumpWidget(_app(reader));
    await tester.pumpAndSettle();
    expect(find.text('first plan'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lico-plan-doc-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('second plan'), findsOneWidget);
    expect(reader.paths, ['plan.md', 'plan.md']);
  });

  testWidgets('plan panel keeps its unavailable state on reader failure', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_PlanReader.error()));
    await tester.pumpAndSettle();

    expect(find.text('The plan file could not be read.'), findsOneWidget);
  });
}

Widget _app(PlanDocumentReader reader) => MaterialApp(
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(platformBrightness: Brightness.dark),
  home: SizedBox(
    width: 500,
    height: 400,
    child: LicoPlanDocumentPanel(planPath: 'plan.md', reader: reader),
  ),
);

final class _PlanReader implements PlanDocumentReader {
  _PlanReader(this.values) : failure = false;
  _PlanReader.error() : values = const [], failure = true;

  final List<String> values;
  final bool failure;
  final paths = <String>[];
  int _index = 0;

  @override
  Future<String> read(String path) async {
    paths.add(path);
    if (failure) throw const FormatException('plan_document_invalid');
    final index = _index < values.length ? _index : values.length - 1;
    _index += 1;
    return values[index];
  }
}
