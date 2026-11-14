import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/lico_ambient_clock.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the clock ticks at the ambient cadence only while acquired', () async {
    final clock = LicoAmbientClock.forBinding(WidgetsBinding.instance);
    expect(clock.isRunning, isFalse);
    expect(clock.value, Duration.zero);

    clock.acquire();
    expect(clock.isRunning, isTrue);
    await Future<void>.delayed(LicoMotion.ambientFrame * 3);
    final first = clock.value;
    expect(first, greaterThan(Duration.zero));
    expect(first, lessThan(LicoMotion.ambientFrame * 8));

    clock.acquire();
    clock.release();
    await Future<void>.delayed(LicoMotion.ambientFrame * 2);
    // A second subscriber keeps the clock running.
    expect(clock.isRunning, isTrue);
    expect(clock.value, greaterThan(first));

    clock.release();
    expect(clock.isRunning, isFalse);
    final stoppedAt = clock.value;
    await Future<void>.delayed(LicoMotion.ambientFrame * 2);
    expect(clock.value, stoppedAt);
  });

  testWidgets('the clock pauses while hidden and resumes without a time jump', (
    tester,
  ) async {
    final clock = LicoAmbientClock.shared;
    clock.acquire();

    await tester.pump(LicoMotion.ambientFrame * 2);
    final beforeHidden = clock.value;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(clock.isRunning, isFalse);
    await tester.pump(LicoMotion.ambientFrame * 3);
    expect(clock.value, beforeHidden);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isTrue);
    await tester.pump(LicoMotion.ambientFrame * 2);
    expect(
      clock.value,
      beforeHidden + LicoMotion.ambientFrame * 2,
      reason: 'elapsed continues from the pause point — no time jump',
    );
    clock.release();
  });
}
