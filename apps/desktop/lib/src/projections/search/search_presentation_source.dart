import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/search/search_projection.dart';
import 'package:licoup/src/presentation/search/search_providers.dart'
    show searchPresentationFieldGroup;

int _searchSourceIncarnations = 0;

/// Runtime source over the existing search projection producer.
///
/// The producer stays the application-facing owner; this adapter adds source
/// identity for the prepared runtime: one epoch per adapter incarnation,
/// monotonic versions, and a single-member consistency group per accepted
/// change. The observation subscribes before reading the current value, so no
/// producer update is lost between the initial read and the change stream.
final class SearchPresentationSource
    implements PresentationSource<SearchProjection> {
  SearchPresentationSource({
    required ProjectionSource<SearchProjection> projection,
  }) : _projection = projection,
       _epoch = SourceEpoch('search-${++_searchSourceIncarnations}');

  final ProjectionSource<SearchProjection> _projection;
  final SourceEpoch _epoch;
  int _version = 0;

  @override
  ResourceFieldGroup<SearchProjection> get fieldGroup =>
      searchPresentationFieldGroup;

  @override
  Future<SourceObservation<SearchProjection>> open() async {
    _version += 1;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    var installed = position;
    final changes = StreamController<SourceChange<SearchProjection>>(
      sync: true,
    );
    final subscription = _projection.changes.listen(
      (update) {
        if (changes.isClosed) return;
        _version += 1;
        final nextPosition = SourcePosition(
          epoch: _epoch,
          version: SourceVersion(_version),
        );
        final group = ConsistencyGroup(
          id: ConsistencyGroupId(
            'search-catalog-${nextPosition.version.value}',
            source: SourceIdentity(
              scope: fieldGroup.resource.scope,
              stableKey: fieldGroup.resource.stableKey,
            ),
          ),
          position: nextPosition,
          changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
        );
        changes.add(
          SourceChange<SearchProjection>(
            snapshot: ResourceSnapshot<SearchProjection>(
              fieldGroup: fieldGroup,
              epoch: nextPosition.epoch,
              version: nextPosition.version,
              value: update.value,
              consistencyGroup: group,
            ),
            base: installed,
            group: group,
            trace: update.trace,
          ),
        );
        installed = nextPosition;
      },
      onDone: () {
        if (!changes.isClosed) unawaited(changes.close());
      },
    );
    changes.onCancel = () async {
      await subscription.cancel();
    };
    return SourceObservation<SearchProjection>(
      initial: ResourceSnapshot<SearchProjection>(
        fieldGroup: fieldGroup,
        epoch: position.epoch,
        version: position.version,
        value: _projection.current,
      ),
      changes: changes.stream,
    );
  }
}
