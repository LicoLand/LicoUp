import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryRoot;
  late PortableDataRoot portableData;
  late PresentationPreferences fallback;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'layout-preferences-test-',
    );
    portableData = PortableDataRoot(dataDirectoryOverride: temporaryRoot);
    fallback = PresentationPreferences(
      layoutProfileId: LayoutProfileId.parse('workbench'),
      appearancePresetId: 'default-system',
      localePreference: 'system',
    );
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('serialized concurrent field updates retain every mutation', () async {
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );

    await Future.wait([
      repository.setLayoutProfile(LayoutProfileId.parse('native')),
      repository.setAppearancePreset('dark'),
      repository.setLocalePreference('zh'),
    ]);

    final loaded = await repository.load();
    expect(loaded.preferences.layoutProfileId, LayoutProfileId.parse('native'));
    expect(loaded.preferences.appearancePresetId, 'dark');
    expect(loaded.preferences.localePreference, 'zh');
  });

  test('canonical writes omit unknown runtime-only fields', () async {
    final file = await preferencesFile(portableData);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'layoutProfileId': 'workbench',
        'appearancePresetId': 'default-system',
        'localePreference': 'system',
        'transientPanelId': 'runtime-only-value',
        'surface': 'desktop',
        'viewport': 'medium',
      }),
    );
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );

    await repository.setLayoutProfile(LayoutProfileId.parse('native'));
    final decoded = jsonDecode(await file.readAsString()) as Map;

    expect(decoded.keys.toSet(), {
      'schemaVersion',
      'layoutProfileId',
      'appearancePresetId',
      'localePreference',
    });
    expect(decoded['layoutProfileId'], 'native');
  });

  test('corrupt documents recover to fallback and converge on write', () async {
    final file = await preferencesFile(portableData);
    await file.writeAsString('{invalid');
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );

    final loaded = await repository.load();
    expect(loaded.recovered, isTrue);
    expect(loaded.issue, PresentationPreferencesLoadIssue.invalidDocument);
    expect(loaded.preferences, fallback);

    await repository.setLocalePreference('en');
    final converged = jsonDecode(await file.readAsString()) as Map;
    expect(converged['layoutProfileId'], 'workbench');
    expect(converged['localePreference'], 'en');
  });

  test(
    'replacement keeps old destination visible until flushed temp wins',
    () async {
      final initial = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      await initial.setAppearancePreset('light');

      final enteredReplace = Completer<(File, File)>();
      final allowReplace = Completer<void>();
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
        beforeReplace: (temporary, destination) async {
          enteredReplace.complete((temporary, destination));
          await allowReplace.future;
        },
      );

      final update = repository.setAppearancePreset('dark');
      final files = await enteredReplace.future;
      final oldDocument = jsonDecode(await files.$2.readAsString()) as Map;
      expect(oldDocument['appearancePresetId'], 'light');
      expect(await files.$1.exists(), isTrue);

      allowReplace.complete();
      await update;
      final newDocument = jsonDecode(await files.$2.readAsString()) as Map;
      expect(newDocument['appearancePresetId'], 'dark');
      expect(await files.$1.exists(), isFalse);
    },
  );

  test(
    'write failure is bounded, cleans temp, and preserves destination',
    () async {
      final initial = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      await initial.setLayoutProfile(LayoutProfileId.parse('workbench'));
      File? attemptedTemporary;
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
        beforeReplace: (temporary, _) async {
          attemptedTemporary = temporary;
          throw const FileSystemException('denied', 'sensitive-location');
        },
      );

      Object? failure;
      try {
        await repository.setLayoutProfile(LayoutProfileId.parse('native'));
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<PresentationPreferencesRepositoryException>());
      expect('$failure', isNot(contains('sensitive-location')));
      expect(await attemptedTemporary!.exists(), isFalse);
      expect(
        (await initial.load()).preferences.layoutProfileId,
        LayoutProfileId.parse('workbench'),
      );
    },
  );
}

Future<File> preferencesFile(PortableDataRoot portableData) async {
  final root = await portableData.clientDirectory();
  return File(p.join(root.path, 'appearance-preferences.json'));
}
