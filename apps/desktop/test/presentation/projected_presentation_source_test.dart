import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';

void main() {
  group('one lifecycle for every resource type', () {
    test('opens by subscribing before reading the source', () async {
      final projection = _RecordedProjectionSource(const _Projection('body'));
      final source = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );
      addTearDown(source.dispose);

      final observation = await source.open();

      // A producer update published between the two would otherwise be lost.
      expect(projection.subscribedBeforeRead, isTrue);
      expect(observation.initial.value, 'body');
      expect(observation.initial.resource, _bodyResource);
      expect(observation.initial.version.value, 1);
    });

    test('publishes the mapped region value with monotonic versions', () async {
      final projection = _RecordedProjectionSource(const _Projection('one'));
      final source = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );
      addTearDown(source.dispose);

      final observation = await source.open();
      final changes = <SourceChange<String>>[];
      final subscription = observation.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      projection.publish(const _Projection('two'));
      projection.publish(const _Projection('two'));

      expect(changes, hasLength(1));
      expect(changes.single.snapshot.value, 'two');
      expect(changes.single.matchesBase(observation.initial), isTrue);
      expect(changes.single.hasValidGroup, isTrue);
      expect(changes.single.position.version.value, 2);
    });

    test('the last cancelled observation releases the producer', () async {
      final projection = _RecordedProjectionSource(const _Projection('one'));
      final source = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );
      addTearDown(source.dispose);

      final first = await source.open();
      final firstSubscription = first.changes.listen((_) {});
      expect(source.isObserved, isTrue);
      expect(projection.hasListener, isTrue);

      await firstSubscription.cancel();
      await pumpEventQueue();
      expect(source.isObserved, isFalse);
      expect(projection.hasListener, isFalse);

      // The source moves on unobserved; a reconnect reads it again and
      // continues the version sequence instead of restarting it.
      projection.publish(const _Projection('gap'));
      final second = await source.open();
      expect(second.initial.value, 'gap');
      expect(second.initial.epoch, first.initial.epoch);
      expect(second.initial.position.isAfter(first.initial.position), isTrue);
      await second.changes.listen((_) {}).cancel();
    });

    test('each incarnation is its own epoch', () {
      final projection = _RecordedProjectionSource(const _Projection('one'));
      final first = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );
      final second = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(first.epoch, isNot(second.epoch));
    });

    test('a disposed source refuses a new observation', () async {
      final projection = _RecordedProjectionSource(const _Projection('one'));
      final source = ProjectedPresentationSource<_Projection, String>(
        projection: projection,
        fieldGroup: _bodyFields,
        epochKey: 'document-body',
        read: (value) => value.body,
      );

      await source.dispose();

      await expectLater(source.open(), throwsStateError);
    });
  });
}

const _bodyResource = ResourceKey(
  scope: ResourceScope('document'),
  stableKey: 'body',
);

const _bodyFields = ResourceFieldGroup<String>(
  resource: _bodyResource,
  name: 'body',
);

final class _Projection {
  const _Projection(this.body);

  final String body;
}

final class _RecordedProjectionSource implements ProjectionSource<_Projection> {
  _RecordedProjectionSource(this._current);

  final StreamController<ProjectionUpdate<_Projection>> _controller =
      StreamController<ProjectionUpdate<_Projection>>.broadcast(sync: true);
  _Projection _current;
  bool _subscribed = false;
  bool subscribedBeforeRead = false;

  bool get hasListener => _controller.hasListener;

  @override
  _Projection get current {
    subscribedBeforeRead = _subscribed;
    return _current;
  }

  @override
  Stream<ProjectionUpdate<_Projection>> get changes {
    _subscribed = true;
    return _controller.stream;
  }

  void publish(_Projection value, {TraceContext? trace}) {
    _current = value;
    _controller.add(ProjectionUpdate<_Projection>(value, trace: trace));
  }
}
