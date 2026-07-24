import 'package:flutter/services.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('typed Secure Mesh bridge preserves public result fields', () async {
    const channel = MethodChannel('secure-mesh-contract');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <Map<String, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final request = Map<String, Object?>.from(call.arguments as Map);
      requests.add(request);
      if (request['action'] == 'secure_mesh.kt.status') {
        return <String, Object?>{
          'ok': true,
          'privateKeyMaterial': 'unit-test-secret',
        };
      }
      return <String, Object?>{
        'ok': true,
        'protocolVersion': 'licomesh.secure-mesh.v1',
        'productionReady': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final bridge = SecureMeshMobileBridge(
      channel: channel,
      platform: 'test',
      unavailableCode: 'secure_mesh_unavailable',
      unavailableMessage: 'Secure Mesh unavailable.',
    );
    final result = await bridge.execute(
      SecureMeshRequest(
        action: SecureMeshAction.secureMeshStatus,
        params: const <String, Object?>{},
      ),
    );
    expect(result.ok, isTrue);
    expect(result.protocolVersion, 'licomesh.secure-mesh.v1');
    expect(requests.single['action'], 'secure_mesh.status');

    await expectLater(
      bridge.execute(
        SecureMeshRequest(
          action: SecureMeshAction.ktStatus,
          params: const <String, Object?>{},
        ),
      ),
      throwsA(
        isA<SecureMeshFailure>().having(
          (failure) => failure.code,
          'code',
          SecureMeshFailureCode.forbiddenSecretMaterial,
        ),
      ),
    );
    expect(requests.last.toString(), isNot(contains('unit-test-secret')));
  });

  test('generated request rejects secret-bearing parameters before dispatch', () {
    expect(
      () => SecureMeshRequest(
        action: SecureMeshAction.ktStatus,
        params: const <String, Object?>{
          'privateKey': 'unit-test-secret',
        },
      ),
      throwsA(
        isA<SecureMeshFailure>().having(
          (failure) => failure.code,
          'code',
          SecureMeshFailureCode.forbiddenSecretMaterial,
        ),
      ),
    );
  });
}
