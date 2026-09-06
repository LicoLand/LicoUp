// Manual visual-verification drive for the Dashboard navigation rebuild.
// Runs the full production app in a real macOS window and exercises the
// engine-level gestures that external visual verification cannot reach on a
// locked console: tapping 聊天频道/模型网关 for the distinct models panes and
// a real long-press drag reorder of the 功能 list.
//
// This file is inert in normal test runs: it returns immediately unless
// LICO_VISUAL_DRIVE=1 is set. Run it with:
//   LICO_VISUAL_DRIVE=1 flutter test \
//     integration_test/dashboard_visual_drive_test.dart \
//     -d macos
// MARK lines on stdout sync external `screencapture` shots.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:licoup/main.dart' as app;

Future<void> _waitForKey(
  WidgetTester tester,
  Key key, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(key).evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 500));
  }
  throw StateError('visual_drive_key_timeout:$key');
}

void main() {
  final driving = Platform.environment['LICO_VISUAL_DRIVE'] == '1';
  if (driving) {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  }

  testWidgets('dashboard navigation visual drive', (tester) async {
    app.main();
    var shellReady = true;
    try {
      await _waitForKey(tester, const Key('dashboard-desktop-shell'));
    } on StateError {
      shellReady = false;
    }
    if (!shellReady) {
      final bootException = tester.takeException();
      // ignore: avoid_print
      print('DIAG bootException: $bootException');
      // ignore: avoid_print
      print(
        'DIAG widgetsApp: ${find.byType(WidgetsApp).evaluate().length} '
        'materialApp: ${find.byType(MaterialApp).evaluate().length} '
        'scaffold: ${find.byType(Scaffold).evaluate().length} '
        'anyWidget: ${find.byType(Widget).evaluate().length}',
      );
      final texts = <String>[];
      for (final element in find.byType(Text).evaluate().take(40)) {
        final data = (element.widget as Text).data;
        if (data != null && data.isNotEmpty) {
          texts.add(data);
        }
      }
      // ignore: avoid_print
      print('DIAG texts: $texts');
      throw StateError('visual_drive_shell_missing');
    }
    await tester.pump(const Duration(seconds: 3));

    // The restored view is 智能体中心 (seeded current view), so the 功能
    // list is already on screen.
    await _waitForKey(
      tester,
      const Key('messaging-sidebar-list-chatChannels'),
    );
    // ignore: avoid_print
    print('MARK features-list');
    await tester.pump(const Duration(seconds: 8));

    // 聊天频道 opens the models destination on the chat-channels pane.
    await tester.tap(find.byKey(const Key('messaging-sidebar-list-chatChannels')));
    await tester.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('MARK chat-channels-pane');
    await tester.pump(const Duration(seconds: 8));

    // 模型网关 opens the same destination on the gateway pane.
    await tester.tap(find.byKey(const Key('messaging-sidebar-list-modelGateway')));
    await tester.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('MARK gateway-pane');
    await tester.pump(const Duration(seconds: 8));

    // Back to the 功能 list and long-press drag the first entry two rows
    // down; the custom order persists through dashboard-feature-order.json.
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump(const Duration(seconds: 2));
    final firstRow = find
        .byKey(const Key('messaging-sidebar-list-chatChannels'))
        .evaluate()
        .isNotEmpty
        ? find.byKey(const Key('messaging-sidebar-list-chatChannels'))
        : find.byKey(const Key('messaging-sidebar-list-agentHub'));
    await _waitForKey(tester, const Key('messaging-sidebar-feature-list'));
    final gesture = await tester.startGesture(tester.getCenter(firstRow));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
    // ignore: avoid_print
    print('MARK reordered');
    await tester.pump(const Duration(seconds: 8));

    // 对话 spot check: the conversation destination still renders.
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-conversations')));
    await tester.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('MARK conversations');
    await tester.pump(const Duration(seconds: 8));

    // ignore: avoid_print
    print('MARK done');
  }, skip: !driving);
}
