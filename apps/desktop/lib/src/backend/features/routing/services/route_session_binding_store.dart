import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A private mapping between an opaque routing handle and an agent's native
/// session identifier.
///
/// Native identifiers never belong in route-history records. This store is a
/// separate recovery boundary whose directory and file are owner-only on
/// POSIX hosts.
class RouteSessionBinding {
  const RouteSessionBinding({
    required this.logicalHandle,
    required this.taskDigest,
    required this.agentId,
    required this.nativeSessionId,
    required this.sequence,
  });

  final String logicalHandle;
  final String taskDigest;
  final String agentId;
  final String nativeSessionId;
  final int sequence;

  Map<String, dynamic> toJson() => {
    'logicalHandle': logicalHandle,
    'taskDigest': taskDigest,
    'agentId': agentId,
    'nativeSessionId': nativeSessionId,
    'sequence': sequence,
  };

  factory RouteSessionBinding.fromJson(Map<String, dynamic> json) {
    final logicalHandle = (json['logicalHandle'] ?? '').toString().trim();
    final taskDigest = (json['taskDigest'] ?? '').toString().trim();
    final agentId = (json['agentId'] ?? '').toString().trim();
    final nativeSessionId = (json['nativeSessionId'] ?? '').toString().trim();
    final sequence = json['sequence'];
    if (!_logicalHandlePattern.hasMatch(logicalHandle) ||
        !_digestPattern.hasMatch(taskDigest) ||
        agentId.isEmpty ||
        nativeSessionId.isEmpty ||
        sequence is! int ||
        sequence < 1) {
      throw const FormatException('Invalid protected route-session binding.');
    }
    return RouteSessionBinding(
      logicalHandle: logicalHandle,
      taskDigest: taskDigest,
      agentId: agentId,
      nativeSessionId: nativeSessionId,
      sequence: sequence,
    );
  }
}

/// Restart-safe private binding store for exact native-session continuation.
///
/// The public route-history store persists only opaque logical handles and
/// digests. Raw native identifiers are recoverable only through this boundary.
class ProtectedRouteSessionBindingStore {
  ProtectedRouteSessionBindingStore({required Directory rootDirectory})
    : _rootDirectory = rootDirectory {
    _load();
  }

  static const int _schemaVersion = 1;

  final Directory _rootDirectory;
  final Random _random = Random.secure();
  final Map<String, RouteSessionBinding> _byHandle = {};
  final Map<String, String> _handleByExactBinding = {};
  final Set<String> _taskNativeSessionKeys = {};
  final Map<String, RouteSessionBinding> _currentByTaskDigest = {};
  final Map<String, RouteSessionBinding> _currentByTaskAgent = {};
  int _sequence = 0;

  Directory get _bindingDir => Directory(
    p.join(_rootDirectory.path, 'lico-client', 'routing', 'private-bindings'),
  );

  File get _bindingFile => File(p.join(_bindingDir.path, 'bindings.json'));

  String bind({
    required String taskId,
    required String agentId,
    required String nativeSessionId,
  }) {
    final normalizedTaskId = taskId.trim();
    final normalizedAgentId = agentId.trim();
    final normalizedNativeSessionId = nativeSessionId.trim();
    if (normalizedTaskId.isEmpty ||
        normalizedAgentId.isEmpty ||
        normalizedNativeSessionId.isEmpty) {
      throw StateError('A route-session binding field was empty.');
    }

    final taskDigest = digestRoutePrivateValue(normalizedTaskId);
    final exactKey = _exactBindingKey(
      taskDigest,
      normalizedAgentId,
      normalizedNativeSessionId,
    );
    final existingHandle = _handleByExactBinding[exactKey];
    final handle = existingHandle ?? _newLogicalHandle();
    final binding = RouteSessionBinding(
      logicalHandle: handle,
      taskDigest: taskDigest,
      agentId: normalizedAgentId,
      nativeSessionId: normalizedNativeSessionId,
      sequence: ++_sequence,
    );
    _byHandle[handle] = binding;
    _handleByExactBinding[exactKey] = handle;
    _taskNativeSessionKeys.add(
      _taskNativeSessionKey(taskDigest, normalizedNativeSessionId),
    );
    _currentByTaskDigest[taskDigest] = binding;
    _currentByTaskAgent[_taskAgentKey(taskDigest, normalizedAgentId)] = binding;
    _persist();
    return handle;
  }

  RouteSessionBinding? currentForTask(String taskId) {
    final normalized = taskId.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return _currentByTaskDigest[digestRoutePrivateValue(normalized)];
  }

  RouteSessionBinding? bindingForHandle(String logicalHandle) {
    return _byHandle[logicalHandle.trim()];
  }

  /// Returns the latest exact native binding for one task/agent branch.
  ///
  /// This indexed lookup lets routing return to an earlier agent without
  /// opening a replacement native session or scanning the binding history.
  RouteSessionBinding? currentForTaskAgent({
    required String taskId,
    required String agentId,
  }) {
    final normalizedTaskId = taskId.trim();
    final normalizedAgentId = agentId.trim();
    if (normalizedTaskId.isEmpty || normalizedAgentId.isEmpty) {
      return null;
    }
    return _currentByTaskAgent[_taskAgentKey(
      digestRoutePrivateValue(normalizedTaskId),
      normalizedAgentId,
    )];
  }

