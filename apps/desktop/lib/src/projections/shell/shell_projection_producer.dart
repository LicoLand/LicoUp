import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
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
    required FunctionalStatusRuntime status,
    required ClientNavigationController navigation,
    required LayoutManager layoutManager,
    required ProjectionSource<EnvironmentProjection> environment,
    AppearanceProjection Function(AppearancePreferenceOwner owner)?
    appearanceResolver,
    LocaleProjection Function(LocalePreferenceOwner owner)? localeResolver,
    LayoutProjection Function(
      LayoutManager manager,
      EnvironmentProjection environment,
    )?
    layoutResolver,
    StatusProjection Function(FunctionalStatusRuntime runtime)? statusResolver,
  }) {
    final resolveAppearance = appearanceResolver ?? resolveAppearanceProjection;
    final resolveLocale = localeResolver ?? resolveLocaleProjection;
    final resolveLayout = layoutResolver ?? resolveLayoutProjection;
    final resolveStatus = statusResolver ?? resolveStatusProjection;
    this.appearance = ApplicationProjectionSource<AppearanceProjection>(
      changes: appearance.changes,
      read: () => resolveAppearance(appearance),
    );
    this.locale = ApplicationProjectionSource<LocaleProjection>(
      changes: locale.changes,
      read: () => resolveLocale(locale),
    );
    _layout = _LayoutProjectionSource<LayoutProjection>(
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
  late final ApplicationProjectionSource<LocaleProjection> locale;
  late final _LayoutProjectionSource<LayoutProjection> _layout;
  late final ProjectionSource<EnvironmentProjection> environment;
  late final ApplicationProjectionSource<NavigationProjection> navigation;
  late final ApplicationProjectionSource<StatusProjection> status;
  bool _disposed = false;

  ProjectionSource<LayoutProjection> get layout => _layout;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      appearance.dispose(),
      locale.dispose(),
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

  static NavigationProjection _readNavigation(
    ClientNavigationController navigation,
  ) => NavigationProjection(
    destination: navigation.currentSection,
    destinations: ClientSection.values.where(
      (destination) => navigation.resolve(destination) == destination,
    ),
  );
}

AppearanceProjection resolveAppearanceProjection(
  AppearancePreferenceOwner appearance,
) => AppearanceProjection(
  presetId: appearance.presetId,
  fontPreference: appearance.fontPreference,
  presets: appearance.presets.map(
    ShellProjectionProducer._projectAppearancePreset,
  ),
);

LocaleProjection resolveLocaleProjection(LocalePreferenceOwner locale) =>
    LocaleProjection(locale.preference);

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
final class _LayoutProjectionSource<T> implements ProjectionSource<T> {
  _LayoutProjectionSource({
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
