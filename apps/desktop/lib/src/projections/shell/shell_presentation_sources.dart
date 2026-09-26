import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart'
    show
        shellAppearancePresentationFields,
        shellEnvironmentPresentationFields,
        shellLayoutPresentationFields,
        shellLocalePresentationFields,
        shellNavigationPresentationFields,
        shellStatusPresentationFields;

int _shellSourceIncarnations = 0;

/// The six shell regions as prepared-runtime sources.
///
/// Each region keeps its own field group, so a locale change never waits for
/// the status region and vice versa. The wrapped application sources stay the
/// owners; the adapters only add source identity (epoch, monotonic versions)
/// and one single-member consistency group per accepted change.
final class ShellPresentationSources {
  ShellPresentationSources({
    required ProjectionSource<AppearanceProjection> appearance,
    required ProjectionSource<LocaleProjection> locale,
    required ProjectionSource<LayoutProjection> layout,
    required ProjectionSource<EnvironmentProjection> environment,
    required ProjectionSource<NavigationProjection> navigation,
    required ProjectionSource<StatusProjection> status,
  }) : appearance = _ShellRegionSource<AppearanceProjection>(
         fieldGroup: shellAppearancePresentationFields,
         source: appearance,
       ),
       locale = _ShellRegionSource<LocaleProjection>(
         fieldGroup: shellLocalePresentationFields,
         source: locale,
       ),
       layout = _ShellRegionSource<LayoutProjection>(
         fieldGroup: shellLayoutPresentationFields,
         source: layout,
       ),
       environment = _ShellRegionSource<EnvironmentProjection>(
         fieldGroup: shellEnvironmentPresentationFields,
         source: environment,
       ),
       navigation = _ShellRegionSource<NavigationProjection>(
         fieldGroup: shellNavigationPresentationFields,
         source: navigation,
       ),
       status = _ShellRegionSource<StatusProjection>(
         fieldGroup: shellStatusPresentationFields,
         source: status,
       );

  final PresentationSource<AppearanceProjection> appearance;
  final PresentationSource<LocaleProjection> locale;
  final PresentationSource<LayoutProjection> layout;
  final PresentationSource<EnvironmentProjection> environment;
  final PresentationSource<NavigationProjection> navigation;
  final PresentationSource<StatusProjection> status;

  /// Releases every open region observation with its last listener.
  Future<void> dispose() async {
    for (final source in <Object>[
      appearance,
      locale,
      layout,
      environment,
      navigation,
      status,
    ]) {
      await (source as _ShellRegionSource<Object?>).dispose();
    }
  }
}

final class _ShellRegionSource<T> implements PresentationSource<T> {
  _ShellRegionSource({
    required this.fieldGroup,
    required ProjectionSource<T> source,
  }) : _source = source,
       _epoch = SourceEpoch('shell-${++_shellSourceIncarnations}');

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ProjectionSource<T> _source;
  final SourceEpoch _epoch;
  final Set<StreamController<SourceChange<T>>> _listeners =
      <StreamController<SourceChange<T>>>{};
  StreamSubscription<ProjectionUpdate<T>>? _subscription;
  bool _disposed = false;

  @override
  Future<SourceObservation<T>> open() {
    if (_disposed) {
      return Future<SourceObservation<T>>.error(
        StateError('shell presentation source is disposed'),
      );
    }
    _subscription ??= _source.changes.listen(_accept);
    final position = _nextPosition();
    final controller = StreamController<SourceChange<T>>(sync: true);
    controller.onCancel = () => _release(controller);
    _listeners.add(controller);
    return Future<SourceObservation<T>>.value(
      SourceObservation<T>(
        initial: ResourceSnapshot<T>(
          fieldGroup: fieldGroup,
          epoch: position.epoch,
          version: position.version,
          value: _source.current,
        ),
        changes: controller.stream,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    for (final controller in _listeners.toList()) {
      // A listener whose stream was never attached never completes its close
      // future; closing is best-effort since disposal is terminal anyway.
      unawaited(controller.close());
    }
    _listeners.clear();
  }

  void _release(StreamController<SourceChange<T>> controller) {
    if (!_listeners.remove(controller)) return;
    unawaited(controller.close());
    if (_listeners.isEmpty) {
      final subscription = _subscription;
      _subscription = null;
      unawaited(subscription?.cancel());
    }
  }

  int _version = 0;

  SourcePosition _nextPosition() {
    _version += 1;
    return SourcePosition(epoch: _epoch, version: SourceVersion(_version));
  }

  void _accept(ProjectionUpdate<T> update) {
    if (_disposed || _listeners.isEmpty) return;
    final position = _nextPosition();
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${fieldGroup.resource.stableKey}-${position.version.value}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<T>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: update.value,
      consistencyGroup: group,
    );
    for (final controller in _listeners.toList()) {
      if (!controller.isClosed) {
        controller.add(
          SourceChange<T>(
            snapshot: snapshot,
            base: SourcePosition(
              epoch: position.epoch,
              version: SourceVersion(position.version.value - 1),
            ),
            group: group,
            trace: update.trace,
          ),
        );
      }
    }
  }
}
