import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_resources.dart';

/// Static feature providers for the agents catalog region.
///
/// The source port is a composition input: the feature composition installs
/// the live application adapter through [agentsCatalogSourceProvider]. This layer
/// owns no source lifecycle - the default port reports a configuration error
/// instead of building a shadow source.
///
/// Views watch [agentsCatalogProjectionProvider]: Loading until the runtime
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

final agentsCatalogSourceProvider =
    Provider<PresentationSource<AgentsProjection>>(
      (_) => _NotConfiguredSource<AgentsProjection>(
        agentsCatalogFields,
        'agents catalog',
      ),
    );

final _agentsCatalogSnapshotProvider =
    StreamProvider<ResourceSnapshot<AgentsProjection>>(
      (ref) {
        final runtime = ref.watch(presentationRuntimeProvider);
        final subscription = runtime.observe(
          ref.watch(agentsCatalogSourceProvider),
        );
        ref.onDispose(subscription.close);
        return subscription.stream;
      },
      retry: (_, _) => null,
      dependencies: [presentationRuntimeProvider, agentsCatalogSourceProvider],
    );

/// The region value installed by the runtime.
final agentsCatalogProjectionProvider = Provider<AsyncValue<AgentsProjection>>(
  (ref) => ref
      .watch(_agentsCatalogSnapshotProvider)
      .whenData((snapshot) => snapshot.value),
  dependencies: [_agentsCatalogSnapshotProvider],
);
