import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'extension_ui_test_support.dart';

void main() {
  test('a resource value snapshots its inputs into unmodifiable views', () {
    final formValues = <String, String>{'endpoint': 'https://local'};
    final fieldOptions = <String, List<String>>{
      'mode': <String>['fast'],
    };
    final series = <String, List<double>>{
      'licoup.tokens.input': <double>[1, 2],
    };
    final value = ExtensionUiResourceValue(
      formValues: formValues,
      fieldOptions: fieldOptions,
      series: series,
    );

    formValues['endpoint'] = 'https://mutated';
    fieldOptions['mode']!.add('slow');
    series['licoup.tokens.input']!.add(3);

    expect(value.formValues['endpoint'], 'https://local');
    expect(value.fieldOptions['mode'], <String>['fast']);
    expect(value.series['licoup.tokens.input'], <double>[1, 2]);
    expect(
      () => value.formValues['endpoint'] = 'https://mutated',
      throwsUnsupportedError,
    );
    expect(
      () => value.fieldOptions['mode']!.add('slow'),
      throwsUnsupportedError,
    );
    expect(
      () => value.series['licoup.tokens.input']!.add(3),
      throwsUnsupportedError,
    );
  });

  testWidgets('mutating an admitted input cannot change the visible value',
      (tester) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final field = syntheticExtensionField('immutable-resource');
    final formValues = <String, String>{'endpoint': 'https://local'};
    final series = <String, List<double>>{
      'licoup.tokens.input': <double>[7],
    };
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: formValues,
        series: series,
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.immutable',
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
          registryEpoch: 1,
          contributions: <Map<String, Object?>>[
            extensionContributionJson(
              id: 'vendor.example.form',
              kind: 'settings',
              title: 'Endpoint',
              resourceRef: 'resource:test.immutable',
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExtensionUiHost(registry: registry)),
      ),
    );
    await tester.pumpAndSettle();

    final session = registry.mounted.single;
    final admitted = session.displayed.value;
    expect(admitted?.formValues['endpoint'], 'https://local');
    expect(admitted?.series['licoup.tokens.input'], <double>[7]);

    formValues['endpoint'] = 'https://mutated';
    series['licoup.tokens.input']!.add(8);
    await tester.pumpAndSettle();

    expect(identical(session.displayed.value, admitted), isTrue);
    expect(session.displayed.value?.formValues['endpoint'], 'https://local');
    expect(
      session.displayed.value?.series['licoup.tokens.input'],
      <double>[7],
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('extension-field-vendor.example.form-endpoint')),
          )
          .controller
          ?.text,
      'https://local',
    );
  });

  test('mutating the maps passed to dispatch cannot change the invocation',
      () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
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
          registryEpoch: 2,
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
    await pumpEventQueue();
    final session = registry.mounted.single;

    final values = <String, String>{'endpoint': 'https://local'};
    final credentialRefs = <String, String>{'key': 'credential:fixture-1'};
    await Future<void>.value(
      session.dispatch(values: values, credentialRefs: credentialRefs),
    );
    values['endpoint'] = 'https://mutated';
    credentialRefs['key'] = 'credential:mutated';

    final invocation = actions.invocations.single;
    expect(invocation.values['endpoint'], 'https://local');
    expect(invocation.credentialRefs['key'], 'credential:fixture-1');
    expect(
      () => invocation.values['endpoint'] = 'https://mutated',
      throwsUnsupportedError,
    );
    expect(
      () => invocation.credentialRefs['key'] = 'credential:mutated',
      throwsUnsupportedError,
    );
  });
}
