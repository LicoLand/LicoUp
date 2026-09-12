import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/platform/presentation/macos_reduce_motion_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native motion subscription forwards changes and releases channel',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(MacosReduceMotionChannel.channelName);
      final methods = <String>[];
      final listening = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'listen') listening.complete();
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final values = <bool>[];
      final subscription = const MacosReduceMotionChannel().changes.listen(
        values.add,
      );
      await listening.future;
      for (final value in [true, true, false]) {
        await messenger.handlePlatformMessage(
          MacosReduceMotionChannel.channelName,
          const StandardMethodCodec().encodeSuccessEnvelope(value),
          (_) {},
        );
      }
      expect(values, [true, false]);
      await subscription.cancel();
      expect(methods, ['listen', 'cancel']);
    },
  );
}
