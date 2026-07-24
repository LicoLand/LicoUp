import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// Persists the last successful local agent discovery snapshot so the Agents
/// sidebar can paint immediately on the next launch without waiting for scan.
abstract class ScannedTargetsCacheStore implements TargetSnapshotRepository {
  const ScannedTargetsCacheStore();

  @override
  Future<List<TargetCandidate>> load(Object portableData);

  @override
  Future<void> save(Object portableData, List<TargetCandidate> targets);
}

class PlatformScannedTargetsCacheStore implements ScannedTargetsCacheStore {
  const PlatformScannedTargetsCacheStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'scanned-targets-cache.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<List<TargetCandidate>> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, _fileName);
    if (decoded is! Map) {
      return const [];
    }
    // v2: runtime.message.send no longer requires parity evidence, so cached
    // capability snapshots from older semantics must be refreshed once.
    if (decoded['schemaVersion'] != 2) {
      return const [];
    }
    final raw = decoded['candidates'];
    if (raw is! List) {
      return const [];
    }
    final result = <TargetCandidate>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final candidateJson = Map<String, dynamic>.from(item);
      // A cache is paint-fast metadata, not executable authority. Do not stat
      // cached paths here: they may point at macOS-protected user folders or
      // network volumes and trigger privacy prompts during app startup. The
      // mandatory background rescan restores a current executable binding.
      candidateJson.remove('binaryPath');
      if (candidateJson['supportedActions'] is List) {
        candidateJson['supportedActions'] =
            (candidateJson['supportedActions'] as List)
                .where((action) => action != 'runtime.message.send')
                .toList(growable: false);
      }
      final candidate = TargetCandidate.fromJson(candidateJson);
      final id = candidate.target.trim();
      if (id.isEmpty || !candidate.visibleInClient || !seen.add(id)) {
        continue;
      }
      result.add(candidate);
    }
    return List.unmodifiable(result);
  }

  @override
  Future<void> save(Object portableData, List<TargetCandidate> targets) {
    final candidates = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final target in targets) {
      final id = target.target.trim();
      if (id.isEmpty || !target.visibleInClient || !seen.add(id)) {
        continue;
      }
      candidates.add(target.toJson());
    }
    return _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 2,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'candidates': candidates,
    }, lock: true);
  }
}
