import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/extensions/extension_ui_catalog_port.dart';
import 'package:licoup/src/composition/extensions/extension_ui_composition.dart';

import 'extension_ui_test_support.dart';

void main() {
  testWidgets(
    'the composition follows committed epochs from the catalog port',
    (tester) async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final port = ExtensionUiCatalogDocumentPort();
      addTearDown(port.dispose);
      final composition = ExtensionUiComposition(runtime: runtime);
      addTearDown(composition.dispose);

      final field = syntheticExtensionField('composition-resource');
      final source = SyntheticExtensionResourceSource(
        fieldGroup: field,
        initial: ExtensionUiResourceValue(
          formValues: <String, String>{'endpoint': 'https://local'},
        ),
      );
      composition.bindings.registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.composition',
          source: source,
        ),
      );

      composition.attachCatalog(port);
      port.publishDocument(
        extensionEpochDocument(
          registryEpoch: 1,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.composition',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'endpoint',
                  label: 'Endpoint',
                  type: 'text',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pump();

      expect(composition.registry.registryEpoch, 1);
      expect(composition.registry.mounted, hasLength(1));
      expect(source.openCount, 1);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: composition.buildHost())),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('extension-settings-vendor.example.form')),
        findsOneWidget,
      );

      port.publishDocument(
        extensionEpochDocument(
          registryEpoch: 2,
          contributions: <Map<String, Object?>>[],
        ),
      );
      await tester.pumpAndSettle();
      expect(composition.registry.mounted, isEmpty);
      expect(
        find.byKey(const Key('extension-settings-vendor.example.form')),
        findsNothing,
      );
      expect(source.closeCount, 1);
    },
  );

  testWidgets('attachCatalog reads the current epoch without losing a commit', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final port = ExtensionUiCatalogDocumentPort();
    addTearDown(port.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);

    port.publishDocument(
      extensionEpochDocument(
        registryEpoch: 3,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.command',
            kind: 'command',
          ),
        ],
      ),
    );
    composition.attachCatalog(port);
    await tester.pump();

    expect(composition.registry.registryEpoch, 3);
    expect(composition.registry.mounted, hasLength(1));
  });

  testWidgets(
    'mountDocument mounts one epoch directly and withdraw releases it',
    (tester) async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final composition = ExtensionUiComposition(runtime: runtime);
      addTearDown(composition.dispose);

      composition.mountDocument(
        extensionEpochDocument(
          registryEpoch: 4,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
            ),
          ],
        ),
      );
      expect(composition.registry.mounted, hasLength(1));

      composition.withdraw();
      expect(composition.registry.mounted, isEmpty);
      expect(composition.registry.registryEpoch, 0);
    },
  );

  testWidgets('disposing the composition stops following the catalog', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final port = ExtensionUiCatalogDocumentPort();
    addTearDown(port.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    composition.attachCatalog(port);
    composition.mountDocument(
      extensionEpochDocument(
        registryEpoch: 5,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.command',
            kind: 'command',
          ),
        ],
      ),
    );
    expect(port.hasListeners, isTrue);
    expect(composition.registry.mounted, hasLength(1));

    await composition.dispose();
    expect(port.hasListeners, isFalse);
    port.publishDocument(
      extensionEpochDocument(
        registryEpoch: 6,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.command',
            kind: 'command',
          ),
        ],
      ),
    );
    expect(composition.registry.mounted, isEmpty);
  });

  testWidgets('a malformed epoch document is refused before it can mount', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);

    expect(
      () => composition.mountDocument(<String, Object?>{
        'registryEpoch': 1,
        'servedProfiles': <String>[],
        'contributions': <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.command',
            kind: 'command',
          )..['handler'] = 'code',
        ],
      }),
      throwsFormatException,
    );
    expect(composition.registry.mounted, isEmpty);
  });
}
