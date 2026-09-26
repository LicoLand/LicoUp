import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'registered_feature_migration_list.dart';

/// Verifies the V7-F6 migration list against the repository on disk.
///
/// The point of these checks is that the list cannot silently omit one of the
/// 13 registered bindings, cannot claim a file that does not exist, and cannot
/// hide unowned remainder work behind prose: every path is resolved, every
/// wiring claim is matched against the composition source, and every remainder
/// names its owner and concrete files.
void main() {
  test('the list covers exactly the binding files on disk', () {
    final discovered = _bindingFilesOnDisk();
    final recorded = <String, String>{
      for (final record in registeredFeatureMigrations)
        record.feature: record.binding,
    };

    expect(
      discovered.keys.toSet(),
      recorded.keys.toSet(),
      reason: 'every presentation binding must be listed, none invented',
    );
    expect(recorded, hasLength(13));
    for (final feature in discovered.keys) {
      expect(
        recorded[feature],
        discovered[feature],
        reason: '$feature binding path must match the file on disk',
      );
    }
  });

  test('every recorded path, adapter and wiring claim is real', () {
    final compositionRoot = File(
      'lib/src/composition/client_app_composition.dart',
    ).readAsStringSync();
    final rootOverrides = _rootOverrideBody(compositionRoot);

    for (final record in registeredFeatureMigrations) {
      final reason = record.feature;
      expect(File(record.binding).existsSync(), isTrue, reason: '${reason}B');
      expect(File(record.composition).existsSync(), isTrue, reason: reason);
      for (final producer in record.projectionProducers) {
        expect(File(producer).existsSync(), isTrue, reason: producer);
      }
      for (final source in record.presentationSources) {
        expect(File(source).existsSync(), isTrue, reason: source);
      }
      for (final test in record.behaviorTests) {
        expect(File(test).existsSync(), isTrue, reason: test);
      }

      // The conversation row is owned by the parallel V7-F5 task, so its
      // adapter set is expected to move; every other projections directory is
      // frozen against this list.
      if (record.uiConsumption != FeatureUiConsumption.inFlight) {
        expect(
          _adapterFilesOnDisk(record.feature),
          record.presentationSources.toSet(),
          reason: '$reason adapter files must match the projections directory',
        );
      }

      final composition = File(record.composition).readAsStringSync();
      // This temporary migration inventory checks the exposed override seam,
      // not whether equivalent production code uses a field or a getter.
      final hasOverrides = RegExp(
        r'providerOverrides\s*(?:=|=>)\s*<Override>\s*\[',
      ).hasMatch(composition);
      final hasEntry = composition.contains('presentationProviderEntry(');
      switch (record.wiring) {
        case FeatureSourceWiring.providerOverrides:
          expect(
            hasOverrides,
            isTrue,
            reason: '$reason must expose provider overrides',
          );
          expect(
            hasEntry,
            isFalse,
            reason: '$reason must not mix entries with overrides',
          );
        case FeatureSourceWiring.providerEntry:
          // A successor integration may upgrade an entry to root overrides;
          // it may never leave the feature without a runtime port.
          expect(
            hasEntry || hasOverrides,
            isTrue,
            reason: '$reason must expose an entry or overrides',
          );
        case FeatureSourceWiring.none:
          if (record.uiConsumption == FeatureUiConsumption.inFlight) break;
          expect(hasEntry, isFalse, reason: '$reason has no runtime entry');
          expect(
            hasOverrides,
            isFalse,
            reason: '$reason has no runtime overrides',
          );
      }
    }

    final aggregated = <String>[
      for (final match in RegExp(
        r'\._(\w+)\.providerOverrides',
      ).allMatches(rootOverrides))
        match.group(1)!,
    ];
    expect(
      aggregated,
      containsAll(<String>[
        'settings',
        'pluginManagement',
        'skillHub',
        'mobileRelay',
      ]),
      reason: 'the root keeps installing the override features',
    );
    final featureByFlatName = <String, RegisteredFeatureMigration>{
      for (final record in registeredFeatureMigrations)
        _flatten(record.feature): record,
    };
    for (final name in aggregated) {
      final record = featureByFlatName[_flatten(name)];
      expect(
        record,
        isNotNull,
        reason: 'aggregated feature $name must be in the migration list',
      );
      expect(
        record!.wiring,
        isNot(FeatureSourceWiring.none),
        reason: 'only runtime-capable features may be installed at the root',
      );
    }
  });

  test('each feature UI claim matches the view sources', () {
    for (final record in registeredFeatureMigrations) {
      for (final path in record.uiDirectories) {
        expect(
          FileSystemEntity.isDirectorySync(path) ||
              FileSystemEntity.isFileSync(path),
          isTrue,
          reason: '${record.feature} UI path $path must exist',
        );
      }
      if (record.legacyRetired) {
        expect(
          _readsLegacyProjection(record.uiDirectories),
          isFalse,
          reason:
              '${record.feature} claims the legacy projection is retired but '
              'a view still reads it',
        );
      }
      switch (record.uiConsumption) {
        case FeatureUiConsumption.inFlight:
          continue;
        case FeatureUiConsumption.rendererPort:
          final files = _dartFiles(record.uiDirectories);
          expect(files, isNotEmpty, reason: record.feature);
          expect(
            files.any(
              (file) => file.readAsStringSync().contains('widget.renderer'),
            ),
            isTrue,
            reason: '${record.feature} must reach views through the renderer',
          );
          continue;
        case FeatureUiConsumption.narrowInputs:
        case FeatureUiConsumption.legacyProjection:
        case FeatureUiConsumption.mixed:
        case FeatureUiConsumption.none:
          expect(
            _deriveUiConsumption(record.uiDirectories),
            record.uiConsumption,
            reason: '${record.feature} UI consumption changed',
          );
      }
    }
  });

  test('unfinished features name concrete files and owners', () {
    for (final record in registeredFeatureMigrations) {
      if (!record.legacyRetired) {
        expect(
          record.remainders,
          isNotEmpty,
          reason: '${record.feature} cannot retire silently',
        );
      }
      for (final remainder in record.remainders) {
        expect(remainder.owner, isNotEmpty);
        expect(remainder.reason, isNotEmpty);
        expect(
          remainder.files.isNotEmpty || remainder.filesToCreate.isNotEmpty,
          isTrue,
          reason: '${record.feature} remainder must name files',
        );
        for (final file in remainder.files) {
          expect(File(file).existsSync(), isTrue, reason: file);
        }
        for (final file in remainder.filesToCreate) {
          expect(
            File(file).existsSync(),
            isFalse,
            reason: '$file already exists; the list is stale',
          );
        }
      }
    }
  });
}

