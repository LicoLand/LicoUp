import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

/// The published document a native host writes for one appearance package
/// generation, as this interface must read it.
Map<String, Object?> _publishedDocument({
  Map<String, Object?>? themeBinding,
  List<Map<String, Object?>> fallbacks = const [],
  List<Map<String, Object?>> contributions = const [],
}) => {
  'format': 'licoup.client.mount-plan.v1',
  'version': 1,
  'revision': 7,
  'servedProfiles': <String>[],
  'hostPrimitives': ['form', 'table', 'chart', 'progress', 'text', 'action'],
  'hostActions': <String>[],
  'bindings': [
    themeBinding ??
        {
          'kind': 'theme',
          'resourceId': 'org.licoland.theme.aurora',
          'packageId': 'org.licoland.appearance.synthetic',
          'packageGeneration': 3,
        },
    {'kind': 'layout', 'system': 'appearance'},
    {'kind': 'style', 'system': 'appearance'},
    {'kind': 'font', 'system': 'font'},
    {'kind': 'language', 'system': 'locale'},
    {'kind': 'composition', 'system': 'appearance'},
  ],
  'fallbacks': fallbacks,
  'contributions': contributions,
};

/// The host registration a shell builds from what it compiled.
HostPrimitiveRegistry _host({
  Set<DeclarativePrimitive> primitives = const {
    DeclarativePrimitive.text,
    DeclarativePrimitive.progress,
    DeclarativePrimitive.form,
    DeclarativePrimitive.table,
    DeclarativePrimitive.action,
    DeclarativePrimitive.command,
  },
  Set<String> actions = const {'org.licoland.action.apply-theme'},
  Map<String, String> defaults = const {'bg-base': '#101014', 'brand': '#88ff00'},
  Set<String> roles = const {'bg-base', 'brand', 'text-primary'},
}) => HostPrimitiveRegistry(
  primitives: primitives,
  actions: actions,
  appearanceDefaults: defaults,
  appearanceTokenRoles: roles,
);

Map<String, Object?> _themeText({
  String id = 'org.licoland.appearance.synthetic/theme',
  Map<String, Object?> inputs = const {'label': 'Aurora'},
}) => {
  'id': id,
  'primitive': 'text',
  'inputs': inputs,
  'resourceId': 'org.licoland.theme.aurora',
};

