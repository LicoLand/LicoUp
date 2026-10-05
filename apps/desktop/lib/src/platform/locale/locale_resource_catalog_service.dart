import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/locale/locale_resource_pack.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// One load of the installed language resources.
final class LocaleResourceCatalogLoadResult {
  const LocaleResourceCatalogLoadResult({
    required this.packs,
    required this.directory,
    this.errors = const <String>[],
  });

  /// Installed resources in load order; a later document wins a repeated key.
  final List<LocaleResourcePack> packs;

  final Directory directory;

  /// Stable codes for documents that were present but unusable.
  final List<String> errors;
}

/// Loads the language resources installed in the client's data directory.
///
/// The client ships no compiled-in install: resources arrive as documents in
/// [localeResourcesDirectoryName] under the portable data root, exactly like the
/// appearance preset catalogue. Reading them is what makes an installed resource
/// change the rendered interface.
final class LocaleResourceCatalogService {
  const LocaleResourceCatalogService();

  static const String localeResourcesDirectoryName = 'locale-resources';

  Future<LocaleResourceCatalogLoadResult> loadCatalog(
    PortableDataRoot portableData,
  ) async {
    final directory = await localeResourcesDirectory(portableData);
    await portableData.withAppManagedWriter(
      () => directory.create(recursive: true),
    );

    final errors = <String>[];
    final packs = <LocaleResourcePack>[];
    if (!await directory.exists()) {
      return LocaleResourceCatalogLoadResult(
        packs: const <LocaleResourcePack>[],
        directory: directory,
        errors: const <String>[],
      );
    }

    final files = await directory
        .list()
        .where(
          (entity) => entity is File && p.extension(entity.path) == '.json',
        )
        .cast<File>()
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));

    for (var index = 0; index < files.length; index++) {
      final pack = decodeLocaleResourceDocument(
        await files[index].readAsString(),
      );
      if (pack == null) {
        errors.add('installed_language_invalid:$index');
        continue;
      }
      packs.add(pack);
    }

    return LocaleResourceCatalogLoadResult(
      packs: List<LocaleResourcePack>.unmodifiable(packs),
      directory: directory,
      errors: List<String>.unmodifiable(errors),
    );
  }

  Future<Directory> localeResourcesDirectory(
    PortableDataRoot portableData,
  ) async {
    final root = await portableData.clientDirectory();
    return Directory(p.join(root.path, localeResourcesDirectoryName));
  }
}
