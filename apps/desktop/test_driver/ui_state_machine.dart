import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final directory = Directory('../../build/reports/ui-state-machine')
      ..createSync(recursive: true);
    File(
      '${directory.path}/profile.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  },
  writeResponseOnFailure: true,
);
