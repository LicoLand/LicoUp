import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

const _shellScope = ResourceScope('shell');

/// Stable resource identity for the shell appearance region.
final shellAppearancePresentationFields =
    ResourceFieldGroup<AppearanceProjection>(
      resource: const ResourceKey(scope: _shellScope, stableKey: 'appearance'),
      name: 'projection',
    );

/// Stable resource identity for the shell locale region.
final shellLocalePresentationFields = ResourceFieldGroup<LocaleProjection>(
  resource: const ResourceKey(scope: _shellScope, stableKey: 'locale'),
  name: 'projection',
);

/// Stable resource identity for the shell layout region.
final shellLayoutPresentationFields = ResourceFieldGroup<LayoutProjection>(
  resource: const ResourceKey(scope: _shellScope, stableKey: 'layout'),
  name: 'projection',
);

/// Stable resource identity for the shell environment region.
final shellEnvironmentPresentationFields =
    ResourceFieldGroup<EnvironmentProjection>(
      resource: const ResourceKey(scope: _shellScope, stableKey: 'environment'),
      name: 'projection',
    );

/// Stable resource identity for the shell navigation region.
final shellNavigationPresentationFields =
    ResourceFieldGroup<NavigationProjection>(
      resource: const ResourceKey(scope: _shellScope, stableKey: 'navigation'),
      name: 'projection',
    );

/// Stable resource identity for the shell status region.
final shellStatusPresentationFields = ResourceFieldGroup<StatusProjection>(
  resource: const ResourceKey(scope: _shellScope, stableKey: 'status'),
  name: 'projection',
);

/// Static feature providers for the six shell regions.
///
/// The source ports are composition inputs: the feature composition installs
/// the live application adapters through the `shell*SourceProvider` ports.
/// This layer owns no source lifecycle - the default ports report a
/// configuration error instead of building shadow sources.
///
/// The shell host watches the `shell*ProjectionProvider` values: Loading until
/// the runtime installs the first snapshot per region, an error after
/// revocation or a source failure, and never the legacy owner value.
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

final shellAppearanceSourceProvider =
    Provider<PresentationSource<AppearanceProjection>>(
      (_) => _NotConfiguredSource<AppearanceProjection>(
        shellAppearancePresentationFields,
        'shell appearance',
      ),
    );

final _shellAppearanceSnapshotProvider =
    StreamProvider<ResourceSnapshot<AppearanceProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellAppearanceSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The appearance region value installed by the runtime.
final shellAppearanceProjectionProvider =
    Provider<AsyncValue<AppearanceProjection>>(
      (ref) => ref
          .watch(_shellAppearanceSnapshotProvider)
          .whenData((snapshot) => snapshot.value),
    );

final shellLocaleSourceProvider =
    Provider<PresentationSource<LocaleProjection>>(
      (_) => _NotConfiguredSource<LocaleProjection>(
        shellLocalePresentationFields,
        'shell locale',
      ),
    );

final _shellLocaleSnapshotProvider =
    StreamProvider<ResourceSnapshot<LocaleProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellLocaleSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The locale region value installed by the runtime.
final shellLocaleProjectionProvider = Provider<AsyncValue<LocaleProjection>>(
  (ref) => ref
      .watch(_shellLocaleSnapshotProvider)
      .whenData((snapshot) => snapshot.value),
);

final shellLayoutSourceProvider =
    Provider<PresentationSource<LayoutProjection>>(
      (_) => _NotConfiguredSource<LayoutProjection>(
        shellLayoutPresentationFields,
        'shell layout',
      ),
    );

final _shellLayoutSnapshotProvider =
    StreamProvider<ResourceSnapshot<LayoutProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellLayoutSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The layout region value installed by the runtime.
final shellLayoutProjectionProvider = Provider<AsyncValue<LayoutProjection>>(
  (ref) => ref
      .watch(_shellLayoutSnapshotProvider)
      .whenData((snapshot) => snapshot.value),
);

final shellEnvironmentSourceProvider =
    Provider<PresentationSource<EnvironmentProjection>>(
      (_) => _NotConfiguredSource<EnvironmentProjection>(
        shellEnvironmentPresentationFields,
        'shell environment',
      ),
    );

final _shellEnvironmentSnapshotProvider =
    StreamProvider<ResourceSnapshot<EnvironmentProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellEnvironmentSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The environment region value installed by the runtime.
final shellEnvironmentProjectionProvider =
    Provider<AsyncValue<EnvironmentProjection>>(
      (ref) => ref
          .watch(_shellEnvironmentSnapshotProvider)
          .whenData((snapshot) => snapshot.value),
    );

final shellNavigationSourceProvider =
    Provider<PresentationSource<NavigationProjection>>(
      (_) => _NotConfiguredSource<NavigationProjection>(
        shellNavigationPresentationFields,
        'shell navigation',
      ),
    );

final _shellNavigationSnapshotProvider =
    StreamProvider<ResourceSnapshot<NavigationProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellNavigationSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The navigation region value installed by the runtime.
final shellNavigationProjectionProvider =
    Provider<AsyncValue<NavigationProjection>>(
      (ref) => ref
          .watch(_shellNavigationSnapshotProvider)
          .whenData((snapshot) => snapshot.value),
    );

final shellStatusSourceProvider =
    Provider<PresentationSource<StatusProjection>>(
      (_) => _NotConfiguredSource<StatusProjection>(
        shellStatusPresentationFields,
        'shell status',
      ),
    );

final _shellStatusSnapshotProvider =
    StreamProvider<ResourceSnapshot<StatusProjection>>((ref) {
      final runtime = ref.watch(presentationRuntimeProvider);
      final subscription = runtime.observe(
        ref.watch(shellStatusSourceProvider),
      );
      ref.onDispose(subscription.close);
      return subscription.stream;
    }, retry: (_, _) => null);

/// The status region value installed by the runtime.
final shellStatusProjectionProvider = Provider<AsyncValue<StatusProjection>>(
  (ref) => ref
      .watch(_shellStatusSnapshotProvider)
      .whenData((snapshot) => snapshot.value),
);
