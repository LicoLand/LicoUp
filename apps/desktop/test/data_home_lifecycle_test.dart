import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/data_home_executor.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  for (final failAfterDrain in [false, true]) {
    test(
      'settings relocation drains accepted root writes before helper and rebuilds; '
      'failure=$failAfterDrain',
      () async {
        final parent = await Directory.systemTemp.createTemp(
          'data-home-lifecycle-',
        );
        final source = Directory('${parent.path}/source');
        final targetParent = Directory('${parent.path}/target-parent');
        await source.create();
        await targetParent.create();

        final writeStarted = Completer<void>();
        final releaseWrite = Completer<void>();
        final sourceRoot = PortableDataRoot(dataDirectoryOverride: source);
        final preferences = FilePresentationPreferencesRepository(
          portableData: sourceRoot,
          fallback: PresentationPreferences(
            layoutProfileId: LayoutProfileId.parse('desktop'),
            appearancePresetId: AppearancePresetIds.defaultSystem,
            localePreference: 'system',
          ),
          beforeReplace: (_, _) async {
            if (!writeStarted.isCompleted) writeStarted.complete();
            await releaseWrite.future;
          },
        );

        var selectedRoot = source;
        final roots = <PortableDataRoot>[];
        final agents = <_RelocationAgentService>[];
        ClientAppComposition createComposition() {
          final root = roots.isEmpty
              ? sourceRoot
              : PortableDataRoot(dataDirectoryOverride: selectedRoot);
          roots.add(root);
          final agent = _RelocationAgentService(
            source: source,
            failAfterDrain: failAfterDrain,
            onPublished: (destination) => selectedRoot = destination,
          );
          agents.add(agent);
          return ClientAppComposition(
            controller: ClientController(
              portableData: root,
              agentService: agent,
            ),
          );
        }

        final composition = createComposition();
        final relocationDone = Completer<void>();
        Object? relocationFailure;
        final effects = composition.settings.effects.effects.listen((effect) {
          if (effect is! DataHomeRelocationRequested) return;
          unawaited(() async {
            try {
              await composition.relocateDataHome(effect.destinationParent);
            } on Object catch (error) {
              relocationFailure = error;
            } finally {
              relocationDone.complete();
            }
          }());
        });
        addTearDown(() async {
          if (!releaseWrite.isCompleted) releaseWrite.complete();
          await effects.cancel();
          await composition.dispose();
          if (roots.length > 1) {
            await roots.last.stopAppManagedWritersAndDrain();
          }
          await parent.delete(recursive: true);
        });

        final acceptedWrite = preferences.setAppearancePreset('fixture-preset');
        await writeStarted.future;

        composition.settings.intents.send(RelocateDataHome(targetParent.path));
        final lateWrite = preferences.setLocalePreference('en');
        await expectLater(lateWrite, throwsA(isA<StateError>()));
        expect(agents.single.relocationStarted.isCompleted, isFalse);

        releaseWrite.complete();
        await acceptedWrite;
        await relocationDone.future;

        final destination = Directory('${targetParent.path}/LicoUp');
        final preferencePath =
            '${destination.path}/client-state/appearance-preferences.json';
        if (failAfterDrain) {
          expect(relocationFailure, isA<LicoClientRpcException>());
          expect(agents.single.failureThrown, isTrue);
          expect(selectedRoot.path, source.path);
          expect(await File(preferencePath).exists(), isFalse);
          expect(
            await File(
              '${source.path}/client-state/appearance-preferences.json',
            ).readAsString(),
            contains('fixture-preset'),
          );
        } else {
          expect(relocationFailure, isNull);
          expect(agents.single.failureThrown, isFalse);
          expect(selectedRoot.path, destination.path);
          expect(
            jsonDecode(
              await File(preferencePath).readAsString(),
            )['appearancePresetId'],
            'fixture-preset',
          );
        }

        final rebuilt = createComposition();
        expect((await roots.last.dataDirectory()).path, selectedRoot.path);
        expect(rebuilt.initialized, isFalse);
        await rebuilt.dispose();
      },
    );
  }
}

final class _RelocationAgentService extends FakeAgentService {
  _RelocationAgentService({
    required this.source,
    required this.failAfterDrain,
    required this.onPublished,
  });

  final Directory source;
  final bool failAfterDrain;
  final void Function(Directory destination) onPublished;
  final Completer<void> relocationStarted = Completer<void>();
  var failureThrown = false;

  @override
  Future<Map<String, dynamic>> relocateDataHome(
    String destinationParent, {
    DataHomePhaseHandler? onPhase,
  }) async {
    relocationStarted.complete();
    if (failAfterDrain) {
      failureThrown = true;
      throw const LicoClientRpcException('data_home_destination_exists');
    }
    final destination = Directory('$destinationParent/LicoUp');
    await destination.create(recursive: true);
    await Directory('${destination.path}/client-state').create();
    await File(
      '${source.path}/client-state/appearance-preferences.json',
    ).copy('${destination.path}/client-state/appearance-preferences.json');
    onPublished(destination);
    return <String, dynamic>{'status': 'relocated'};
  }
}
