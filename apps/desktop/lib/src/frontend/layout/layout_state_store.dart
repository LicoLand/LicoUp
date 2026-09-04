import 'dart:async';

import 'package:licoup/src/presentation/layout/layout_catalog.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';

/// Bounded, renderer-local state keyed exclusively by catalog declarations.
///
/// Listeners are notified after every mutation so shell chrome and destination
/// content sharing one channel (for example the settings section tab) stay in
/// sync without a direct widget link.
final class LayoutStateStore implements LayoutStatePort {
  LayoutStateStore(this.catalog);

  final LayoutCatalog catalog;
  final Map<LayoutStateNamespace, LayoutPresentationStateValue> _values = {};
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  int get length => _values.length;

  @override
  Object get catalogIdentity => catalog;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool declares(LayoutStateNamespace namespace) =>
      catalog.declaresStateNamespace(namespace);

  @override
  LayoutPresentationStateValue? read(LayoutStateNamespace namespace) {
    _requireDeclared(namespace);
    return _values[namespace];
  }

  @override
  void write(
    LayoutStateNamespace namespace,
    LayoutPresentationStateValue value,
  ) {
    _requireDeclared(namespace);
    if (namespace.valueKind != value.kind) {
      throw const FormatException('layout_state_value_kind_mismatch');
    }
    if (_values[namespace] == value) return;
    _values[namespace] = value;
    _notifyListeners();
  }

  @override
  void remove(LayoutStateNamespace namespace) {
    _requireDeclared(namespace);
    if (_values.remove(namespace) != null) {
      _notifyListeners();
    }
  }

  void resetProfile(LayoutProfileId profileId) {
    final before = _values.length;
    _values.removeWhere((namespace, _) => namespace.profileId == profileId);
    if (_values.length == before) return;
    _notifyListeners();
  }

  void resetAll() {
    if (_values.isEmpty) return;
    _values.clear();
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) _changes.add(null);
  }

  void _requireDeclared(LayoutStateNamespace namespace) {
    if (!declares(namespace)) {
      throw const FormatException('layout_state_namespace_unregistered');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }
}
