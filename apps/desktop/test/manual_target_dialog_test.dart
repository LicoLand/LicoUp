import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/features/targets/ui/manual_target_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ManualTargetDialog submits trimmed draft and supports cancel', (
    tester,
  ) async {
    ManualTargetDraft? draft;
    bool dialogCanceled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                ElevatedButton(
                  onPressed: () async {
                    draft = await showDialog<ManualTargetDraft>(
                      context: context,
                      builder: (_) => const ManualTargetDialog(),
                    );
                  },
                  child: const Text('Open'),
                ),
                ElevatedButton(
                  onPressed: () {
                    showDialog<ManualTargetDraft>(
                      context: context,
                      builder: (_) => const ManualTargetDialog(),
                    ).then((value) {
                      if (value == null) {
                        dialogCanceled = true;
                      }
                    });
                  },
                  child: const Text('OpenCancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField).at(0));
    await tester.enterText(find.byType(TextField).at(0), ' test-data/config.json ');
    await tester.tap(find.byType(TextField).at(1));
    await tester.enterText(
      find.byType(TextField).at(1),
      ' ${['', 'opt', 'tools', 'kimi'].join('/')} ',
    );
    await tester.tap(find.byType(TextField).at(2));
    await tester.enterText(
      find.byType(TextField).at(2),
      ' test-data/native-history ',
    );

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    expect(find.text('Kimi'), findsOneWidget);
    await tester.tap(find.text('Kimi Code').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('manual-target-submit')));
    await tester.pumpAndSettle();

    expect(draft, isNotNull);
    expect(draft?.target, 'kimi-code');
    expect(draft?.configPath, 'test-data/config.json');
    expect(draft?.binaryPath, ['', 'opt', 'tools', 'kimi'].join('/'));
    expect(draft?.historyRoot, 'test-data/native-history');

    await tester.tap(find.text('OpenCancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-target-cancel')));
    await tester.pumpAndSettle();

    expect(dialogCanceled, isTrue);
  });
}
