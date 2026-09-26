import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';

import 'extension_ui_test_support.dart';

void main() {
  group('contribution declaration', () {
    test('a settings form decodes and mounts against served profiles', () {
      final document = extensionEpochDocument(
        registryEpoch: 7,
        servedProfiles: const <String>{'declarative-ui'},
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.endpoint-form',
            kind: 'settings',
            resourceRef: 'resource:vendor.example.endpoint',
            actionRef: 'action:vendor.example.save',
            fields: <Map<String, Object?>>[
              extensionFieldJson(
                id: 'endpoint',
                label: 'Endpoint',
                type: 'text',
                required: true,
              ),
              extensionFieldJson(
                id: 'key',
                label: 'API key',
                type: 'secret-ref',
              ),
            ],
          ),
        ],
      );

      final snapshot = ExtensionUiRegistrySnapshot.fromJson(document);
      expect(snapshot.registryEpoch, 7);
      expect(snapshot.servedProfiles, <String>{'declarative-ui'});
      final entry = snapshot.contributions.single;
      expect(entry.instanceId, 'instance-1');
      expect(entry.generation, 1);
      expect(entry.contribution.kind, ExtensionContributionKind.settings);
      expect(entry.contribution.fields, hasLength(2));
      expect(entry.contribution.fields.last.type, ExtensionFieldType.secretRef);

      final decisions = planExtensionUiMount(
        snapshot.contributions.map((entry) => entry.contribution),
        servedProfiles: snapshot.servedProfiles,
        availablePrimitives:
            ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      );
      expect(decisions.single.isMounted, isTrue);
    });

    test('a secret-ref field carrying a value is refused alone', () {
      final withSecret = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.bad-form',
          kind: 'settings',
          fields: <Map<String, Object?>>[
            extensionFieldJson(
              id: 'key',
              label: 'API key',
              type: 'secret-ref',
              value: 'placeholder-secret',
            ),
          ],
        ),
      );
      final refusal = withSecret.refusal();
      expect(refusal, isNotNull);
      expect(refusal!.code, 'ui_secret_inline_refused');
      expect(refusal.field, 'fields.value');

      final plain = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.plain-form',
          kind: 'settings',
        ),
      );
      final decisions = planExtensionUiMount(
        <ExtensionUiContribution>[withSecret, plain],
        servedProfiles: const <String>{'declarative-ui'},
        availablePrimitives:
            ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      );
      expect(
        decisions.first.blocked,
        ExtensionUiMountBlock.contributionInvalid,
      );
      expect(decisions.last.isMounted, isTrue);
    });

    test('a contribution has no place for code or unknown fields', () {
      expect(
        () => ExtensionUiContribution.fromJson(
          extensionDeclarationJson(id: 'vendor.example.sneaky', kind: 'command')
            ..['script'] = 'run()',
        ),
        throwsFormatException,
      );
      expect(
        () => ExtensionUiContribution.fromJson(
          extensionDeclarationJson(
            id: 'vendor.example.unknown-kind',
            kind: 'canvas',
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => ExtensionUiContribution.fromJson(
          extensionDeclarationJson(id: 'bareword', kind: 'command'),
        ).refusal(),
        returnsNormally,
      );
      expect(
        ExtensionUiContribution.fromJson(
          extensionDeclarationJson(id: 'bareword', kind: 'command'),
        ).refusal()?.field,
        'id',
      );
    });

    test('a metric panel names standardized metrics and nothing else', () {
      final panel = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.panel',
          kind: 'metric-panel',
          series: <Map<String, Object?>>[
            extensionSeriesJson(
              metric: 'licoup.tokens.input',
              label: 'Input tokens',
              unit: 'tokens',
            ),
          ],
        ),
      );
      expect(panel.refusal(), isNull);
      expect(extensionUiPrimitiveFor(panel.kind), DeclarativePrimitive.chart);

      final empty = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.panel',
          kind: 'metric-panel',
        ),
      );
      expect(empty.refusal()?.field, 'series');

      final unruly = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.panel',
          kind: 'metric-panel',
          series: <Map<String, Object?>>[
            extensionSeriesJson(
              metric: 'tokens',
              label: 'Input tokens',
              unit: 'tokens',
            ),
          ],
        ),
      );
      expect(unruly.refusal()?.field, 'series');

      final overreach = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.command',
          kind: 'command',
          series: <Map<String, Object?>>[
            extensionSeriesJson(
              metric: 'licoup.tokens.input',
              label: 'Input tokens',
              unit: 'tokens',
            ),
          ],
        ),
      );
      expect(overreach.refusal()?.field, 'series');
    });

    test('an unserved or unpublished profile blocks only its contribution', () {
      final needsProfile = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.pairing',
          kind: 'navigation',
          requiredProfile: 'agent-execution',
        ),
      );
      final needsFuture = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.future',
          kind: 'navigation',
          requiredProfile: 'future-profile',
        ),
      );
      final plain = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(id: 'vendor.example.local', kind: 'command'),
      );
      final decisions = planExtensionUiMount(
        <ExtensionUiContribution>[needsProfile, needsFuture, plain],
        servedProfiles: const <String>{'declarative-ui'},
        availablePrimitives:
            ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      );
      expect(decisions[0].blocked, ExtensionUiMountBlock.profileNotInstalled);
      expect(decisions[1].blocked, ExtensionUiMountBlock.profileUnpublished);
      expect(decisions[2].isMounted, isTrue);

      final served = planExtensionUiMount(
        <ExtensionUiContribution>[needsProfile, needsFuture, plain],
        servedProfiles: const <String>{'declarative-ui', 'agent-execution'},
        availablePrimitives:
            ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
      );
      expect(served[0].isMounted, isTrue);
      expect(served[1].blocked, ExtensionUiMountBlock.profileUnpublished);
    });

    test('a missing host primitive is a local unavailability', () {
      final form = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(id: 'vendor.example.form', kind: 'settings'),
      );
      final command = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(id: 'vendor.example.command', kind: 'command'),
      );
      final panel = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.panel',
          kind: 'metric-panel',
          series: <Map<String, Object?>>[
            extensionSeriesJson(
              metric: 'licoup.tokens.input',
              label: 'Input tokens',
              unit: 'tokens',
            ),
          ],
        ),
      );
      final decisions = planExtensionUiMount(
        <ExtensionUiContribution>[form, command, panel],
        servedProfiles: const <String>{'declarative-ui'},
        availablePrimitives: const <DeclarativePrimitive>{
          DeclarativePrimitive.form,
        },
      );
      expect(decisions[0].isMounted, isTrue);
      expect(decisions[1].blocked, ExtensionUiMountBlock.primitiveUnavailable);
      expect(decisions[2].blocked, ExtensionUiMountBlock.primitiveUnavailable);

      final resourceView = ExtensionUiContribution.fromJson(
        extensionDeclarationJson(
          id: 'vendor.example.view',
          kind: 'resource-view',
        ),
      );
      expect(extensionUiPrimitiveFor(resourceView.kind), isNull);
      expect(
        planExtensionUiMount(
          <ExtensionUiContribution>[resourceView],
          servedProfiles: const <String>{'declarative-ui'},
          availablePrimitives: const <DeclarativePrimitive>{
            DeclarativePrimitive.table,
          },
        ).single.blocked,
        ExtensionUiMountBlock.resourceFormatMissing,
        reason: 'resource views mount through their declared format renderer',
      );
    });
  });

  group('epoch document', () {
    test('refuses unknown document keys and an impossible epoch', () {
      expect(
        () => ExtensionUiRegistrySnapshot.fromJson(<String, Object?>{
          'registryEpoch': 1,
          'servedProfiles': <String>[],
          'contributions': <Map<String, Object?>>[],
          'instances': <String>[],
        }),
        throwsFormatException,
      );
      expect(
        () => ExtensionUiRegistrySnapshot.fromJson(<String, Object?>{
          'registryEpoch': 0,
          'servedProfiles': <String>[],
          'contributions': <Map<String, Object?>>[],
        }),
        throwsFormatException,
      );
      expect(
        () => ExtensionUiRegistrySnapshot.fromJson(<String, Object?>{
          'registryEpoch': 1,
          'servedProfiles': <String>[],
          'contributions': <Map<String, Object?>>[
            extensionContributionJson(id: 'vendor.example.c', kind: 'command')
              ..remove('generation'),
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
