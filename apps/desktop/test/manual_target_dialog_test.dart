import 'package:flutter/material.dart';
import 'package:flutter_client/src/ui/manual_target_dialog.dart';
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
    await tester.enterText(find.byType(TextField).at(0), ' /tmp/config.json ');
    await tester.tap(find.byType(TextField).at(1));
    await tester.enterText(find.byType(TextField).at(1), ' /usr/bin/code ');
    await tester.tap(find.byType(TextField).at(2));
    await tester.enterText(
      find.byType(TextField).at(2),
      ' /tmp/native-history ',
    );

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('manual-target-submit')));
    await tester.pumpAndSettle();

    expect(draft, isNotNull);
    expect(draft?.target, 'claude-code');
    expect(draft?.configPath, '/tmp/config.json');
    expect(draft?.binaryPath, '/usr/bin/code');
    expect(draft?.historyRoot, '/tmp/native-history');

    await tester.tap(find.text('OpenCancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-target-cancel')));
    await tester.pumpAndSettle();

    expect(dialogCanceled, isTrue);
  });
}
