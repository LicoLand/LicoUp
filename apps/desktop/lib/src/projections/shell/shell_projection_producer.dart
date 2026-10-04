import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/controller/locale_resource_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/mounted_destination_set.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/projections/application_projection_source.dart';

/// Six independent shell state planes. Composition exclusively owns their
/// shared lifetime, while renderers subscribe only to the plane they consume.
final class ShellProjectionProducer {
  ShellProjectionProducer({
    required AppearancePreferenceOwner appearance,
    required LocalePreferenceOwner locale,
    required LocaleResourceOwner localeResources,
    required FunctionalStatusRuntime status,
    required ClientNavigationController navigation,
    required LayoutManager layoutManager,
    required ProjectionSource<EnvironmentProjection> environment,
    MountedDestinationSet? mountedDestinations,
    AppearanceProjection Function(AppearancePreferenceOwner owner)?
    appearanceResolver,
    LocaleProjection Function(
      LocalePreferenceOwner owner,
      LocaleResourceOwner resources,
    )?
    localeResolver,
    LayoutProjection Function(
      LayoutManager manager,
      EnvironmentProjection environment,
    )?
    layoutResolver,
    StatusProjection Function(FunctionalStatusRuntime runtime)? statusResolver,
  }) {
    final mounts =
        mountedDestinations ?? MountedDestinationSet(ClientSection.values);
    this.mounts = mounts;
    final resolveAppearance = appearanceResolver ?? resolveAppearanceProjection;
    final resolveLocale = localeResolver ?? resolveLocaleProjection;
    final resolveLayout = layoutResolver ?? resolveLayoutProjection;
    final resolveStatus = statusResolver ?? resolveStatusProjection;
    this.appearance = ApplicationProjectionSource<AppearanceProjection>(
      changes: appearance.changes,
      read: () => resolveAppearance(appearance),
    );
    _locale = _MergedProjectionSource<LocaleProjection>(
      changes: [locale.changes, localeResources.changes],
      read: () => resolveLocale(locale, localeResources),
    );
    _layout = _MergedProjectionSource<LayoutProjection>(
      changes: [layoutManager.selectionChanges, environment.changes],
      read: () => resolveLayout(layoutManager, environment.current),
    );
    this.environment = environment;
    this.navigation = ApplicationProjectionSource<NavigationProjection>(
      changes: navigation.changes,
      read: () => _readNavigation(navigation),
    );
    this.status = ApplicationProjectionSource<StatusProjection>(
      changes: status.changes,
      read: () => resolveStatus(status),
    );
  }

  late final ApplicationProjectionSource<AppearanceProjection> appearance;
  late final _MergedProjectionSource<LocaleProjection> _locale;
  late final _MergedProjectionSource<LayoutProjection> _layout;
  late final ProjectionSource<EnvironmentProjection> environment;
  late final ApplicationProjectionSource<NavigationProjection> navigation;
  late final ApplicationProjectionSource<StatusProjection> status;

  /// The catalogue projection of which destinations this client mounts.
  late final MountedDestinationSet mounts;
  bool _disposed = false;

  ProjectionSource<LocaleProjection> get locale => _locale;

