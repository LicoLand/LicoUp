import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/proxy_bridge_settings_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proxy bridge exposes Kimi Code CLI without the Kimi desktop alias', () {
    final controller = ClientController();
    addTearDown(controller.dispose);

    expect(controller.proxyBridgeAvailableTargets, contains('kimi-code'));
    expect(controller.proxyBridgeAvailableTargets, isNot(contains('kimi')));
    expect(proxyBridgeTargetLabel('kimi-code'), 'Kimi Code - CLI');
  });

  test('proxy bridge ignores a persisted obsolete Kimi CLI target id', () {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.proxyBridgeStatus = {
      'document': {
        'targets': [
          {'target': 'kimi'},
          {'target': 'kimi-code'},
        ],
      },
    };

    expect(controller.isProxyBridgeTargetSelected('kimi'), isFalse);
    expect(controller.isProxyBridgeTargetSelected('kimi-code'), isTrue);
  });

  test('proxy bridge display labels describe the actual surface', () {
    expect(proxyBridgeTargetLabel('codex'), 'ChatGPT Codex - CLI');
    expect(proxyBridgeTargetLabel('cursor'), 'Cursor - IDE');
    expect(proxyBridgeTargetLabel('code'), 'Visual Studio Code - IDE');
  });
}
