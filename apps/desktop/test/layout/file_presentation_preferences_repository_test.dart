import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/file_presentation_preferences_repository.dart';
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
      layoutProfileId: LayoutProfileId.parse('dashboard'),
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
      repository.setLayoutProfile(LayoutProfileId.parse('atlas')),
      repository.setAppearancePreset('dark'),
      repository.setLocalePreference('zh'),
      repository.setReduceMotion(true),
      repository.setLoadingEffect('particles'),
    ]);

    final loaded = await repository.load();
    expect(loaded.preferences.layoutProfileId, LayoutProfileId.parse('atlas'));
    expect(loaded.preferences.appearancePresetId, 'dark');
    expect(loaded.preferences.localePreference, 'zh');
    expect(loaded.preferences.reduceMotion, isTrue);
    expect(loaded.preferences.loadingEffectId, 'particles');
  });

  test('canonical writes omit unknown runtime-only fields', () async {
    final file = await preferencesFile(portableData);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'layoutProfileId': 'dashboard',
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

    await repository.setLayoutProfile(LayoutProfileId.parse('atlas'));
    final decoded = jsonDecode(await file.readAsString()) as Map;

    expect(decoded.keys.toSet(), {
      'schemaVersion',
      'layoutProfileId',
      'appearancePresetId',
      'localePreference',
      'reduceMotion',
      'loadingEffectId',
    });
    expect(decoded['layoutProfileId'], 'atlas');
    expect(decoded['reduceMotion'], isFalse);
  });

  test('reduce motion persists and absent preference follows system', () async {
    final file = await preferencesFile(portableData);
    final document = fallback.toJson()..remove('reduceMotion');
    await file.writeAsString(jsonEncode(document));
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    expect((await repository.load()).preferences.reduceMotion, isFalse);

    await repository.setReduceMotion(true);
    final reopened = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    expect((await reopened.load()).preferences.reduceMotion, isTrue);
    await reopened.setReduceMotion(false);
    expect((await repository.load()).preferences.reduceMotion, isFalse);
  });

  test(
    'corrupt documents fail closed without resetting durable preferences',
    () async {
      final file = await preferencesFile(portableData);
      await file.writeAsString('{invalid');
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );

      await expectLater(
        repository.load(),
        throwsA(
          isA<PresentationPreferencesRepositoryException>().having(
            (error) => error.code,
            'code',
            PresentationPreferencesRepositoryErrorCode.readFailed,
          ),
        ),
      );
      expect(await file.readAsString(), '{invalid');
    },
  );

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

  test('legacy layout ids upgrade on load and round-trip on save', () async {
    final file = await preferencesFile(portableData);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'layoutProfileId': 'messaging',
        'appearancePresetId': 'default-system',
        'localePreference': 'system',
      }),
    );
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );

    final legacy = await repository.load();
    expect(
      legacy.preferences.layoutProfileId,
      LayoutProfileId.parse('dashboard'),
      reason: 'retired Default/messaging id resolves to the renamed profile',
    );

    // The migrated choice round-trips: the next save persists the canonical
    // id and a later load reads it back unchanged.
    final saved = await repository.setLayoutProfile(
      LayoutProfileId.parse('dashboard'),
    );
    expect(saved.layoutProfileId, LayoutProfileId.parse('dashboard'));
    final decoded = jsonDecode(await file.readAsString()) as Map;
    expect(decoded['layoutProfileId'], 'dashboard');

    final reloaded = await repository.load();
    expect(
      reloaded.preferences.layoutProfileId,
      LayoutProfileId.parse('dashboard'),
    );
  });

  test('canonical dashboard and unknown ids load without remapping', () async {
    for (final id in ['dashboard', 'desktop', 'atlas']) {
      final file = await preferencesFile(portableData);
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'layoutProfileId': id,
          'appearancePresetId': 'default-system',
          'localePreference': 'system',
        }),
      );
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      final loaded = await repository.load();
      expect(loaded.preferences.layoutProfileId, LayoutProfileId.parse(id));
      await file.delete();
    }
  });

  test(
    'write failure is bounded, cleans temp, and preserves destination',
    () async {
      final initial = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      await initial.setLayoutProfile(LayoutProfileId.parse('dashboard'));
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
        await repository.setLayoutProfile(LayoutProfileId.parse('atlas'));
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<PresentationPreferencesRepositoryException>());
      expect('$failure', isNot(contains('sensitive-location')));
      expect(await attemptedTemporary!.exists(), isFalse);
      expect(
        (await initial.load()).preferences.layoutProfileId,
        LayoutProfileId.parse('dashboard'),
      );
    },
  );

  test(
    'a resource request survives restart without an availability claim',
    () async {
      final file = await preferencesFile(portableData);
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );

      await repository.setResourceSelection(
        PresentationResourceKind.theme,
        PresentationResourceSelection(
          resourceId: 'org.example.orbital',
          packageId: 'org.example.orbital-package',
          packageGeneration: 3,
        ),
      );

      final decoded = jsonDecode(await file.readAsString()) as Map;
      expect(decoded['resourceSelections'], {
        'theme': {
          'resourceId': 'org.example.orbital',
          'packageId': 'org.example.orbital-package',
          'packageGeneration': 3,
        },
      });

      // A restart reads the request back with the identity, the package and the
      // generation it was written with. Nothing in the document answers whether
      // the resource is served: that is the package owner's fact.
      final restarted = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      final loaded = await restarted.load();
      final request = loaded.preferences.resourceSelection(
        PresentationResourceKind.theme,
      );
      expect(request, isNotNull);
      expect(request!.resourceId, 'org.example.orbital');
      expect(request.packageId, 'org.example.orbital-package');
      expect(request.packageGeneration, 3);
      expect(loaded.preferences.resourceSelections.keys, ['theme']);
    },
  );

  test('an unrelated write keeps the recorded resource requests', () async {
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    await repository.setResourceSelection(
      PresentationResourceKind.font,
      PresentationResourceSelection(
        resourceId: 'org.example.mono',
        packageId: 'org.example.fonts',
      ),
    );

    await repository.setReduceMotion(true);

    final reloaded = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    final loaded = await reloaded.load();
    expect(loaded.preferences.reduceMotion, isTrue);
    expect(
      loaded.preferences
          .resourceSelection(PresentationResourceKind.font)
          ?.resourceId,
      'org.example.mono',
    );
  });

  test(
    'clearing a request records the declared default and leaves no entry',
    () async {
      final file = await preferencesFile(portableData);
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );
      await repository.setResourceSelection(
        PresentationResourceKind.language,
        PresentationResourceSelection(resourceId: 'org.example.french'),
      );

      await repository.setResourceSelection(
        PresentationResourceKind.language,
        null,
      );

      final decoded = jsonDecode(await file.readAsString()) as Map;
      expect(decoded.containsKey('resourceSelections'), isFalse);
      expect((await repository.load()).preferences.resourceSelections, isEmpty);
    },
  );

  test(
    'a kind this build does not know keeps the identity it was written with',
    () async {
      final file = await preferencesFile(portableData);
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'layoutProfileId': 'dashboard',
          'appearancePresetId': 'default-system',
          'localePreference': 'system',
          'resourceSelections': {
            'orbital-behavior': {
              'resourceId': 'org.example.behavior',
              'packageGeneration': 7,
            },
          },
        }),
      );
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );

      await repository.setLayoutProfile(LayoutProfileId.parse('atlas'));

      final decoded = jsonDecode(await file.readAsString()) as Map;
      expect(decoded['resourceSelections'], {
        'orbital-behavior': {
          'resourceId': 'org.example.behavior',
          'packageGeneration': 7,
        },
      });
      expect(decoded['layoutProfileId'], 'atlas');
    },
  );

  test(
    'an unreadable resource request refuses the document without rewriting it',
    () async {
      final file = await preferencesFile(portableData);
      final stored = jsonEncode({
        'schemaVersion': 1,
        'layoutProfileId': 'dashboard',
        'appearancePresetId': 'default-system',
        'localePreference': 'system',
        'resourceSelections': {
          'theme': {'resourceId': ''},
        },
      });
      await file.writeAsString(stored);
      final repository = FilePresentationPreferencesRepository(
        portableData: portableData,
        fallback: fallback,
      );

      await expectLater(
        repository.load(),
        throwsA(
          isA<PresentationPreferencesRepositoryException>().having(
            (error) => error.code,
            'code',
            PresentationPreferencesRepositoryErrorCode.readFailed,
          ),
        ),
      );
      expect(await file.readAsString(), stored);
    },
  );
}

Future<File> preferencesFile(PortableDataRoot portableData) async {
  final root = await portableData.clientDirectory();
  return File(p.join(root.path, 'appearance-preferences.json'));
}
