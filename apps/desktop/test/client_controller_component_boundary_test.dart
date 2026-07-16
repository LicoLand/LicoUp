import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'client controller delegates component construction to its assembly',
    () {
      final root = File(
        'lib/src/application/controller/client_controller.dart',
      ).readAsStringSync();
      final assembly = File(
        'lib/src/application/controller/client_component_assembly.dart',
      ).readAsStringSync();

      expect(root.split('\n').length, lessThan(800));
      expect(assembly.split('\n').length, lessThan(500));
      expect(root, contains('ClientComponentAssembly('));
      for (final directConstruction in [
        'TargetController(',
        'SecureMeshController(',
        'ClientNavigationController(',
      ]) {
        expect(root, isNot(contains(directConstruction)));
      }
      expect(assembly, isNot(contains('client_controller.dart')));
      expect(
        assembly,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    },
  );
}
