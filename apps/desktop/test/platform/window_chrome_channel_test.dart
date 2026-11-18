import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/platform/window_chrome/window_chrome_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(windowChromeChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('setTrafficLightAnchor maps a map reply to cluster edges', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setTrafficLightAnchor') {
        return <String, num>{'leading': 20, 'trailing': 92};
      }
      return null;
    });

    final edges = await WindowChromeChannel.instance.setTrafficLightAnchor(
      const Rect.fromLTWH(0, 0, 72, 52),
    );
    expect(edges, isNotNull);
    expect(edges!.leading, 20);
    expect(edges.trailing, 92);
  });

  test('setTrafficLightAnchor resolves null for non-map replies', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setTrafficLightAnchor') {
        return 92.0;
      }
      return null;
    });

    final edges = await WindowChromeChannel.instance.setTrafficLightAnchor(
      const Rect.fromLTWH(0, 0, 72, 52),
    );
    expect(edges, isNull);
  });

  test(
    'setTrafficLightAnchor resolves null without a native handler',
    () async {
      final edges = await WindowChromeChannel.instance.setTrafficLightAnchor(
        const Rect.fromLTWH(0, 0, 72, 52),
      );
      expect(edges, isNull);
    },
  );
}
