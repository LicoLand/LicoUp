import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/skill_hub/skill_hub_inputs.dart';

/// Static feature providers for the skill hub presentation regions.
///
/// Source ports are composition inputs: the feature composition overrides each
/// source provider with the live application adapter. Views watch the typed
/// inputs providers only. Observation opens lazily while a region has a
/// listener and releases with the last one (autoDispose).
PresentationSource<T> _unavailableSource<T>(String region) {
  throw StateError('skill hub $region source is supplied by composition');
}

StreamProvider<ResourceSnapshot<T>> _snapshotProvider<T>(
  Provider<PresentationSource<T>> sourceProvider,
) {
  return StreamProvider.autoDispose<ResourceSnapshot<T>>((ref) {
    final runtime = ref.watch(presentationRuntimeProvider);
    final subscription = runtime.observe(ref.watch(sourceProvider));
    ref.onDispose(subscription.close);
    return subscription.stream;
  }, retry: (_, _) => null);
}

Provider<AsyncValue<T>> _inputsProvider<T>(
  StreamProvider<ResourceSnapshot<T>> snapshotProvider,
) {
  return Provider.autoDispose<AsyncValue<T>>(
    (ref) => ref.watch(snapshotProvider).whenData((snapshot) => snapshot.value),
  );
}

final skillHubCatalogSourceProvider =
    Provider<PresentationSource<SkillHubCatalogInputs>>(
      (_) => _unavailableSource('catalog'),
    );

final skillHubCatalogSnapshotProvider = _snapshotProvider(
  skillHubCatalogSourceProvider,
);

final skillHubCatalogInputsProvider = _inputsProvider(
  skillHubCatalogSnapshotProvider,
);
