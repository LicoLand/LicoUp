import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'extension_ui_test_support.dart';

void main() {
  late PresentationRuntime runtime;

  setUp(() {
    runtime = PresentationRuntime();
  });

  tearDown(() {
    runtime.dispose();
  });

  testWidgets('a missing credential port refuses only the secret operation',
      (tester) async {
    final field = syntheticExtensionField('credential-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.credential',
          source: source,
        ),
      );
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.save', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 1,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.credential',
              actionRef: 'action:test.save',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'endpoint',
                  label: 'Endpoint',
                  type: 'text',
                ),
                extensionFieldJson(
                  id: 'key',
                  label: 'API key',
                  type: 'secret-ref',
                  required: true,
                ),
              ],
            ),
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
              title: 'Run synthetic job',
              actionRef: 'action:test.save',
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    final session = registry.mounted.first;
    expect(session.canStoreCredentials, isFalse);
    final secretField = find.byKey(
      const Key('extension-field-vendor.example.form-key'),
    );
    expect(
      tester.widget<TextField>(secretField).enabled,
      isFalse,
      reason: 'the display layer never takes custody of a secret itself',
    );
    expect(find.text('Credential host unavailable'), findsOneWidget);

    // A required secret field keeps the form from submitting.
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pumpAndSettle();
    expect(actions.invocations, isEmpty);
    expect(find.text('required'), findsOneWidget);

    // A control that already holds a value is refused with the credential
    // reason, and still nothing is dispatched.
    tester.widget<TextField>(secretField).controller!.text =
        'local-synthetic-secret';
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pumpAndSettle();
    expect(actions.invocations, isEmpty);
    expect(find.text('credential_unavailable'), findsOneWidget);

    // A contribution without secrets is unaffected.
    await tester.tap(
      find.byKey(const Key('extension-command-vendor.example.command')),
    );
    await tester.pumpAndSettle();
    expect(actions.invocations, hasLength(1));
  });

  testWidgets('a refused host credential dispatches nothing and keeps the input',
      (tester) async {
    final field = syntheticExtensionField('refused-resource');
    final source = SyntheticExtensionResourceSource(fieldGroup: field);
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.refused',
          source: source,
        ),
      );
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.save', actions);
    final credentials = FixtureExtensionCredentialPort()..fail = true;
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
      credentialPort: credentials,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 2,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.refused',
              actionRef: 'action:test.save',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'key',
                  label: 'API key',
                  type: 'secret-ref',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    final secretField = find.byKey(
      const Key('extension-field-vendor.example.form-key'),
    );
    await tester.enterText(secretField, 'local-synthetic-secret');
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pumpAndSettle();

    expect(credentials.requests, hasLength(1));
    expect(actions.invocations, isEmpty);
    expect(find.text('credential_failed'), findsOneWidget);
    expect(
      tester.widget<TextField>(secretField).controller?.text,
      'local-synthetic-secret',
      reason: 'a failed custody keeps the input so the user can retry',
    );
  });

  testWidgets('a stored credential passes only the handle and clears the input',
      (tester) async {
    final field = syntheticExtensionField('stored-resource');
    final source = SyntheticExtensionResourceSource(fieldGroup: field);
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.stored',
          source: source,
        ),
      );
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.save', actions);
    final credentials = FixtureExtensionCredentialPort();
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
      credentialPort: credentials,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 3,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.stored',
              actionRef: 'action:test.save',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'key',
                  label: 'API key',
                  type: 'secret-ref',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    final secretField = find.byKey(
      const Key('extension-field-vendor.example.form-key'),
    );
    await tester.enterText(secretField, 'local-synthetic-secret');
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pumpAndSettle();

    final invocation = actions.invocations.single;
    final handle = invocation.credentialRefs['key'];
    expect(handle, startsWith('credential:fixture-'));
    expect(invocation.values.containsKey('key'), isFalse);
    expect(credentials.secretFor(handle!), 'local-synthetic-secret');
    expect(
      tester.widget<TextField>(secretField).controller?.text,
      isEmpty,
      reason: 'the control releases the secret once the host holds it',
    );
  });

  testWidgets('withdrawing while custody is pending dispatches no stale action',
      (tester) async {
    final field = syntheticExtensionField('pending-resource');
    final source = SyntheticExtensionResourceSource(fieldGroup: field);
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.pending',
          source: source,
        ),
      );
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.save', actions);
    final gate = Completer<void>();
    final credentials = FixtureExtensionCredentialPort()..gate = gate;
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
      credentialPort: credentials,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 4,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.pending',
              actionRef: 'action:test.save',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'key',
                  label: 'API key',
                  type: 'secret-ref',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    await tester.enterText(
      find.byKey(const Key('extension-field-vendor.example.form-key')),
      'local-synthetic-secret',
    );
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pump();
    expect(credentials.requests, hasLength(1), reason: 'custody is pending');

    registry.withdraw();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('extension-settings-vendor.example.form')),
      findsNothing,
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(
      actions.invocations,
      isEmpty,
      reason: 'a withdrawn epoch never dispatches a stale action',
    );
  });
}

Future<void> _pumpHost(
  WidgetTester tester,
  ExtensionUiMountRegistry registry,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ExtensionUiHost(registry: registry)),
    ),
  );
  await tester.pumpAndSettle();
}
