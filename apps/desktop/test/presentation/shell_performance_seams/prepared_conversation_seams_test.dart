import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import '../../fixtures/client_controller/support/fake_agent_service.dart';
import 'support/measurement_preferences.dart';

/// Prepared conversation bodies are counted work, and presentation changes must
/// not repeat that work.
///
/// The measured seam is the composition-bound port: a view publishes the text it
/// holds, and the owner reports how often it prepared a body and what the
/// installed value contains. A restyle, a return to a mounted view, or a layout
/// change may rebuild widgets, but it must not re-parse the conversation and
/// must not drop the prepared body.
void main() {
  test(
    'restyles and layout changes preserve the prepared body and its session',
    () async {
      // The measurement owns its data root and its presentation preferences, so
      // it never reads and never writes the presentation preferences of the
      // machine it runs on.
      final dataRoot = Directory.systemTemp.createTempSync(
        'licoup-prepared-seams-',
      );
      addTearDown(() {
        if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
      });
      final controller = ClientController(
        agentService: FakeAgentService(),
        portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
        presentationPreferencesRepository: MeasurementPreferences(
          PresentationPreferences(
            layoutProfileId: LayoutProfileId.parse('dashboard'),
            appearancePresetId: AppearancePresetIds.licoSoda,
            localePreference: LocalePreference.english,
          ),
        ),
      );
      final composition = ClientAppComposition(controller: controller);
      await controller.layoutManager.initialize();
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      addTearDown(() async {
        container.dispose();
        await composition.dispose();
      });

      final port =
          container.read(conversationMarkdownPortProvider)
              as ConversationMarkdownPreparation;
      const text = '# Title\n\nbody **bold**\n\nsecond paragraph\n\n';
      port.publish(
        identity: 'measured-body',
        text: text,
        conversationId: 'measured-conversation',
      );
      final installed = await _waitForValue(port, 'measured-body');
      final preparedAttempts = port.preparationsFor('measured-body');
      expect(
        installed.blocks.map((block) => block.value.contentHash).toList(),
        parseMessageMarkdownBlocks(
          text,
        ).map((block) => block.contentHash).toList(),
        reason:
            'the prepared body carries exactly the parsed blocks of its text',
      );
      expect(
        port.positionFor('measured-body'),
        isNotNull,
        reason: 'the body keeps its source session position',
      );

      // A view that rebuilds republishes the text it still holds. That is not a
      // revision: it must not parse again or replace the installed value.
      port.publish(
        identity: 'measured-body',
        text: text,
        conversationId: 'measured-conversation',
      );
      await _settle();
      expect(
        port.preparationsFor('measured-body'),
        preparedAttempts,
        reason: 'a republished unchanged body is not prepared again',
      );
      expect(
        port.valueFor('measured-body'),
        same(installed),
        reason: 'the installed value is preserved for the unchanged revision',
      );

      // Presentation changes: the theme and the layout selection move, and the
      // prepared conversation body must be untouched by either.
      controller.appearancePreferenceOwner.replacePreset(
        AppearancePresetIds.licoSodaLight,
      );
      await controller.layoutManager.selectLayout(
        LayoutProfileId.parse('desktop'),
      );
      await _settle();
      expect(
        port.preparationsFor('measured-body'),
        preparedAttempts,
        reason: 'a restyle or layout change never re-parses a conversation',
      );
      expect(
        port.valueFor('measured-body'),
        same(installed),
        reason: 'the restyle preserved the installed prepared value',
      );
      expect(
        port.positionFor('measured-body'),
        isNotNull,
        reason: 'the restyle preserved the body session registration',
      );

      // A real revision is different work and is prepared again.
      port.publish(
        identity: 'measured-body',
        text: '${text}third paragraph\n\n',
        conversationId: 'measured-conversation',
      );
      final revised = await _waitForValue(
        port,
        'measured-body',
        differentFrom: installed,
      );
      expect(
        port.preparationsFor('measured-body'),
        greaterThan(preparedAttempts),
        reason: 'a text revision is prepared, so the count has to move',
      );
      expect(
        revised.blocks.length,
        greaterThan(installed.blocks.length),
        reason: 'the revised body parsed the appended block',
      );

      // The session linkage still retires the body it belongs to.
      port.retireConversation('measured-conversation');
      expect(
        port.stateFor('measured-body'),
        isA<ConversationMarkdownWithdrawn>(),
        reason: 'the body still belongs to the conversation it was read for',
      );
      expect(port.valueFor('measured-body'), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<PreparedValue<MessageMarkdownBlock>> _waitForValue(
  ConversationMarkdownPreparation preparation,
  String identity, {
  PreparedValue<MessageMarkdownBlock>? differentFrom,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = preparation.valueFor(identity);
    if (value != null && !identical(value, differentFrom)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final failure = preparation.failureFor(identity);
  fail(
    'no prepared value for $identity within ${timeout.inSeconds}s'
    '${failure == null ? '' : ' (failure: $failure)'}',
  );
}

Future<void> _settle() async {
  for (var turn = 0; turn < 4; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
