import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';

/// Static feature providers for the target catalog region.
///
/// The source port is a composition input: the feature composition installs
/// the live application adapter through [targetsCatalogSourceProvider]. This layer
/// owns no source lifecycle - the default port reports a configuration error
/// instead of building a shadow source.
///
/// Views watch [targetsCatalogProjectionProvider]: Loading until the runtime
/// installs the first snapshot, an error after revocation or a source failure,
/// and never the legacy owner value.
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

final targetsCatalogSourceProvider =
    Provider<PresentationSource<TargetsProjection>>(
      (_) => _NotConfiguredSource<TargetsProjection>(
        targetsCatalogFields,
        'target catalog',
      ),
    );

final _targetsCatalogSnapshotProvider =
    StreamProvider<ResourceSnapshot<TargetsProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(targetsCatalogSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The region value installed by the runtime.
final targetsCatalogProjectionProvider =
    Provider<AsyncValue<TargetsProjection>>(
      (ref) => ref
          .watch(_targetsCatalogSnapshotProvider)
          .whenData((snapshot) => snapshot.value),
    );
