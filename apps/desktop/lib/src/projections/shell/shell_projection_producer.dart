import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

/// Focused shell snapshot producer. Composition exclusively owns its lifetime.
final class ShellProjectionProducer
    implements ProjectionSource<ShellProjection> {
  ShellProjectionProducer({
    required ClientShellController shell,
    required ClientNavigationController navigation,
    required LayoutManager layout,
    required bool Function() readMobileSurface,
  }) : _shell = shell,
       _navigation = navigation,
       _layout = layout,
       _readMobileSurface = readMobileSurface,
       _current = _readSnapshot(shell, navigation, layout, readMobileSurface) {
    _shell.addListener(_handleChanged);
    _navigation.addListener(_handleChanged);
    _layout.addListener(_handleLayoutChanged);
  }

  final ClientShellController _shell;
  final ClientNavigationController _navigation;
  final LayoutManager _layout;
  final bool Function() _readMobileSurface;
  final StreamController<ShellProjection> _changes =
      StreamController<ShellProjection>.broadcast(sync: true);
  ShellProjection _current;
  bool _disposed = false;

  @override
  ShellProjection get current => _current;

  @override
  Stream<ShellProjection> get changes => _changes.stream;

  void _handleLayoutChanged(Object _) => _handleChanged();

  void _handleChanged() {
    if (_disposed) return;
    final next = _readSnapshot(
      _shell,
      _navigation,
      _layout,
      _readMobileSurface,
    );
    if (next == _current) return;
    _current = next;
    _changes.add(next);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _layout.removeListener(_handleLayoutChanged);
    _navigation.removeListener(_handleChanged);
    _shell.removeListener(_handleChanged);
    await _changes.close();
  }

  static ShellProjection _readSnapshot(
    ClientShellController shell,
    ClientNavigationController navigation,
    LayoutManager layout,
    bool Function() readMobileSurface,
  ) => ShellProjection(
    layout: ShellLayout(layout.state),
    appearance: ShellAppearance(
      presetId: shell.appearancePresetId,
      presetConfigs: shell.appearancePresetConfigs,
      localePreference: shell.localePreference,
    ),
    environment: ShellEnvironment(mobileSurface: readMobileSurface()),
    status: ShellStatus(
      displayMessage: shell.displayStatusMessage,
      displayCaption: shell.displayStatusCaption,
      errorCode: shell.lastErrorCode,
    ),
    destination: navigation.currentSection,
  );
}
