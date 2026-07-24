import 'package:flutter/services.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void registerMobileRelayIosBridgeScenarios() {
  test('reads iOS Secure Mesh runtime bridge status and native JSON', () async {
    const channel = MethodChannel(secureMeshIosChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'nativeJson') {
        final request = Map<String, dynamic>.from(call.arguments as Map);
        return {'ok': true, 'action': request['action'], 'platform': 'ios'};
      }
      expect(call.method, 'status');
      return {
        'ok': true,
        'protocolVersion': 'licomesh.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'ios',
        'bridge': {
          'methodChannel': secureMeshIosChannelName,
          'statusMethod': true,
          'nativeJsonMethod': true,
        },
        'secureStore': {'provider': 'iOS Keychain', 'available': true},
        'nativeRuntime': {'usesSharedRustCore': true},
        'productionReady': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const bridge = SecureMeshIosBridge(channel: channel);
    final status = await bridge.status();
    final native = await bridge.nativeJson({
      'action': 'mobile.relay.e2ee.status',
      'params': const {},
    });

    expect(status['ok'], isTrue);
    expect(status['platform'], 'ios');
    expect(status['bridge']['methodChannel'], secureMeshIosChannelName);
    expect(status['secureStore']['provider'], 'iOS Keychain');
    expect(status['nativeRuntime']['usesSharedRustCore'], isTrue);
    expect(native['ok'], isTrue);
    expect(native['action'], 'mobile.relay.e2ee.status');
    expect(native['platform'], 'ios');
    expect(calls, ['status', 'nativeJson']);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayIosBridgeScenarios();
}
