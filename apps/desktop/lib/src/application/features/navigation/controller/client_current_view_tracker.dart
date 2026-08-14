import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/presentation/client_current_view.dart';

/// Process-wide source of truth for the interface the user is using.
///
/// Production uses [instance]. The tracker serializes persistence so rapid
/// navigation can never let an older asynchronous write replace a newer view.
final class ClientCurrentViewTracker extends ChangeNotifier {
  ClientCurrentViewTracker();

  static final ClientCurrentViewTracker instance = ClientCurrentViewTracker();

  ClientCurrentView? _current;
  ClientCurrentView? _pendingDuringLoad;
  bool _loaded = false;
  int _bindingEpoch = 0;
  Future<void> _writeTail = Future<void>.value();
  ClientCurrentViewStore? _store;
  Object? _portableData;

  ClientCurrentView? get current => _current;
  bool get loaded => _loaded;

  Future<void> load({
    required ClientCurrentViewStore store,
    required Object portableData,
  }) async {
    final epoch = ++_bindingEpoch;
    _loaded = false;
    _store = store;
    _portableData = portableData;
    ClientCurrentView? restored;
    try {
      restored = await store.load(portableData);
    } on Object {
      restored = null;
    }
    if (epoch != _bindingEpoch) return;
    final pending = _pendingDuringLoad;
    _pendingDuringLoad = null;
    _current = pending ?? restored;
    _loaded = true;
    notifyListeners();
    if (pending != null) _enqueueSave(store, portableData, pending);
  }

  void record(ClientCurrentView view) {
    if (!_loaded) {
      _pendingDuringLoad = view;
      if (view != _current) {
        _current = view;
        notifyListeners();
      }
      return;
    }
    if (view == _current) return;
    final store = _store;
    final portableData = _portableData;
    if (store == null || portableData == null) return;
    _current = view;
    notifyListeners();
    _enqueueSave(store, portableData, view);
  }

  void _enqueueSave(
    ClientCurrentViewStore store,
    Object portableData,
    ClientCurrentView view,
  ) {
    _writeTail = _writeTail
        .catchError((Object _) {})
        .then((_) => store.save(portableData, view))
        .catchError((Object _) {});
  }

  Future<void> flush() => _writeTail.catchError((Object _) {});
}