  bool containsNativeSession({
    required String taskId,
    required String nativeSessionId,
  }) {
    final normalizedTaskId = taskId.trim();
    final normalizedNativeSessionId = nativeSessionId.trim();
    if (normalizedTaskId.isEmpty || normalizedNativeSessionId.isEmpty) {
      return false;
    }
    final taskDigest = digestRoutePrivateValue(normalizedTaskId);
    return _taskNativeSessionKeys.contains(
      _taskNativeSessionKey(taskDigest, normalizedNativeSessionId),
    );
  }

  void clearTask(String taskId) {
    final normalized = taskId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final taskDigest = digestRoutePrivateValue(normalized);
    final handles = _byHandle.values
        .where((binding) => binding.taskDigest == taskDigest)
        .map((binding) => binding.logicalHandle)
        .toList(growable: false);
    for (final handle in handles) {
      final removed = _byHandle.remove(handle);
      if (removed != null) {
        _handleByExactBinding.remove(
          _exactBindingKey(
            removed.taskDigest,
            removed.agentId,
            removed.nativeSessionId,
          ),
        );
        _taskNativeSessionKeys.remove(
          _taskNativeSessionKey(removed.taskDigest, removed.nativeSessionId),
        );
      }
    }
    _currentByTaskDigest.remove(taskDigest);
    _currentByTaskAgent.removeWhere(
      (key, _) => key.startsWith('$taskDigest\u0000'),
    );
    _persist();
  }

  void _load() {
    final file = _bindingFile;
    if (!file.existsSync()) {
      return;
    }
    _rejectLink(_bindingDir.path, expected: FileSystemEntityType.directory);
    _hardenPath(_bindingDir.path, directory: true);
    _rejectLink(file.path, expected: FileSystemEntityType.file);
    _hardenPath(file.path, directory: false);
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != _schemaVersion ||
        decoded['bindings'] is! List) {
      throw const FormatException('Invalid protected binding store.');
    }
    for (final raw in decoded['bindings'] as List<dynamic>) {
      if (raw is! Map) {
        throw const FormatException('Invalid protected binding store.');
      }
      final binding = RouteSessionBinding.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (_byHandle.containsKey(binding.logicalHandle)) {
        throw const FormatException('Duplicate protected binding handle.');
      }
      _byHandle[binding.logicalHandle] = binding;
      _handleByExactBinding[_exactBindingKey(
            binding.taskDigest,
            binding.agentId,
            binding.nativeSessionId,
          )] =
          binding.logicalHandle;
      _taskNativeSessionKeys.add(
        _taskNativeSessionKey(binding.taskDigest, binding.nativeSessionId),
      );
      final current = _currentByTaskDigest[binding.taskDigest];
      if (current == null || binding.sequence > current.sequence) {
        _currentByTaskDigest[binding.taskDigest] = binding;
      }
      final taskAgentKey = _taskAgentKey(binding.taskDigest, binding.agentId);
      final currentAgentBinding = _currentByTaskAgent[taskAgentKey];
      if (currentAgentBinding == null ||
          binding.sequence > currentAgentBinding.sequence) {
        _currentByTaskAgent[taskAgentKey] = binding;
      }
      if (binding.sequence > _sequence) {
        _sequence = binding.sequence;
      }
    }
  }

  void _persist() {
    final directory = _bindingDir;
    directory.createSync(recursive: true);
    _rejectLink(directory.path, expected: FileSystemEntityType.directory);
    _hardenPath(directory.path, directory: true);

    final payload = jsonEncode({
      'schemaVersion': _schemaVersion,
      'bindings': [for (final binding in _byHandle.values) binding.toJson()],
    });
    final temporary = File(
      p.join(directory.path, '.bindings.${_newLogicalHandle()}.tmp'),
    );
    temporary.writeAsStringSync(payload, flush: true);
    _hardenPath(temporary.path, directory: false);
    if (Platform.isWindows && _bindingFile.existsSync()) {
      _bindingFile.deleteSync();
    }
    temporary.renameSync(_bindingFile.path);
    _hardenPath(_bindingFile.path, directory: false);
  }

  String _newLogicalHandle() {
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    return 'rh_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  static String _exactBindingKey(
    String taskDigest,
    String agentId,
    String nativeSessionId,
  ) => '$taskDigest\u0000$agentId\u0000$nativeSessionId';

  static String _taskNativeSessionKey(
    String taskDigest,
    String nativeSessionId,
  ) => '$taskDigest\u0000$nativeSessionId';

  static String _taskAgentKey(String taskDigest, String agentId) =>
      '$taskDigest\u0000$agentId';

  static void _rejectLink(
    String path, {
    required FileSystemEntityType expected,
  }) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != expected) {
      throw StateError(
        'Protected route-session storage is not a regular path.',
      );
    }
  }

  static void _hardenPath(String path, {required bool directory}) {
    if (Platform.isWindows) {
      // Windows inherits the application's private data-root ACL. The native
      // packaging boundary owns that ACL; never copy this file to public state.
      return;
    }
    final result = Process.runSync('chmod', [directory ? '700' : '600', path]);
    if (result.exitCode != 0) {
      throw StateError('Could not protect route-session storage.');
    }
  }
}

String digestRoutePrivateValue(String value) {
  return sha256.convert(utf8.encode(value)).toString();
}

final RegExp _logicalHandlePattern = RegExp(r'^rh_[A-Za-z0-9_-]{24}$');
final RegExp _digestPattern = RegExp(r'^[a-f0-9]{64}$');
