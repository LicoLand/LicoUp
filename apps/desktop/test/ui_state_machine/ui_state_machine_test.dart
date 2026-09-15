import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'model.dart';
import 'runner.dart';

void main() {
  final model = UiInteractionModel.load();
  final run = UiInteractionRun(model, performance: false);
  tearDownAll(() {
    final directory = Directory('../../build/reports/ui-state-machine')
      ..createSync(recursive: true);
    File('${directory.path}/widget.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(run.report()),
    );
  });
  for (final machine in model.machines.where(run.selects)) {
    testWidgets('${machine.id}: every visible transition', (tester) async {
      await run.exercise(tester, machine);
    });
  }
}
