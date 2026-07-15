import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:path/path.dart' as p;

/// Append-only JSON-lines store for per-task route history.
class RouteHistoryStore {
  RouteHistoryStore({required Directory rootDirectory})
    : _rootDirectory = rootDirectory {
    _ensureCurrentSchema();
  }

  static const String _schemaVersion = '2';

  final Directory _rootDirectory;
  final Map<String, List<RouteHistoryEntry>> _memory = {};

  Directory get _historyDir => Directory(
    p.join(_rootDirectory.path, 'lico-client', 'routing', 'history'),
  );

  File get _schemaFile => File(p.join(_historyDir.path, '.schema'));

  void _ensureCurrentSchema() {
    final directory = _historyDir;
    final schemaIsCurrent =
        _schemaFile.existsSync() &&
        _schemaFile.readAsStringSync().trim() == _schemaVersion;
    if (!schemaIsCurrent && directory.existsSync()) {
      // The superseded schema persisted raw native session identifiers and
      // complete distillation packages. It must be removed, not parsed or
      // retained as a compatibility archive.
      directory.deleteSync(recursive: true);
    }
    directory.createSync(recursive: true);
    if (!_schemaFile.existsSync()) {
      _schemaFile.writeAsStringSync(_schemaVersion, flush: true);
    }
  }

  File _fileFor(String taskId) {
    final safe = taskId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(p.join(_historyDir.path, '$safe.jsonl'));
  }

  Future<void> append(RouteHistoryEntry entry) async {
    final list = _memory.putIfAbsent(entry.taskId, () => <RouteHistoryEntry>[]);
    list.add(entry);
    await _historyDir.create(recursive: true);
    final file = _fileFor(entry.taskId);
    await file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
    );
  }

  List<RouteHistoryEntry> entriesFor(String taskId) {
    return List.unmodifiable(_memory[taskId] ?? const []);
  }

  Future<int> diskLineCount(String taskId) async {
    final file = _fileFor(taskId);
    if (!await file.exists()) {
      return 0;
    }
    final lines = await file.readAsLines();
    return lines.where((line) => line.trim().isNotEmpty).length;
  }

  Future<void> clearTask(String taskId) async {
    _memory.remove(taskId);
    final file = _fileFor(taskId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> clearAll() async {
    _memory.clear();
    if (await _historyDir.exists()) {
      await _historyDir.delete(recursive: true);
    }
    _ensureCurrentSchema();
  }
}
