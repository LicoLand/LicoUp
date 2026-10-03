import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Everything a first launch decides, in one durable document.
///
/// The marker and the declines live together because they answer the same
/// question: "has this data home already been offered these packages?" A data
/// home without the document has never completed a first launch, so the offer is
/// made once and never again — including for a package the user declined, and
/// including a launch that finished without installing anything.
final class PackageFirstLaunchRecord {
  const PackageFirstLaunchRecord({
    this.firstLaunchCompleted = false,
    Map<String, String> declines = const {},
  }) : _declines = declines;

  factory PackageFirstLaunchRecord.fromJson(Map<String, dynamic> json) {
    final rawDeclines = json['declinedPackages'];
    final declines = <String, String>{};
    if (rawDeclines is Map) {
      for (final entry in rawDeclines.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && key.trim().isNotEmpty) {
          declines[key] = value is String ? value : '';
        }
      }
    }
    return PackageFirstLaunchRecord(
      firstLaunchCompleted: json['firstLaunchCompleted'] == true,
      declines: declines,
    );
  }

  final bool firstLaunchCompleted;
  final Map<String, String> _declines;

  Map<String, String> get declines => Map.unmodifiable(_declines);

  bool declined(String packageId) => _declines.containsKey(packageId);

  PackageFirstLaunchRecord completed() =>
      PackageFirstLaunchRecord(firstLaunchCompleted: true, declines: _declines);

  PackageFirstLaunchRecord withDecline(String packageId, String reason) =>
      PackageFirstLaunchRecord(
        firstLaunchCompleted: firstLaunchCompleted,
        declines: {..._declines, packageId: reason},
      );

  Map<String, dynamic> toJson() => {
    'firstLaunchCompleted': firstLaunchCompleted,
    'declinedPackages': _declines,
  };
}

/// Port for the durable first-launch document.
///
/// The platform layer ships the file-backed implementation; tests supply an
/// in-memory one, so the recommendation flow is deterministic without touching a
/// real data home.
abstract class PackageFirstLaunchStore {
  const PackageFirstLaunchStore();

  Future<PackageFirstLaunchRecord> load();

  Future<void> save(PackageFirstLaunchRecord record);
}

/// File-backed first-launch document in the client state directory.
///
/// It resolves its path through [PortableDataRoot.clientDirectory], so it always
/// follows the selected data home, and it replaces the file atomically so an
/// interrupted write cannot leave a half document that would re-offer the
/// packages.
final class FilePackageFirstLaunchStore extends PackageFirstLaunchStore {
  FilePackageFirstLaunchStore(this._portableData);

  static const fileName = 'package-first-launch.json';
  static const _schema = 'lico.package-first-launch.v1';

  final PortableDataRoot _portableData;

  Future<File> file() async {
    final directory = await _portableData.clientDirectory();
    return File(p.join(directory.path, fileName));
  }

  @override
  Future<PackageFirstLaunchRecord> load() async {
    final target = await file();
    if (!await target.exists()) return const PackageFirstLaunchRecord();
    try {
      final decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map) return const PackageFirstLaunchRecord();
      if (decoded['schemaVersion'] != _schema) {
        return const PackageFirstLaunchRecord();
      }
      return PackageFirstLaunchRecord.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } on FormatException {
      return const PackageFirstLaunchRecord();
    } on FileSystemException {
      return const PackageFirstLaunchRecord();
    }
  }

  @override
  Future<void> save(PackageFirstLaunchRecord record) async {
    final target = await file();
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({...record.toJson(), 'schemaVersion': _schema}),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}

/// In-memory first-launch document for tests and for a run whose data home
/// cannot be written. A failed save leaves the previous decision in force for
/// this process.
final class MemoryPackageFirstLaunchStore extends PackageFirstLaunchStore {
  MemoryPackageFirstLaunchStore([
    this._record = const PackageFirstLaunchRecord(),
  ]);

  PackageFirstLaunchRecord _record;

  @override
  Future<PackageFirstLaunchRecord> load() async => _record;

  @override
  Future<void> save(PackageFirstLaunchRecord record) async {
    _record = record;
  }
}
