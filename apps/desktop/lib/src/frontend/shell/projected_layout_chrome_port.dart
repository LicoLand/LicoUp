import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

final class ProjectedLayoutChromePort implements LayoutChromePort {
  ProjectedLayoutChromePort({
    required LayoutChromePort actions,
    required ProjectionSource<StatusProjection> status,
    required ProjectionSource<LocaleProjection> locale,
  }) : _actions = actions,
       _status = status.current,
       _locale = locale.current,
       _notifier = ValueNotifier(_snapshot(status.current, locale.current)) {
    _statusSubscription = status.changes.listen(_handleStatus);
    _localeSubscription = locale.changes.listen(_handleLocale);
  }

  final LayoutChromePort _actions;
  final ValueNotifier<LayoutChromeSnapshot> _notifier;
  StatusProjection _status;
  LocaleProjection _locale;
  late final StreamSubscription<ProjectionUpdate<StatusProjection>>
  _statusSubscription;
  late final StreamSubscription<ProjectionUpdate<LocaleProjection>>
  _localeSubscription;
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
    _status = update.value;
    final next = _snapshot(_status, _locale);
    if (next != _notifier.value) _notifier.value = next;
  }

  void _handleLocale(ProjectionUpdate<LocaleProjection> update) {
    if (_disposed) return;
    _locale = update.value;
    final next = _snapshot(_status, _locale);
    if (next != _notifier.value) _notifier.value = next;
  }

  static LayoutChromeSnapshot _snapshot(
    StatusProjection status,
    LocaleProjection locale,
  ) {
    final resolved = resolveStatusProjection(status, locale);
    return LayoutChromeSnapshot(
      status: LayoutChromeStatusSnapshot(
        message: resolved.message,
        caption: resolved.caption,
        errorCode: resolved.errorCode,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      _statusSubscription.cancel(),
      _localeSubscription.cancel(),
    ]);
    _notifier.dispose();
  }
}
