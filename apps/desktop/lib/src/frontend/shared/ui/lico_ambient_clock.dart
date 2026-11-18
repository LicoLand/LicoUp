import 'dart:async';

import 'package:flutter/widgets.dart';

import 'lico_motion.dart';

/// The one frame clock behind ambient motion.
///
/// A `ValueListenable<Duration>` of elapsed ambient time, driven by a single
/// `Timer.periodic` at [LicoMotion.ambientFrame] — ambient painters repaint at
/// the shared ambient cadence instead of each owning a vsync ticker that
/// schedules a frame every refresh. The clock runs only while at least one
/// subscriber holds it (acquire/release ref-count) and the app lifecycle is
/// `resumed` or `inactive`; on `hidden`/`paused`/`detached` it stops and on
/// return it resumes without a time jump — elapsed continues from where it
/// paused.
///
/// One app-wide instance: [LicoAmbientClock.shared].
final class LicoAmbientClock extends ValueNotifier<Duration> {
  LicoAmbientClock._(WidgetsBinding binding)
    : _binding = binding,
      super(Duration.zero) {
    _binding.addObserver(_lifecycleObserver);
  }

  /// The shared ambient clock.
  static final LicoAmbientClock shared = LicoAmbientClock._(
    WidgetsBinding.instance,
  );

  /// A clock bound to a specific binding — tests only.
  factory LicoAmbientClock.forBinding(WidgetsBinding binding) =>
      LicoAmbientClock._(binding);

  final WidgetsBinding _binding;
  late final WidgetsBindingObserver _lifecycleObserver =
      _AmbientClockLifecycleObserver(_onLifecycleState);
  int _subscribers = 0;
  Timer? _timer;
  bool _lifecycleActive = true;

  /// Registers an ambient-motion subscriber; the clock starts on the first.
  void acquire() {
    _subscribers += 1;
    _sync();
  }

  /// Unregisters a subscriber; the clock stops when the last one releases.
  void release() {
    if (_subscribers == 0) {
      return;
    }
    _subscribers -= 1;
    _sync();
  }

  /// Whether the periodic timer is armed — observable for tests.
  bool get isRunning => _timer != null;

  int get subscriberCount => _subscribers;

  void _onLifecycleState(AppLifecycleState state) {
    _lifecycleActive =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _sync();
  }

  void _sync() {
    final shouldRun = _subscribers > 0 && _lifecycleActive;
    if (shouldRun && _timer == null) {
      _timer = Timer.periodic(LicoMotion.ambientFrame, (_) {
        value += LicoMotion.ambientFrame;
      });
    } else if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

final class _AmbientClockLifecycleObserver extends WidgetsBindingObserver {
  _AmbientClockLifecycleObserver(this.onState);

  final void Function(AppLifecycleState state) onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onState(state);
  }
}
