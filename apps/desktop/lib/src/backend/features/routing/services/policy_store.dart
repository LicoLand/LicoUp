import 'dart:async';
import 'dart:io';

import 'package:flutter_client/src/backend/features/routing/services/policy_file_watcher.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:path/path.dart' as p;

/// Default relative path under the portable data root for the active policy.
const String defaultRoutingPolicyRelativePath =
    'future-client/routing/routing-policy.json';

/// File-backed [RoutingPolicyStore] with atomic snapshot swap and hot reload.
class FileRoutingPolicyStore implements RoutingPolicyStore {
  FileRoutingPolicyStore({
    required Directory rootDirectory,
    String relativePolicyPath = defaultRoutingPolicyRelativePath,
    PolicyFileWatcher? watcher,
    Duration? watchDebounce,
  }) : _rootDirectory = rootDirectory,
       _relativePolicyPath = relativePolicyPath,
       _watcher =
           watcher ??
           DebouncedPolicyFileWatcher(
             debounce: watchDebounce ?? routingPolicyWatchDebounce,
           );

  final Directory _rootDirectory;
  final String _relativePolicyPath;
  final PolicyFileWatcher _watcher;

  final StreamController<RoutingPolicyStoreEvent> _events =
      StreamController<RoutingPolicyStoreEvent>.broadcast();

  RoutingPolicyDocument _active = emptyRoutingPolicyDocument;
  RoutingPolicyValidationError? _lastError;
  StreamSubscription<String>? _watchSubscription;
  bool _loaded = false;
  bool _disposed = false;
  bool _watching = false;

  @override
  RoutingPolicyDocument get active => _active;

  @override
  RoutingPolicyValidationError? get lastError => _lastError;

  File get policyFile =>
      File(p.join(_rootDirectory.path, _relativePolicyPath));

  @override
  Future<RoutingPolicyDocument> load() async {
    _ensureNotDisposed();
    final file = policyFile;
    if (!await file.exists()) {
      _active = emptyRoutingPolicyDocument;
      _lastError = null;
      _loaded = true;
      _emit(RoutingPolicyStoreLoaded(_active));
      return _active;
    }

    final source = await file.readAsString();
    final parsed = parseRoutingPolicyDocument(
      source,
      sourcePath: file.path,
    );
    switch (parsed) {
      case RoutingPolicyParseSuccess(:final document):
        _active = document;
        _lastError = null;
        _loaded = true;
        _emit(RoutingPolicyStoreLoaded(document));
        return document;
      case RoutingPolicyParseFailure(:final error):
        // Initial load with a malformed file: keep empty policy, surface error.
        _active = emptyRoutingPolicyDocument;
        _lastError = error;
        _loaded = true;
        _emit(RoutingPolicyStoreValidationFailed(error));
        _emit(RoutingPolicyStoreLoaded(_active));
        return _active;
    }
  }

  @override
  Stream<RoutingPolicyStoreEvent> watch() {
    _ensureNotDisposed();
    if (!_loaded) {
      throw StateError('Call load() before watch().');
    }
    if (!_watching) {
      _watching = true;
      // Attach before start() so injected/test signals are never missed.
      _watchSubscription = _watcher.changes.listen((_) {
        unawaited(_reloadFromDisk());
      });
      unawaited(_prepareAndStartWatcher());
    }
    return _events.stream;
  }

  Future<void> _prepareAndStartWatcher() async {
    final file = policyFile;
    await file.parent.create(recursive: true);
    await _watcher.start(file);
  }

  /// Force a reload from disk (also used by tests).
  Future<void> reload() => _reloadFromDisk();

  Future<void> _reloadFromDisk() async {
    if (_disposed) {
      return;
    }
    final file = policyFile;
    if (!await file.exists()) {
      // File removed: retain last good policy and surface an error.
      final error = RoutingPolicyValidationError(
        path: file.path,
        message: 'Policy file was removed; retaining last good snapshot.',
      );
      _lastError = error;
      _emit(RoutingPolicyStoreValidationFailed(error));
      return;
    }

    final source = await file.readAsString();
    final parsed = parseRoutingPolicyDocument(
      source,
      sourcePath: file.path,
    );
    switch (parsed) {
      case RoutingPolicyParseSuccess(:final document):
        // Atomic snapshot swap: single reference assignment of an immutable
        // document. Concurrent readers never observe a torn intermediate.
        _active = document;
        _lastError = null;
        _emit(RoutingPolicyStoreReloaded(document));
      case RoutingPolicyParseFailure(:final error):
        // Retain last good policy; surface the validation error.
        _lastError = error;
        _emit(RoutingPolicyStoreValidationFailed(error));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _watchSubscription?.cancel();
    _watchSubscription = null;
    await _watcher.dispose();
    await _events.close();
  }

  void _emit(RoutingPolicyStoreEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('RoutingPolicyStore is disposed.');
    }
  }
}
