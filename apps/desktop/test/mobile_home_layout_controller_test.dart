import 'dart:async';

import 'package:flutter_client/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads layout through its narrow repository', () async {
    final repository = _MemoryLayoutRepository(
      const MobileHomeLayout(
        order: ['target:a', 'device:b', 'account:retired'],
        pinnedEntryIds: {'target:a', 'account:retired'},
      ),
    );
    final controller = MobileHomeLayoutController(repository: repository);

    await controller.load();

    expect(controller.layout.order, ['target:a', 'device:b']);
    expect(controller.layout.pinnedEntryIds, {'target:a'});
  });

  test('reorders unique pinned entries and preserves unpinned order', () async {
    final repository = _MemoryLayoutRepository(MobileHomeLayout.defaults());
    final controller = MobileHomeLayoutController(repository: repository)
      ..replaceLayout(
        const MobileHomeLayout(
          order: ['target:a', 'device:b', 'action:retired'],
          pinnedEntryIds: {'target:a', 'device:b'},
        ),
      );

    await controller.reorderPinnedEntries(
      ['target:a', 'target:a', 'device:b'],
      0,
      2,
    );

    expect(controller.layout.order, ['device:b', 'target:a']);
    expect(repository.saved.single.order, controller.layout.order);
  });

  test('toggle and removal update both projections', () async {
    final repository = _MemoryLayoutRepository(MobileHomeLayout.defaults());
    final controller = MobileHomeLayoutController(repository: repository)
      ..replaceLayout(
        const MobileHomeLayout(
          order: ['target:a', 'device:b'],
          pinnedEntryIds: {'target:a'},
        ),
      );

    await controller.togglePinned('device:b');
    await controller.removeEntries({'target:a'});

    expect(controller.layout.order, ['device:b']);
    expect(controller.layout.pinnedEntryIds, {'device:b'});
    expect(repository.saved, hasLength(2));
  });

  test('serializes overlapping persistence writes', () async {
    final repository = _MemoryLayoutRepository(MobileHomeLayout.defaults())
      ..pauseWrites = true;
    final controller = MobileHomeLayoutController(repository: repository);

    final first = controller.togglePinned('target:a');
    final second = controller.togglePinned('device:b');
    await Future<void>.delayed(Duration.zero);

    expect(repository.pendingWrites, 1);
    repository.releaseNext();
    await Future<void>.delayed(Duration.zero);
    expect(repository.pendingWrites, 1);
    repository.releaseNext();
    await Future.wait([first, second]);
    expect(repository.saved.last.pinnedEntryIds, {'target:a', 'device:b'});
  });
}

final class _MemoryLayoutRepository implements MobileHomeLayoutRepository {
  _MemoryLayoutRepository(this.value);

  MobileHomeLayout value;
  final List<MobileHomeLayout> saved = [];
  final List<Completer<void>> _pending = [];
  bool pauseWrites = false;

  int get pendingWrites => _pending.length;

  @override
  Future<MobileHomeLayout> load() async => value;

  @override
  Future<void> save(MobileHomeLayout layout) async {
    if (pauseWrites) {
      final completer = Completer<void>();
      _pending.add(completer);
      await completer.future;
    }
    value = layout;
    saved.add(layout);
  }

  void releaseNext() {
    _pending.removeAt(0).complete();
  }
}
