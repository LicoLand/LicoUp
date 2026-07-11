import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Default quiet window before a policy file change is delivered.
const Duration routingPolicyWatchDebounce = Duration(milliseconds: 200);

/// Emits policy-file change signals. Implementations may use Dart
/// [Directory.watch] or a future FFI bridge to the Rust `notify` sidecar.
abstract class PolicyFileWatcher {
  /// Stream of absolute paths that changed and should be reloaded.
  Stream<String> get changes;

  /// Begin watching [policyFile]. Idempotent.
  Future<void> start(File policyFile);

  /// Stop watching and release resources.
  Future<void> dispose();
}

/// Debounced file watcher backed by [FileSystemEntity.watch].
///
/// Rapid write bursts (editor auto-save) coalesce into one event after
/// [debounce] of quiet time. Injectable [watchFactory] supports tests.
class DebouncedPolicyFileWatcher implements PolicyFileWatcher {
  DebouncedPolicyFileWatcher({
    this.debounce = routingPolicyWatchDebounce,
    Stream<FileSystemEvent> Function(File file)? watchFactory,
  }) : _watchFactory = watchFactory ?? _defaultWatch;

  final Duration debounce;
  final Stream<FileSystemEvent> Function(File file) _watchFactory;

  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _debounceTimer;
  String? _watchedPath;
  bool _disposed = false;

  @override
  Stream<String> get changes => _controller.stream;

  @override
  Future<void> start(File policyFile) async {
    if (_disposed) {
      throw StateError('PolicyFileWatcher is disposed.');
    }
    await _subscription?.cancel();
    _debounceTimer?.cancel();
    _watchedPath = p.normalize(policyFile.absolute.path);
    final parent = policyFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    _subscription = _watchFactory(policyFile).listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_controller.isClosed) {
          _controller.addError(error, stackTrace);
        }
      },
    );
  }

  void _onEvent(FileSystemEvent event) {
    final watched = _watchedPath;
    if (watched == null) {
      return;
    }
    final eventPath = p.normalize(event.path);
    final watchedName = p.basename(watched);
    final eventName = p.basename(eventPath);
    final matchesFile =
        eventPath == watched ||
        (event.isDirectory == false && eventName == watchedName);
    if (!matchesFile && event.type != FileSystemEvent.modify) {
      // Directory-level watches may report the file path directly.
      if (eventPath != watched && !eventPath.endsWith(watchedName)) {
        return;
      }
    }
    if (!matchesFile && !eventPath.endsWith(watchedName)) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      if (_disposed || _controller.isClosed) {
        return;
      }
      _controller.add(watched);
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }

  static Stream<FileSystemEvent> _defaultWatch(File file) {
    // Watch the parent directory so atomic replace (delete+create) is visible.
    return file.parent.watch(recursive: false);
  }
}
