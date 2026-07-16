import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/platform/mobile_relay';
  const componentPaths = <String>[
    '$root/mobile_relay_config_projector.dart',
    '$root/mobile_relay_native_dispatch.dart',
    '$root/mobile_relay_service_ops.dart',
    '$root/mobile_relay_secure_conversation_operations.dart',
    '$root/mobile_relay_secure_result_reducer.dart',
    '$root/secure_mesh_protocol_operations.dart',
    '$root/secure_mesh_substrate_operations.dart',
  ];

  test('mobile relay components are normal import libraries', () {
    for (final path in <String>[
      '$root/mobile_relay_service.dart',
      '$root/mobile_relay_secure_mesh_service.dart',
      ...componentPaths,
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
        isFalse,
        reason: path,
      );
    }
  });

  test('components never reverse-import either compatibility facade', () {
    for (final path in componentPaths) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('/mobile_relay_service.dart')),
        reason: path,
      );
      expect(
        source,
        isNot(contains('/mobile_relay_secure_mesh_service.dart')),
        reason: path,
      );
    }
  });

  test(
    'ordinary, conversation, protocol, substrate, and reducer stay isolated',
    () {
      final ordinary = _source('$root/mobile_relay_service_ops.dart');
      final conversation = _source(
        '$root/mobile_relay_secure_conversation_operations.dart',
      );
      final reducer = _source('$root/mobile_relay_secure_result_reducer.dart');
      final protocol = _source('$root/secure_mesh_protocol_operations.dart');
      final substrate = _source('$root/secure_mesh_substrate_operations.dart');

      expect(ordinary, isNot(contains('SecureMeshKt')));
      expect(ordinary, isNot(contains('SecureMeshMls')));
      expect(ordinary, isNot(contains('secure_mesh.file')));
      expect(conversation, isNot(contains('SecureMeshKt')));
      expect(conversation, isNot(contains('SecureMeshMls')));
      expect(conversation, isNot(contains('secure_mesh.file')));
      expect(protocol, isNot(contains('secure_mesh.file')));
      expect(protocol, isNot(contains('secure_mesh.approval')));
      expect(substrate, isNot(contains('SecureMeshKt')));
      expect(substrate, isNot(contains('SecureMeshMls')));
      expect(reducer, isNot(contains("package:flutter_client/")));
    },
  );

  test('facades are bounded explicit composition roots', () {
    final facade = _source('$root/mobile_relay_service.dart');
    final secureFacade = _source('$root/mobile_relay_secure_mesh_service.dart');

    expect(facade.split('\n').length, lessThanOrEqualTo(500));
    expect(facade, contains('MobileRelayOperations'));
    expect(facade, contains('MobileRelaySecureMeshOperations'));
    expect(secureFacade.split('\n').length, lessThanOrEqualTo(300));
    expect(secureFacade, contains('MobileRelaySecureConversationOperations'));
    expect(secureFacade, contains('SecureMeshProtocolOperations'));
    expect(secureFacade, contains('SecureMeshSubstrateOperations'));
  });
}

String _source(String path) => File(path).readAsStringSync();