Map<String, String> _bindingFilesOnDisk() {
  final presentation = Directory('lib/src/presentation');
  final bindings = <String, String>{};
  for (final entry in presentation.listSync().whereType<Directory>()) {
    final feature = entry.path.split(Platform.pathSeparator).last;
    final binding = File(
      '${entry.path}${Platform.pathSeparator}${feature}_binding.dart',
    );
    if (binding.existsSync()) {
      bindings[feature] = _normalize(binding.path);
    }
  }
  return bindings;
}

Set<String> _adapterFilesOnDisk(String feature) {
  final directory = Directory('lib/src/projections/$feature');
  if (!directory.existsSync()) return <String>{};
  final pattern = RegExp(r'(presentation|projection)_sources?\.dart$');
  return <String>{
    for (final file in directory.listSync().whereType<File>())
      if (pattern.hasMatch(file.path)) _normalize(file.path),
  };
}

String _rootOverrideBody(String compositionRoot) {
  final start = compositionRoot.indexOf(
    'List<Override> get presentationOverrides',
  );
  expect(start, isNonNegative, reason: 'root override getter must exist');
  final end = compositionRoot.indexOf('];', start);
  expect(end, isNonNegative, reason: 'root override getter must be closed');
  return compositionRoot.substring(start, end);
}

List<File> _dartFiles(List<String> paths) {
  final files = <File>[];
  for (final path in paths) {
    final entity = FileSystemEntity.isDirectorySync(path)
        ? Directory(path)
        : File(path);
    if (entity is Directory) {
      files.addAll(
        entity
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
      );
    } else {
      files.add(entity as File);
    }
  }
  return files;
}

bool _readsLegacyProjection(List<String> paths) {
  for (final file in _dartFiles(paths)) {
    final source = file.readAsStringSync();
    if (source.contains('binding.projection') ||
        source.contains('.projection.current')) {
      return true;
    }
  }
  return false;
}

FeatureUiConsumption _deriveUiConsumption(List<String> paths) {
  var narrow = false;
  var legacy = false;
  for (final file in _dartFiles(paths)) {
    final source = file.readAsStringSync();
    narrow = narrow || source.contains('AsyncRegion<');
    legacy = legacy || source.contains('ProjectionBuilder<');
  }
  if (narrow && legacy) return FeatureUiConsumption.mixed;
  if (narrow) return FeatureUiConsumption.narrowInputs;
  if (legacy) return FeatureUiConsumption.legacyProjection;
  return FeatureUiConsumption.none;
}

String _normalize(String path) => path.replaceAll(r'\', '/');

String _flatten(String name) => name.replaceAll('_', '').toLowerCase();
