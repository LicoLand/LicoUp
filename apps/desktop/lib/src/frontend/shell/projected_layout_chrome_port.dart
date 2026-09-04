import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

final class ProjectedLayoutChromePort implements LayoutChromePort {
  ProjectedLayoutChromePort({
    required LayoutChromePort actions,
    required ProjectionSource<StatusProjection> status,
  }) : _actions = actions,
       _notifier = ValueNotifier(_snapshot(status.current)) {
    _subscription = status.changes.listen(_handleStatus);
  }

  final LayoutChromePort _actions;
  final ValueNotifier<LayoutChromeSnapshot> _notifier;
  late final StreamSubscription<ProjectionUpdate<StatusProjection>>
  _subscription;
  bool _disposed = false;

  @override
  LayoutChromeSnapshot get value => _notifier.value;
  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);
  @override
  Future<void> openPairing(BuildContext context) =>
      _actions.openPairing(context);
  @override
  Future<void> openGlobalSearch(BuildContext context) =>
      _actions.openGlobalSearch(context);

  void _handleStatus(ProjectionUpdate<StatusProjection> update) {
    if (_disposed) return;
    final next = _snapshot(update.value);
    if (next != _notifier.value) _notifier.value = next;
  }

  static LayoutChromeSnapshot _snapshot(StatusProjection status) =>
      LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: status.displayMessage,
          caption: status.displayCaption,
          errorCode: status.errorCode,
        ),
      );

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _notifier.dispose();
  }
}
