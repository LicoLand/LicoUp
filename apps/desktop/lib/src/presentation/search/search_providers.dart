import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/search/search_projection.dart';

/// Stable resource identity for the search region.
final searchPresentationFieldGroup = ResourceFieldGroup<SearchProjection>(
  resource: const ResourceKey(
    scope: ResourceScope('search'),
    stableKey: 'catalog',
  ),
  name: 'projection',
);

/// Static feature providers for the search region.
///
/// The source port is a composition input: the feature composition installs
/// the live application adapter through [searchSourceProvider]. This layer
/// owns no source lifecycle - the default port reports a configuration error
/// instead of building a shadow source.
///
/// Views watch [searchProjectionProvider]: Loading until the runtime installs
/// the first snapshot, an error after revocation or a source failure, and
/// never the legacy owner value.
final class _NotConfiguredSource<T> implements PresentationSource<T> {
  const _NotConfiguredSource(this.fieldGroup, this.label);

  @override
  final ResourceFieldGroup<T> fieldGroup;
  final String label;

  @override
  Future<SourceObservation<T>> open() => Future<SourceObservation<T>>.error(
    StateError('$label source is not configured; composition must install it'),
  );
}

final searchSourceProvider = Provider<PresentationSource<SearchProjection>>(
  (_) => _NotConfiguredSource<SearchProjection>(
    searchPresentationFieldGroup,
    'search',
  ),
);

final _searchSnapshotProvider =
    StreamProvider<ResourceSnapshot<SearchProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(ref.watch(searchSourceProvider));
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The region value installed by the runtime.
final searchProjectionProvider = Provider<AsyncValue<SearchProjection>>(
  (ref) =>
      ref.watch(_searchSnapshotProvider).whenData((snapshot) => snapshot.value),
);
