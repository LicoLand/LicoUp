import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Secure Mesh facade delegates bounded single-purpose components', () {
    const root = 'lib/src/application/features/mobile_relay/controller';
    const componentFiles = [
      'secure_mesh_status_controller.dart',
      'secure_mesh_file_transfer_controller.dart',
      'secure_mesh_skill_transfer_controller.dart',
      'secure_mesh_approval_controller.dart',
      'secure_mesh_protocol_controller.dart',
    ];
    final facade = File('$root/secure_mesh_controller.dart').readAsStringSync();

    expect(facade.split('\n').length, lessThan(360));
    for (final fileName in componentFiles) {
      final source = File('$root/$fileName').readAsStringSync();
      expect(facade, contains(fileName));
      expect(source.split('\n').length, lessThan(450));
      expect(source, isNot(contains('client_controller.dart')));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }

    final status = File(
      '$root/secure_mesh_status_controller.dart',
    ).readAsStringSync();
    final file = File(
      '$root/secure_mesh_file_transfer_controller.dart',
    ).readAsStringSync();
    final skill = File(
      '$root/secure_mesh_skill_transfer_controller.dart',
    ).readAsStringSync();
    final approval = File(
      '$root/secure_mesh_approval_controller.dart',
    ).readAsStringSync();
    final protocol = File(
      '$root/secure_mesh_protocol_controller.dart',
    ).readAsStringSync();

    expect(status, isNot(contains('secure_mesh_file_transfer_controller')));
    expect(file, isNot(contains('secure_mesh_skill_transfer_controller')));
    expect(file, isNot(contains('secure_mesh_approval_controller')));
    expect(skill, contains('secure_mesh_file_transfer_controller.dart'));
    expect(skill, isNot(contains('secure_mesh_approval_controller')));
    expect(approval, isNot(contains('secure_mesh_file_transfer_controller')));
    expect(protocol, isNot(contains('secure_mesh_file_transfer_controller')));
    expect(protocol, isNot(contains('secure_mesh_approval_controller')));

    expect(facade, isNot(contains('SecureMeshPolicy.')));
    expect(facade, isNot(contains('evaluateFileReceiveConfirmation(')));
    expect(facade, isNot(contains('evaluateApprovalFanout(')));
  });
}
