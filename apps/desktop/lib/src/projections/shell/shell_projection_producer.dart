import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/projections/application_projection_source.dart';

/// Six independent shell state planes. Composition exclusively owns their
/// shared lifetime, while renderers subscribe only to the plane they consume.
final class ShellProjectionProducer {
  ShellProjectionProducer({
    required ClientShellController shell,
    required ClientNavigationController navigation,
    required LayoutManager layoutManager,
    required LayoutRuntimeSurface Function() readRuntimeSurface,
  }) {
    appearance = ApplicationProjectionSource<AppearanceProjection>(
      changes: shell.changes,
      read: () => _readAppearance(shell),
    );
    locale = ApplicationProjectionSource<LocaleProjection>(
      changes: shell.changes,
      read: () => LocaleProjection(shell.localePreference),
    );
    _layout = _LayoutProjectionSource<LayoutProjection>(
      changes: layoutManager.changes,
      read: () => LayoutProjection(layoutManager.state),
    );
    _environment = _LayoutProjectionSource<EnvironmentProjection>(
      changes: layoutManager.changes,
      read: () => EnvironmentProjection(
        environment: layoutManager.environment,
        runtimeSurface: readRuntimeSurface(),
      ),
    );
    this.navigation = ApplicationProjectionSource<NavigationProjection>(
      changes: navigation.changes,
      read: () => _readNavigation(navigation),
    );
    status = ApplicationProjectionSource<StatusProjection>(
      changes: shell.changes,
      read: () => StatusProjection(
        displayMessage: shell.displayStatusMessage,
        displayCaption: shell.displayStatusCaption,
        errorCode: shell.lastErrorCode,
      ),
    );
  }

  late final ApplicationProjectionSource<AppearanceProjection> appearance;
  late final ApplicationProjectionSource<LocaleProjection> locale;
  late final _LayoutProjectionSource<LayoutProjection> _layout;
  late final _LayoutProjectionSource<EnvironmentProjection> _environment;
  late final ApplicationProjectionSource<NavigationProjection> navigation;
  late final ApplicationProjectionSource<StatusProjection> status;
  bool _disposed = false;

  ProjectionSource<LayoutProjection> get layout => _layout;

  ProjectionSource<EnvironmentProjection> get environment => _environment;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      appearance.dispose(),
      locale.dispose(),
      _layout.dispose(),
      _environment.dispose(),
      navigation.dispose(),
      status.dispose(),
    ]);
  }

  static AppearanceProjection _readAppearance(ClientShellController shell) =>
      AppearanceProjection(
        presetId: shell.appearancePresetId,
        presets: shell.appearancePresetConfigs.map(_projectAppearancePreset),
      );

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

typedef _LayoutProjectionReader<T> = T Function();

/// Equality-suppressing projection over the framework-independent layout
/// change stream.
final class _LayoutProjectionSource<T> implements ProjectionSource<T> {
  _LayoutProjectionSource({
    required Stream<ApplicationChange> changes,
    required _LayoutProjectionReader<T> read,
  }) : _read = read,
       _current = read() {
    _subscription = changes.listen(_handleChange);
  }

  final _LayoutProjectionReader<T> _read;
  final StreamController<ProjectionUpdate<T>> _updates =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  late final StreamSubscription<ApplicationChange> _subscription;
  T _current;
  bool _disposed = false;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _updates.stream;

  void _handleChange(ApplicationChange change) {
    if (_disposed) return;
    final next = _read();
    if (next == _current) return;
    _current = next;
    _updates.add(
      ProjectionUpdate(
        next,
        trace: change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_updates);
  }
}