  ProjectionSource<LayoutProjection> get layout => _layout;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      appearance.dispose(),
      _locale.dispose(),
      _layout.dispose(),
      navigation.dispose(),
      status.dispose(),
    ]);
  }

  static AppearancePresetProjection _projectAppearancePreset(
    AppearancePresetConfig config,
  ) {
    final tokens = [
      for (final entry in config.tokens.entries)
        AppearanceTokenProjection(name: entry.key, value: entry.value),
    ]..sort((left, right) => left.name.compareTo(right.name));
    return AppearancePresetProjection(
      id: config.id,
      label: config.labelFor(),
      modeId: config.mode.id,
      tokens: tokens,
    );
  }

  /// Projects the mounted destinations the composition declared.
  ///
  /// Only mounted destinations are offered, because an uninstalled feature has
  /// no surface and no owner to reach. Unmounted ones are reported in
  /// [NavigationProjection.unavailable] rather than dropped, so the absence is
  /// visible, and a selection that is not mounted — a restored view naming a
  /// capability this client does not have — is recovered to a mounted
  /// destination before the shell renders it.
  NavigationProjection _readNavigation(ClientNavigationController navigation) {
    final available = mounts.destinations
        .where((destination) => navigation.resolve(destination) == destination)
        .toList(growable: false);
    final requested = navigation.currentSection;
    final unavailable = [
      for (final destination in ClientSection.values)
        if (!mounts.isMounted(destination)) destination,
    ];
    if (available.isEmpty) {
      return NavigationProjection(
        destination: requested,
        destinations: const <ClientSection>[],
        unavailable: unavailable,
      );
    }
    final destination = available.contains(requested)
        ? requested
        : mounts.recoveryFor(requested) ?? available.first;
    return NavigationProjection(
      destination: destination,
      destinations: available,
      unavailable: unavailable,
      recoveryDestination: destination == requested ? null : destination,
    );
  }
}

AppearanceProjection resolveAppearanceProjection(
  AppearancePreferenceOwner appearance,
) => AppearanceProjection(
  presetId: appearance.presetId,
  fontPreference: appearance.fontPreference,
  reduceMotion: appearance.reduceMotion,
  loadingEffectId: appearance.loadingEffectId,
  presets: appearance.presets.map(
    ShellProjectionProducer._projectAppearancePreset,
  ),
);

/// Projects the locale plane: the preference plus the language resources
/// installed on this client, which are what the rendered strings resolve from.
LocaleProjection resolveLocaleProjection(
  LocalePreferenceOwner locale,
  LocaleResourceOwner resources,
) => LocaleProjection(
  locale.preference,
  resources: [
    for (final pack in resources.packs)
      LocaleResourceProjection(
        id: pack.id,
        locale: pack.locale,
        strings: pack.strings,
      ),
  ],
);

StatusProjection resolveStatusProjection(FunctionalStatusRuntime status) =>
    StatusProjection(
      messageChinese: status.messageChinese,
      messageEnglish: status.messageEnglish,
      caption: status.caption,
      errorCode: status.lastErrorCode,
    );

LayoutProjection resolveLayoutProjection(
  LayoutManager manager,
  EnvironmentProjection environment,
) {
  final state = manager.state;
  final measured = environment.environment;
  final loading = state.status == LayoutSelectionStatus.loading;
  return LayoutProjection(
    LayoutSelectionState(
      committedId: loading ? state.committedId : state.effectiveId,
      effectiveId: state.effectiveId,
      status: loading
          ? LayoutSelectionStatus.loading
          : LayoutSelectionStatus.stable,
      surface: measured.surface,
      viewport: measured.viewport,
      operationEpoch: 0,
    ),
  );
}

typedef _LayoutProjectionReader<T> = T Function();

/// Equality-suppressing projection over the framework-independent layout
/// change stream.
/// Merges the owner signals one plane depends on into one projected value.
///
/// The layout plane follows two owners (the manager's selection and the
/// measured environment), and the locale plane follows two as well (the
/// preference and the language resources installed on this client).
final class _MergedProjectionSource<T> implements ProjectionSource<T> {
  _MergedProjectionSource({
    required Iterable<Stream<Object?>> changes,
    required _LayoutProjectionReader<T> read,
  }) : _read = read,
       _current = read() {
    _subscriptions = [
      for (final changesForOwner in changes)
        changesForOwner.listen(_handleChange),
    ];
  }

  final _LayoutProjectionReader<T> _read;
  final StreamController<ProjectionUpdate<T>> _updates =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  late final List<StreamSubscription<Object?>> _subscriptions;
  T _current;
  bool _disposed = false;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _updates.stream;

  void _handleChange(Object? change) {
    if (_disposed) return;
    final next = _read();
    if (next == _current) return;
    _current = next;
    _updates.add(
      ProjectionUpdate(
        next,
        trace: change is! ApplicationChange || change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_updates);
  }
}
