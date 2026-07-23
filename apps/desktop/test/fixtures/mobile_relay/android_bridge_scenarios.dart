import 'package:flutter/services.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void registerMobileRelayAndroidBridgeScenarios() {
  test('reads Android Secure Mesh runtime bridge status', () async {
    const channel = MethodChannel(secureMeshAndroidChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'writeRuntimeStatus') {
        return {
          'ok': true,
          'relativePath': 'files/secure-mesh/android-runtime-status.json',
          'writtenByAppProcess': true,
        };
      }
      expect(call.method, 'status');
      return {
        'ok': true,
        'protocolVersion': 'licomesh.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'android',
        'bridge': {
          'methodChannel': secureMeshAndroidChannelName,
          'statusMethod': true,
          'writeRuntimeStatusMethod': true,
        },
        'secureStore': {'provider': 'AndroidKeyStore', 'available': true},
        'runtimeStatusFile': {
          'relativePath': 'files/secure-mesh/android-runtime-status.json',
          'appPrivateFilesDir': true,
        },
        'productionReady': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const service = MobileRelayService();
    final status = await service.secureMeshAndroidRuntimeStatus(
      bridge: const SecureMeshAndroidBridge(channel: channel),
    );
    final written = await service.writeSecureMeshAndroidRuntimeStatus(
      bridge: const SecureMeshAndroidBridge(channel: channel),
    );

    expect(status['ok'], isTrue);
    expect(status['protocolVersion'], 'licomesh.secure-mesh.v1');
    expect(status['bridge']['methodChannel'], secureMeshAndroidChannelName);
    expect(status['secureStore']['provider'], 'AndroidKeyStore');
    expect(
      status['runtimeStatusFile']['relativePath'],
      'files/secure-mesh/android-runtime-status.json',
    );
    expect(written['ok'], isTrue);
    expect(written['writtenByAppProcess'], isTrue);
    expect(calls, ['status', 'writeRuntimeStatus']);
    expect(status['productionReady'], isFalse);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayAndroidBridgeScenarios();
}