void main() {
  group('native mount plan document', () {
    test('round-trips a published document without changing its meaning', () {
      final document = _publishedDocument(
        contributions: [_themeText()],
        fallbacks: [
          {
            'kind': 'font',
            'resourceId': 'org.licoland.font.inter',
            'packageId': 'org.licoland.appearance.synthetic',
            'reason': 'disabled',
          },
        ],
      );

      final plan = NativeMountPlan.fromDecoded(document);

      expect(plan.revision, 7);
      expect(plan.contributions, hasLength(1));
      expect(plan.contributions.single.primitive, DeclarativePrimitive.text);
      expect(plan.themeTokens, isEmpty);
      expect(
        NativeMountPlan.fromDecoded(plan.toDecoded()).toDecoded(),
        plan.toDecoded(),
      );
      expect(
        plan.fallbackFor(MountedResourceKind.font)?.reason,
        ResourceFallbackReason.disabled,
      );
      expect(
        plan.bindingFor(MountedResourceKind.theme),
        isA<SelectedResourceBinding>(),
      );
    });

    test('refuses a document generation or member it does not own', () {
      expect(
        () => NativeMountPlan.fromDecoded({
          ..._publishedDocument(),
          'format': 'licoup.client.mount-plan.v2',
        }),
        throwsA(
          isA<NativeMountPlanFormatException>().having(
            (error) => error.code,
            'code',
            'mount_plan_format_unknown',
          ),
        ),
      );
      expect(
        () => NativeMountPlan.fromDecoded({
          ..._publishedDocument(),
          'widget': 'Container()',
        }),
        throwsA(
          isA<NativeMountPlanFormatException>().having(
            (error) => error.code,
            'code',
            'mount_plan_field_unknown',
          ),
        ),
      );
      expect(
        () => NativeMountPlan.fromDecoded({
          ..._publishedDocument(),
          'contributions': [
            {
              'id': 'org.licoland.appearance.synthetic/theme',
              'primitive': 'text',
              'builder': 'buildTheme',
            },
          ],
        }),
        throwsA(
          isA<NativeMountPlanFormatException>().having(
            (error) => error.code,
            'code',
            'mount_plan_contribution_invalid',
          ),
        ),
      );
    });

    test('refuses a kind whose fallback contradicts its declared default', () {
      expect(
        () => NativeMountPlan.fromDecoded({
          ..._publishedDocument(),
          'bindings': [
            {'kind': 'theme', 'system': 'locale'},
            {'kind': 'font', 'system': 'font'},
          ],
        }),
        throwsA(
          isA<NativeMountPlanFormatException>().having(
            (error) => error.code,
            'code',
            'mount_plan_binding_invalid',
          ),
        ),
      );
    });

    test('refuses a kind that both serves a resource and fell back', () {
      expect(
        () => NativeMountPlan.fromDecoded(
          _publishedDocument(
            fallbacks: [
              {
                'kind': 'theme',
                'resourceId': 'org.licoland.theme.aurora',
                'packageId': 'org.licoland.appearance.synthetic',
                'reason': 'replaced',
              },
            ],
          ),
        ),
        throwsA(
          isA<NativeMountPlanFormatException>().having(
            (error) => error.code,
            'code',
            'mount_plan_binding_conflict',
          ),
        ),
      );
    });
  });

  group('host registry', () {
    test('mounts a theme contribution through its registered primitive', () {
      final registry = ExtensionHostRegistry(host: _host());
      addTearDown(registry.dispose);
      var notifications = 0;
      registry.addListener(() => notifications += 1);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(contributions: [_themeText()]),
        ),
      );

      expect(notifications, 1);
      expect(revision.mounted, hasLength(1));
      expect(revision.mounted.single.primitive, DeclarativePrimitive.text);
      expect(revision.mounted.single.inputs['label'], 'Aurora');
      expect(revision.refusals, isEmpty);
      expect(revision.appearance.source, ResolvedAppearanceSource.selectedResource);
      expect(revision.appearance.resourceId, 'org.licoland.theme.aurora');
      expect(revision.appearance.packageGeneration, 3);
      expect(revision.appearance.isDefault, isFalse);
      expect(revision.appearance.tokens['bg-base'], '#101014');
    });

    test('re-mounting the same revision does not tear the interface down', () {
      final registry = ExtensionHostRegistry(host: _host());
      addTearDown(registry.dispose);
      final plan = NativeMountPlan.fromDecoded(
        _publishedDocument(contributions: [_themeText()]),
      );
      final first = registry.mount(plan);
      var notifications = 0;
      registry.addListener(() => notifications += 1);

      final second = registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(contributions: [_themeText()]),
        ),
      );

      expect(identical(first, second), isTrue);
      expect(notifications, 0);
    });

    test('refuses an unregistered primitive and keeps the rest mounted', () {
      final registry = ExtensionHostRegistry(
        host: _host(
          primitives: const {DeclarativePrimitive.text},
        ),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(
            contributions: [
              _themeText(),
              {
                'id': 'org.licoland.appearance.synthetic/summary',
                'primitive': 'table',
                'inputs': {
                  'rows': [
                    ['Role', 'Value'],
                  ],
                },
              },
            ],
          ),
        ),
      );

      expect(revision.mounted, hasLength(1));
      expect(revision.mounted.single.id, 'org.licoland.appearance.synthetic/theme');
      final refusal = revision.refusals.single;
      expect(refusal.refusal, ExtensionMountRefusal.primitiveUnavailable);
      expect(refusal.refusal!.code, 'primitive_unavailable');
      expect(refusal.field, 'primitive');
      expect(refusal.contribution.id, 'org.licoland.appearance.synthetic/summary');
    });

    test('refuses a primitive the plan itself does not publish', () {
      final registry = ExtensionHostRegistry(host: _host());
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded({
          ..._publishedDocument(
            contributions: [
              {
                'id': 'org.licoland.appearance.synthetic/chart',
                'primitive': 'chart',
              },
            ],
          ),
          'hostPrimitives': ['text'],
        }),
      );

      expect(revision.mounted, isEmpty);
      expect(
        revision.refusals.single.refusal,
        ExtensionMountRefusal.primitiveUndeclared,
      );
      expect(revision.refusals.single.refusal!.code, 'primitive_undeclared');
    });

    test('refuses an undeclared action with a stable reason', () {
      final registry = ExtensionHostRegistry(
        host: _host(actions: const {'org.licoland.action.apply-theme'}),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(
            contributions: [
              {
                'id': 'org.licoland.appearance.synthetic/apply',
                'primitive': 'action',
                'actionRef': 'org.licoland.action.erase-everything',
                'inputs': {'label': 'Apply'},
              },
            ],
          ),
        ),
      );

      expect(revision.mounted, isEmpty);
      final refusal = revision.refusals.single;
      expect(refusal.refusal, ExtensionMountRefusal.actionUndeclared);
      expect(refusal.refusal!.code, 'action_undeclared');
      expect(refusal.field, 'actionRef');
    });

    test('refuses an action the plan publishes but this build did not register', () {
      final registry = ExtensionHostRegistry(
        host: _host(actions: const <String>{}),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded({
          ..._publishedDocument(
            contributions: [
              {
                'id': 'org.licoland.appearance.synthetic/apply',
                'primitive': 'action',
                'actionRef': 'org.licoland.action.apply-theme',
                'inputs': {'label': 'Apply'},
              },
            ],
          ),
          'hostActions': ['org.licoland.action.apply-theme'],
        }),
      );

      expect(
        revision.refusals.single.refusal,
        ExtensionMountRefusal.actionUnavailable,
      );
      expect(revision.refusals.single.refusal!.code, 'action_unavailable');
    });

    test('refuses a resource format this build compiles no renderer for', () {
      final registry = ExtensionHostRegistry(
        host: _host(
          primitives: const {
            DeclarativePrimitive.text,
            DeclarativePrimitive.chart,
          },
        ),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(
            contributions: [
              {
                'id': 'org.licoland.appearance.synthetic/graph',
                'primitive': 'chart',
                'resourceFormat': 'licoup.ui.graph-resource.v9',
              },
            ],
          ),
        ),
      );

      expect(
        revision.refusals.single.refusal,
        ExtensionMountRefusal.resourceFormatUnavailable,
      );
      expect(
        revision.refusals.single.refusal!.code,
        'resource_format_unavailable',
      );
    });
  });

  group('appearance fallback', () {
    test('a disabled package renders the declared default deterministically', () {
      final registry = ExtensionHostRegistry(
        host: _host(defaults: const {'bg-base': '#101014', 'brand': '#88ff00'}),
      );
      addTearDown(registry.dispose);

      Map<String, Object?> disabledPlan() => _publishedDocument(
        themeBinding: const {'kind': 'theme', 'system': 'appearance'},
        fallbacks: [
          {
            'kind': 'theme',
            'resourceId': 'org.licoland.theme.aurora',
            'packageId': 'org.licoland.appearance.synthetic',
            'reason': 'disabled',
          },
        ],
      );

      final revision = registry.mount(
        NativeMountPlan.fromDecoded(disabledPlan()),
      );

      // The withdrawn package contributes nothing, and the appearance is the
      // host's own, with the recorded reason carried beside it.
      expect(revision.mounted, isEmpty);
      expect(revision.appearance.isDefault, isTrue);
      expect(
        revision.appearance.source,
        ResolvedAppearanceSource.declaredDefault,
      );
      expect(revision.appearance.resourceId, isNull);
      expect(revision.appearance.fallbackReason, 'disabled');
      expect(revision.appearance.tokens, {
        'bg-base': '#101014',
        'brand': '#88ff00',
      });

      // The same published bindings always project the same appearance: the
      // fallback is a function of the document, not of what was rendered before
      // and not of what the withdrawn resource used to supply.
      final again = ExtensionHostRegistry(
        host: _host(defaults: const {'bg-base': '#101014', 'brand': '#88ff00'}),
      );
      addTearDown(again.dispose);
      final repeated = again.mount(NativeMountPlan.fromDecoded(disabledPlan()));
      expect(repeated.appearance.tokens, revision.appearance.tokens);
      expect(repeated.appearance.fallbackReason, 'disabled');
    });

    test('a selected theme changes the value the host renders', () {
      final registry = ExtensionHostRegistry(
        host: _host(defaults: const {'bg-base': '#101014'}),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded({
          ..._publishedDocument(contributions: [_themeText()]),
          'themeTokens': {'bg-base': '#fee1d0'},
        }),
      );

      expect(revision.appearance.isDefault, isFalse);
      expect(revision.appearance.tokens['bg-base'], '#fee1d0');
    });

    test('the empty plan renders the declared default for every kind', () {
      final registry = ExtensionHostRegistry(
        host: _host(defaults: const {'bg-base': '#101014'}),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.empty(themeTokens: const {}),
      );

      expect(revision.mounted, isEmpty);
      expect(revision.appearance.tokens, {'bg-base': '#101014'});
      for (final kind in MountedResourceKind.values) {
        expect(revision.appearance.isDefault, isTrue, reason: kind.name);
      }
    });

    test('withdrawing a plan returns rendering to the built-in appearance', () {
      final registry = ExtensionHostRegistry(
        host: _host(defaults: const {'bg-base': '#101014'}),
      );
      addTearDown(registry.dispose);
      registry.mount(
        NativeMountPlan.fromDecoded(
          _publishedDocument(contributions: [_themeText()]),
        ),
      );
      var notifications = 0;
      registry.addListener(() => notifications += 1);

      registry.withdraw();

      expect(registry.isMounted, isFalse);
      expect(registry.revision, isNull);
      expect(notifications, 1);
      // Withdrawing twice is not a second change.
      registry.withdraw();
      expect(notifications, 1);
    });

    test('a contributed theme sets only the roles this build renders', () {
      final registry = ExtensionHostRegistry(
        host: _host(
          defaults: const {'bg-base': '#101014'},
          roles: const {'bg-base'},
        ),
      );
      addTearDown(registry.dispose);

      final revision = registry.mount(
        NativeMountPlan.fromDecoded({
          ..._publishedDocument(contributions: [_themeText()]),
          'themeTokens': {'bg-base': '#fee1d0', 'not-a-role': '#ffffff'},
        }),
      );

      // The role this build renders was changed; the role it does not render
      // was not invented into the appearance, and the host's own value for a
      // role the resource left alone stayed.
      expect(revision.appearance.tokens, {'bg-base': '#fee1d0'});
    });
  });
}
