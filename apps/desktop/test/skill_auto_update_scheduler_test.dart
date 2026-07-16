import 'dart:async';

import 'package:flutter_client/src/application/features/skill_hub/services/skill_auto_update_scheduler.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'lifecycle start wakes immediately and schedules periodic due checks',
    () async {
      final gateway = _Gateway();
      late void Function() wakeup;
      var cancelled = false;
      final scheduler = SkillAutoUpdateScheduler(
        gateway: gateway,
        schedulePeriodic: (interval, run) {
          expect(interval, const Duration(minutes: 15));
          wakeup = run;
          return () => cancelled = true;
        },
      );

      scheduler.start();
      scheduler.start();
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.running, isTrue);
      expect(gateway.dueCalls, 1);

      wakeup();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.dueCalls, 2);

      scheduler.dispose();
      expect(cancelled, isTrue);
      expect(scheduler.running, isFalse);
    },
  );

  test('overlap and failure are contained before the next wakeup', () async {
    final gateway = _Gateway();
    final scheduler = SkillAutoUpdateScheduler(
      gateway: gateway,
      schedulePeriodic: (_, _) => () {},
    );
    addTearDown(scheduler.dispose);
    final blocked = Completer<Map<String, dynamic>>();
    gateway.next = blocked.future;

    final first = scheduler.tickNow();
    final overlapping = scheduler.tickNow();
    expect(identical(first, overlapping), isTrue);
    expect(gateway.dueCalls, 1);
    blocked.complete({'ok': true});
    await first;

    gateway.failNext = true;
    await scheduler.tickNow();
    await scheduler.tickNow();
    expect(gateway.dueCalls, 3);
  });
}

final class _Gateway implements SkillUpdateGateway {
  int dueCalls = 0;
  bool failNext = false;
  Future<Map<String, dynamic>>? next;

  @override
  Future<Map<String, dynamic>> runDueSkillUpdates() {
    dueCalls += 1;
    if (failNext) {
      failNext = false;
      throw StateError('synthetic scheduler transport failure');
    }
    final result = next;
    next = null;
    return result ?? Future.value({'ok': true});
  }

  @override
  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) async => {'ok': true};
}
