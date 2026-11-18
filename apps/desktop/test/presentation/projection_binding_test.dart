import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_binding.dart';

void main() {
  group('region generations', () {
    test('a delivery racing a rebind is dropped, not mixed', () {
      final first = _ManualSource(1);
      final second = _ManualSource(2);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: first,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();
      expect(binding.value, 1);
      final staleFirst = first.listeners.single;

      binding.rebind(source: second);

      expect(binding.value, 2);
      expect(committed, <int>[2]);
      // The replaced source's subscription was already cancelled when this
      // delivery was in flight; it must not overwrite the new generation.
      staleFirst(ProjectionUpdate<int>(99));
      expect(binding.value, 2);
      expect(committed, <int>[2]);
    });

    test('A to B to A returns to the current facts of A', () {
      final first = _ManualSource(1);
      final second = _ManualSource(2);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: first,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();

      binding.rebind(source: second);
      // A moves on while it is not observed; returning to A must read A's
      // current value rather than the value A had when it was left.
      first.value = 7;
      binding.rebind(source: first);

      expect(binding.value, 7);
      expect(committed, <int>[2, 7]);
    });

    test('duplicate deliveries do not rebuild the region', () {
      final source = _ManualSource(1);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: source,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();
      final listener = source.listeners.single;

      listener(ProjectionUpdate<int>(2));
      listener(ProjectionUpdate<int>(2));

      expect(binding.value, 2);
      expect(committed, <int>[2]);
    });

    test('a revoked source is not echoed back', () {
      final source = _ManualSource(1);
      var revoked = 0;
      final binding = ProjectionBinding<int, int>(
        source: source,
        select: (value) => value,
        onValue: (_, _) {},
        onRevoked: () => revoked += 1,
      );
      addTearDown(binding.dispose);
      binding.activate();
      final stale = source.listeners.single;

      binding.revoke();

      expect(binding.isRevoked, isTrue);
      expect(revoked, 1);
      // The revoked owner deleted this content; a delivery still in flight
      // must not resurrect it.
      stale(ProjectionUpdate<int>(5));
      expect(binding.value, 1);
      expect(binding.isAttached, isFalse);
    });

    test('a reinstall after revoke observes the new source only', () {
      final revokedSource = _ManualSource(1);
      final replacement = _ManualSource(4);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: revokedSource,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();
      final stale = revokedSource.listeners.single;
      binding.revoke();

      binding.rebind(source: replacement);
      binding.activate();

      expect(binding.isRevoked, isFalse);
      expect(binding.value, 4);
      stale(ProjectionUpdate<int>(1));
      expect(binding.value, 4);
      expect(committed, <int>[4]);
    });
  });

  group('region attach and detach', () {
    test('a detached background tab closes its gap on reattach', () {
      final source = _ManualSource(1);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: source,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();
      final stale = source.listeners.single;

      binding.deactivate();
      source.value = 5;
      stale(ProjectionUpdate<int>(5));
      // A detached region keeps rendering its last committed value and does
      // not rebuild for a source it no longer observes.
      expect(binding.value, 1);
      expect(binding.isAttached, isFalse);
      expect(committed, isEmpty);

      binding.activate();

      expect(binding.value, 5);
      expect(binding.isAttached, isTrue);
      expect(committed, <int>[5]);
    });

    test('reattaching an unchanged source does not rebuild the region', () {
      final source = _ManualSource(1);
      final committed = <int>[];
      final binding = ProjectionBinding<int, int>(
        source: source,
        select: (value) => value,
        onValue: (value, _) => committed.add(value),
      );
      addTearDown(binding.dispose);
      binding.activate();

      binding.deactivate();
      binding.activate();

      expect(binding.value, 1);
      expect(committed, isEmpty);
    });

    test('a changed selector re-reads the region slice', () {
      final source = _ManualSource<_Pair>(const _Pair(3, 30));
      final binding = ProjectionBinding<_Pair, int>(
        source: source,
        select: (pair) => pair.left,
        onValue: (_, _) {},
      );
      addTearDown(binding.dispose);
      binding.activate();

      binding.rebind(select: (pair) => pair.right);

      expect(binding.value, 30);
    });
  });

  group('region classification', () {
    test('an appearance region keeps its value when a source is revoked', () {
      final source = _ManualSource(1);
      var revoked = 0;
      final binding = ProjectionBinding<int, int>(
        source: source,
        select: (value) => value,
        onValue: (_, _) {},
        onRevoked: () => revoked += 1,
        region: ShellRegionClass.appearance,
      );
      addTearDown(binding.dispose);
      binding.activate();

      binding.revoke();

      // An uninstalled appearance package resolves to a platform fallback; the
      // window is never blanked and no business absence is rendered.
      expect(binding.isRevoked, isTrue);
      expect(binding.value, 1);
      expect(revoked, 0);
    });

    test('a rendering extension declares no resource binding', () {
      final source = _ManualSource(1);
      expect(
        () => ProjectionBinding<int, int>(
          source: source,
          select: (value) => value,
          onValue: (_, _) {},
          region: ShellRegionClass.renderingExtension,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

final class _Pair {
  const _Pair(this.left, this.right);

  final int left;
  final int right;
}

/// A projection source whose deliveries the test hands to a captured listener.
///
/// A delivery can therefore be replayed after the binding replaced or revoked
/// the source, which is exactly the race a region generation fence must
/// survive.
final class _ManualSource<T> implements ProjectionSource<T> {
  _ManualSource(this.value);

  T value;
  final List<void Function(ProjectionUpdate<T>)> listeners =
      <void Function(ProjectionUpdate<T>)>[];

  @override
  T get current => value;

  @override
  Stream<ProjectionUpdate<T>> get changes =>
      _ListenerCaptureStream<T>((listener) => listeners.add(listener));
}

final class _ListenerCaptureStream<T> extends Stream<ProjectionUpdate<T>> {
  _ListenerCaptureStream(this._onListen);

  final void Function(void Function(ProjectionUpdate<T>) listener) _onListen;

  @override
  StreamSubscription<ProjectionUpdate<T>> listen(
    void Function(ProjectionUpdate<T> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onListen(onData!);
    return _DetachedSubscription<ProjectionUpdate<T>>();
  }
}

final class _DetachedSubscription<T> implements StreamSubscription<T> {
  @override
  Future<void> cancel() async {}

  @override
  void onData(void Function(T data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) async => futureValue as E;
}
