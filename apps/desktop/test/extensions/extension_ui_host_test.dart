import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
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

  testWidgets('a settings form submits ordinary values and credential handles',
      (tester) async {
    final field = syntheticExtensionField('form-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{
          'endpoint': 'https://local',
          'enabled': 'true',
          'mode': 'fast',
        },
        fieldOptions: <String, List<String>>{
          'mode': <String>['fast', 'slow'],
        },
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.form',
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
          registryEpoch: 1,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.form',
              actionRef: 'action:test.save',
              fields: <Map<String, Object?>>[
                extensionFieldJson(
                  id: 'endpoint',
                  label: 'Endpoint',
                  type: 'text',
                  required: true,
                ),
                extensionFieldJson(
                  id: 'enabled',
                  label: 'Enabled',
                  type: 'boolean',
                ),
                extensionFieldJson(
                  id: 'mode',
                  label: 'Mode',
                  type: 'select',
                ),
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

    final endpointField = find.byKey(
      const Key('extension-field-vendor.example.form-endpoint'),
    );
    expect(tester.widget<TextField>(endpointField).controller?.text, 'https://local');

    await tester.enterText(endpointField, 'https://next');
    await tester.tap(
      find.byKey(const Key('extension-field-vendor.example.form-enabled')),
    );
    await tester.tap(
      find.byKey(const Key('extension-field-vendor.example.form-mode')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('slow').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('extension-field-vendor.example.form-key')),
      'local-synthetic-secret',
    );
    await tester.tap(
      find.byKey(const Key('extension-submit-vendor.example.form')),
    );
    await tester.pumpAndSettle();

    final invocation = actions.invocations.single;
    expect(invocation.values['endpoint'], 'https://next');
    expect(invocation.values['enabled'], 'false');
    expect(invocation.values['mode'], 'slow');
    final handle = invocation.credentialRefs['key'];
    expect(handle, isNotNull);
    expect(handle, startsWith('credential:fixture-'));
    expect(credentials.holds(handle!), isTrue);
    expect(credentials.secretFor(handle), 'local-synthetic-secret');
    final request = credentials.requests.single;
    expect(request.contributionId, 'vendor.example.form');
    expect(request.fieldId, 'key');
    expect(request.actionRef, 'action:test.save');
    expect(
      request.origin.scope,
      const ResourceScope('extension:vendor.example.form'),
      reason: 'the session pins the scope the host port verifies',
    );
    expect(request.origin.resource, field.resource);
    for (final value in <String>[
      ...invocation.values.values,
      ...invocation.credentialRefs.values,
    ]) {
      expect(
        value.contains('local-synthetic-secret'),
        isFalse,
        reason: 'a raw secret never crosses into the contribution',
      );
    }
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('extension-field-vendor.example.form-key')),
          )
          .controller
          ?.text,
      isEmpty,
      reason: 'the host control does not keep the secret after collecting it',
    );
  });

  testWidgets('a prepared update does not clobber local input state',
      (tester) async {
    final field = syntheticExtensionField('local-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.local',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 2,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.local',
              kind: 'settings',
              resourceRef: 'resource:test.local',
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
      ),
    );
    await _pumpHost(tester, registry);

    final endpointField = find.byKey(
      const Key('extension-field-vendor.example.local-endpoint'),
    );
    await tester.enterText(endpointField, 'https://typed');
    source.publish(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://server'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(endpointField).controller?.text,
      'https://typed',
      reason: 'typing is local input state until an explicit submit',
    );
  });

  testWidgets('a command contribution dispatches its action on tap',
      (tester) async {
    final bindings = ExtensionUiBindingRegistry();
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.run', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 3,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
              title: 'Run synthetic job',
              actionRef: 'action:test.run',
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    await tester.tap(
      find.byKey(const Key('extension-command-vendor.example.command')),
    );
    await tester.pumpAndSettle();

    expect(actions.invocations, hasLength(1));
    expect(actions.invocations.single.actionRef, 'action:test.run');
    expect(
      actions.invocations.single.origin.scope,
      const ResourceScope('extension:vendor.example.command'),
    );
  });

  testWidgets('a metric panel draws declared series with an accessible summary',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final field = syntheticExtensionField('panel-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        series: <String, List<double>>{
          'example.documents.processed': <double>[4, 12],
        },
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.panel',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 4,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.panel',
              kind: 'metric-panel',
              title: 'Processed documents',
              resourceRef: 'resource:test.panel',
              series: <Map<String, Object?>>[
                extensionSeriesJson(
                  metric: 'example.documents.processed',
                  label: 'Documents processed',
                  unit: 'item',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    expect(find.text('Processed documents'), findsOneWidget);
    expect(find.text('Documents processed: 12 item'), findsOneWidget);
    expect(
      find.byKey(
        const Key('extension-series-vendor.example.panel-example.documents.processed'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const Key('extension-chart-vendor.example.panel')),
          )
          .label,
      contains('Documents processed: 12 item'),
    );
    semantics.dispose();
  });

  testWidgets('an optional navigation entry appears only while its profile is '
      'served', (tester) async {
    final bindings = ExtensionUiBindingRegistry();
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.open', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 5,
          servedProfiles: const <String>{'declarative-ui'},
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.nav',
              kind: 'navigation',
              title: 'Collaboration',
              requiredProfile: 'agent-execution',
              actionRef: 'action:test.open',
            ),
          ],
        ),
      ),
    );
    await _pumpHost(tester, registry);

    expect(
      find.byKey(const Key('extension-navigation-vendor.example.nav')),
      findsNothing,
    );
    expect(registry.decisions.single.blocked, ExtensionUiMountBlock.profileNotInstalled);

    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 6,
          servedProfiles: const <String>{'declarative-ui', 'agent-execution'},
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.nav',
              kind: 'navigation',
              title: 'Collaboration',
              requiredProfile: 'agent-execution',
              actionRef: 'action:test.open',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(
      const Key('extension-navigation-vendor.example.nav'),
    );
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(actions.invocations.single.actionRef, 'action:test.open');
  });

  testWidgets('a host trust prompt is drawn above and cannot be covered by a '
      'contribution', (tester) async {
    final bindings = ExtensionUiBindingRegistry();
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.run', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 7,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
              title: 'Run synthetic job',
              actionRef: 'action:test.run',
            ),
          ],
        ),
      ),
    );

    var confirmed = false;
    await _pumpHost(
      tester,
      registry,
      trustPrompt: Material(
        type: MaterialType.transparency,
        child: ColoredBox(
          color: const Color(0xAA000000),
          child: Center(
            child: FilledButton(
              key: const Key('host-trust-confirm'),
              onPressed: () => confirmed = true,
              child: const Text('Allow'),
            ),
          ),
        ),
      ),
    );

    final command = find.byKey(
      const Key('extension-command-vendor.example.command'),
    );
    expect(command, findsOneWidget);
    await tester.tapAt(tester.getCenter(command));
    await tester.pumpAndSettle();

    expect(
      actions.invocations,
      isEmpty,
      reason: 'the host prompt layer received the tap, not the contribution',
    );
    expect(confirmed, isFalse);

    await tester.tap(find.byKey(const Key('host-trust-confirm')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('mounting an epoch does not rebuild unrelated surfaces',
      (tester) async {
    final bindings = ExtensionUiBindingRegistry();
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.run', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);
    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 8,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
              actionRef: 'action:test.run',
            ),
          ],
        ),
      ),
    );

    final siblingKey = GlobalKey<_BuildCounterState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              _BuildCounter(key: siblingKey, label: 'conversation'),
              ExtensionUiHost(registry: registry),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buildsBefore = siblingKey.currentState!.builds;

    registry.mount(
      ExtensionUiRegistrySnapshot.fromJson(
        extensionEpochDocument(
          registryEpoch: 9,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.command',
              kind: 'command',
              actionRef: 'action:test.run',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      siblingKey.currentState!.builds,
      buildsBefore,
      reason: 'an epoch mount only rebuilds the contribution host subtree',
    );
  });
}

Future<void> _pumpHost(
  WidgetTester tester,
  ExtensionUiMountRegistry registry, {
  Widget? trustPrompt,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ExtensionUiHost(registry: registry, hostTrustPrompt: trustPrompt),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _BuildCounter extends StatefulWidget {
  const _BuildCounter({super.key, required this.label});

  final String label;

  @override
  State<_BuildCounter> createState() => _BuildCounterState();
}

class _BuildCounterState extends State<_BuildCounter> {
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds += 1;
    return Text('${widget.label}:$builds');
  }
}
