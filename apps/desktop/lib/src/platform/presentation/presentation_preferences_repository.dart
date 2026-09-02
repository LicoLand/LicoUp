import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

typedef PresentationPreferencesBeforeReplace =
    Future<void> Function(File temporary, File destination);

/// File-backed preferences with a single in-process mutation tail and lock.
final class FilePresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  FilePresentationPreferencesRepository({
    required PortableDataRoot portableData,
    required PresentationPreferences fallback,
    PresentationPreferencesBeforeReplace? beforeReplace,
  }) : _portableData = portableData,
       _fallback = fallback,
       _beforeReplace = beforeReplace;

  static const _fileName = 'appearance-preferences.json';
  static int _temporarySequence = 0;

  final PortableDataRoot _portableData;
  final PresentationPreferences _fallback;
  final PresentationPreferencesBeforeReplace? _beforeReplace;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<PresentationPreferencesLoadResult> load() => _enqueue(_loadWithLock);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) =>
      _update((current) => current.copyWith(layoutProfileId: id));

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) =>
      _update((current) => current.copyWith(appearancePresetId: id));

  @override
  Future<PresentationPreferences> setLocalePreference(String preference) =>
      _update((current) => current.copyWith(localePreference: preference));

  Future<PresentationPreferences> _update(
    PresentationPreferences Function(PresentationPreferences current) mutate,
  ) => _enqueue(() async {
    final destination = await _preferencesFile();
    return _withFileLock(
      destination,
      () async {
        final loaded = await _read(destination);
        final next = mutate(loaded.preferences);
        await _writeAtomically(destination, next);
        return next;
      },
      errorCode: PresentationPreferencesRepositoryErrorCode.writeFailed,
    );
  });

  Future<PresentationPreferencesLoadResult> _loadWithLock() async {
    final destination = await _preferencesFile();
    return _withFileLock(
      destination,
      () => _read(destination),
      errorCode: PresentationPreferencesRepositoryErrorCode.readFailed,
    );
  }

  Future<PresentationPreferencesLoadResult> _read(File destination) async {
    if (!await destination.exists()) {
      return PresentationPreferencesLoadResult(preferences: _fallback);
    }
    try {
      final decoded = jsonDecode(await destination.readAsString());
      if (decoded is! Map) {
        throw const FormatException('presentation_document_invalid');
      }
      return PresentationPreferencesLoadResult(
        preferences: PresentationPreferences.fromJson(
          Map<String, Object?>.from(decoded),
          fallback: _fallback,
        ),
      );
    } on FormatException {
      throw const PresentationPreferencesRepositoryException(
        PresentationPreferencesRepositoryErrorCode.readFailed,
      );
    }
  }

  Future<void> _writeAtomically(
    File destination,
    PresentationPreferences preferences,
  ) async {
    await destination.parent.create(recursive: true);
    final temporary = File(
      p.join(
        destination.parent.path,
        '.${p.basename(destination.path)}.$pid.${++_temporarySequence}.tmp',
      ),
    );
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(preferences.toJson()),
        flush: true,
      );
      await _beforeReplace?.call(temporary, destination);
      await temporary.rename(destination.path);
    } on FileSystemException {
      throw const PresentationPreferencesRepositoryException(
        PresentationPreferencesRepositoryErrorCode.writeFailed,
      );
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // Best-effort cleanup; never expose the local path in an error.
        }
      }
    }
  }

  Future<T> _withFileLock<T>(
    File destination,
    Future<T> Function() operation, {
    required PresentationPreferencesRepositoryErrorCode errorCode,
  }) async {
    try {
      await destination.parent.create(recursive: true);
      final lock = File(
        p.join(destination.parent.path, '${p.basename(destination.path)}.lock'),
      );
      final handle = await lock.open(mode: FileMode.write);
      try {
        await handle.lock(FileLock.exclusive);
        return await operation();
      } finally {
        try {
          await handle.unlock();
        } finally {
          await handle.close();
        }
      }
    } on PresentationPreferencesRepositoryException {
      rethrow;
    } on FileSystemException {
      throw PresentationPreferencesRepositoryException(errorCode);
    }
  }

  Future<File> _preferencesFile() async {
    try {
      final root = await _portableData.clientDirectory();
      return File(p.join(root.path, _fileName));
    } on FileSystemException {
      throw const PresentationPreferencesRepositoryException(
        PresentationPreferencesRepositoryErrorCode.readFailed,
      );
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
