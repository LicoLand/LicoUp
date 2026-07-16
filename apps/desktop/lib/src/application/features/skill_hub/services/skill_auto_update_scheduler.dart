import 'dart:async';

import 'package:flutter_client/src/contracts/skill_update.dart';

typedef SkillAutoUpdateTimerCancel = void Function();
typedef SkillAutoUpdateTimerScheduler =
    SkillAutoUpdateTimerCancel Function(Duration interval, void Function() run);

SkillAutoUpdateTimerCancel _schedulePeriodicTimer(
  Duration interval,
  void Function() run,
) {
  final timer = Timer.periodic(interval, (_) => run());
  return timer.cancel;
}

/// Owns the desktop-lifecycle timer for previously user-enabled skill updates.
///
/// The native policy store remains authoritative for source, enabled state,
/// due time, bounded retries, and the cross-process execution lock. This
/// service only supplies periodic wakeups and never discovers a source.
final class SkillAutoUpdateScheduler {
  SkillAutoUpdateScheduler({
    required SkillUpdateGateway gateway,
    this.wakeupInterval = const Duration(minutes: 15),
    SkillAutoUpdateTimerScheduler? schedulePeriodic,
  }) : _gateway = gateway,
       _schedulePeriodic = schedulePeriodic ?? _schedulePeriodicTimer;

  final SkillUpdateGateway _gateway;
  final Duration wakeupInterval;
  final SkillAutoUpdateTimerScheduler _schedulePeriodic;

  SkillAutoUpdateTimerCancel? _cancelTimer;
  Future<void>? _activeTick;
  bool _disposed = false;

  bool get running => _cancelTimer != null && !_disposed;

  void start() {
    if (_disposed || _cancelTimer != null) return;
    _cancelTimer = _schedulePeriodic(wakeupInterval, () {
      unawaited(tickNow());
    });
    unawaited(tickNow());
  }

  Future<void> tickNow() {
    if (_disposed) return Future<void>.value();
    final active = _activeTick;
    if (active != null) return active;
    late final Future<void> tick;
    tick = _runTick().whenComplete(() {
      if (identical(_activeTick, tick)) _activeTick = null;
    });
    _activeTick = tick;
    return tick;
  }

  Future<void> _runTick() async {
    try {
      await _gateway.runDueSkillUpdates();
    } on Object {
      // A failed source is persisted as a bounded native backoff. Transport
      // failures are retried by the next wakeup without surfacing raw details.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimer?.call();
    _cancelTimer = null;
  }
}
