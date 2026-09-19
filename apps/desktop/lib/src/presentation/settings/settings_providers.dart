import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

/// Static feature providers for the settings presentation regions.
///
/// Source ports are composition inputs: the feature composition overrides each
/// source provider with the live application adapter. Views watch the typed
/// inputs providers only. Observation opens lazily on the first watch and stays
/// open for the container's lifetime, so a section that scrolls out of the
/// lazy list and back in renders its installed value immediately instead of
/// collapsing to a zero-height loading gap mid-jump.
PresentationSource<T> _unavailableSource<T>(String region) {
  throw StateError('settings $region source is supplied by composition');
}

StreamProvider<ResourceSnapshot<T>> _snapshotProvider<T>(
  Provider<PresentationSource<T>> sourceProvider,
) {
  return StreamProvider<ResourceSnapshot<T>>((ref) {
    final runtime = ref.watch(presentationRuntimeProvider);
    final subscription = runtime.observe(ref.watch(sourceProvider));
    ref.onDispose(subscription.close);
    return subscription.stream;
  }, retry: (_, _) => null);
}

Provider<AsyncValue<T>> _inputsProvider<T>(
  StreamProvider<ResourceSnapshot<T>> snapshotProvider,
) {
  return Provider<AsyncValue<T>>(
    (ref) => ref.watch(snapshotProvider).whenData((snapshot) => snapshot.value),
  );
}

final settingsGeneralSourceProvider =
    Provider<PresentationSource<SettingsGeneralInputs>>(
      (_) => _unavailableSource('general'),
    );

final settingsGeneralSnapshotProvider = _snapshotProvider(
  settingsGeneralSourceProvider,
);

final settingsGeneralInputsProvider = _inputsProvider(
  settingsGeneralSnapshotProvider,
);

final settingsAppearanceSourceProvider =
    Provider<PresentationSource<SettingsAppearanceInputs>>(
      (_) => _unavailableSource('appearance'),
    );

final settingsAppearanceSnapshotProvider = _snapshotProvider(
  settingsAppearanceSourceProvider,
);

final settingsAppearanceInputsProvider = _inputsProvider(
  settingsAppearanceSnapshotProvider,
);

final settingsLayoutSourceProvider =
    Provider<PresentationSource<SettingsLayoutInputs>>(
      (_) => _unavailableSource('layout'),
    );

final settingsLayoutSnapshotProvider = _snapshotProvider(
  settingsLayoutSourceProvider,
);

final settingsLayoutInputsProvider = _inputsProvider(
  settingsLayoutSnapshotProvider,
);

final settingsStorageSourceProvider =
    Provider<PresentationSource<SettingsStorageInputs>>(
      (_) => _unavailableSource('storage'),
    );

final settingsStorageSnapshotProvider = _snapshotProvider(
  settingsStorageSourceProvider,
);

final settingsStorageInputsProvider = _inputsProvider(
  settingsStorageSnapshotProvider,
);

final settingsUpdateSourceProvider =
    Provider<PresentationSource<SettingsUpdateInputs>>(
      (_) => _unavailableSource('update'),
    );

final settingsUpdateSnapshotProvider = _snapshotProvider(
  settingsUpdateSourceProvider,
);

final settingsUpdateInputsProvider = _inputsProvider(
  settingsUpdateSnapshotProvider,
);

final settingsArchivedSourceProvider =
    Provider<PresentationSource<SettingsArchivedInputs>>(
      (_) => _unavailableSource('archived'),
    );

final settingsArchivedSnapshotProvider = _snapshotProvider(
  settingsArchivedSourceProvider,
);

final settingsArchivedInputsProvider = _inputsProvider(
  settingsArchivedSnapshotProvider,
);

final settingsLogExportSourceProvider =
    Provider<PresentationSource<SettingsLogExportInputs>>(
      (_) => _unavailableSource('log-export'),
    );

final settingsLogExportSnapshotProvider = _snapshotProvider(
  settingsLogExportSourceProvider,
);

final settingsLogExportInputsProvider = _inputsProvider(
  settingsLogExportSnapshotProvider,
);

final settingsAutostartSourceProvider =
    Provider<PresentationSource<SettingsAutostartProjection>>(
      (_) => _unavailableSource('autostart'),
    );

final settingsAutostartSnapshotProvider = _snapshotProvider(
  settingsAutostartSourceProvider,
);

final settingsAutostartInputsProvider = _inputsProvider(
  settingsAutostartSnapshotProvider,
);

final settingsResourceUsageSourceProvider =
    Provider<PresentationSource<SettingsResourceUsageProjection>>(
      (_) => _unavailableSource('resource-usage'),
    );

final settingsResourceUsageSnapshotProvider = _snapshotProvider(
  settingsResourceUsageSourceProvider,
);

final settingsResourceUsageInputsProvider = _inputsProvider(
  settingsResourceUsageSnapshotProvider,
);
