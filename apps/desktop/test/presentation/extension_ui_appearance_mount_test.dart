import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/settings/controller/appearance_preference_owner.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/presentation_plan_appearance.dart';
import 'package:licoup/src/frontend/appearance/appearance_projection_adapter.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/presentation/presentation_mount_plan_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';

/// The published document a native host writes for one appearance package
/// generation. It is written as bytes, exactly as the native side publishes it,
/// so the client is exercised through its real reader.
Map<String, Object?> _publishedPlan({
  List<Map<String, Object?>>? bindings,
  List<Map<String, Object?>> fallbacks = const [],
  List<Map<String, Object?>> contributions = const [],
  Map<String, String> themeTokens = const {},
}) => {
  'format': 'licoup.client.mount-plan.v1',
  'version': 1,
  'revision': 12,
  'servedProfiles': <String>[],
  'hostPrimitives': ['form', 'table', 'chart', 'progress', 'text', 'action'],
  'hostActions': <String>[],
  'bindings':
      bindings ??
      [
        {
          'kind': 'theme',
          'resourceId': 'org.licoland.theme.aurora',
          'packageId': 'org.licoland.appearance.synthetic',
          'packageGeneration': 4,
        },
        {'kind': 'layout', 'system': 'appearance'},
        {'kind': 'style', 'system': 'appearance'},
        {'kind': 'font', 'system': 'font'},
        {'kind': 'language', 'system': 'locale'},
        {'kind': 'composition', 'system': 'appearance'},
      ],
  'fallbacks': fallbacks,
  if (themeTokens.isNotEmpty) 'themeTokens': themeTokens,
  'contributions': contributions,
};

Map<String, Object?> _contribution({
  String id = 'org.licoland.appearance.synthetic/theme',
  String primitive = 'text',
  String? actionRef,
  String? resourceFormat,
}) => {
  'id': id,
  'primitive': primitive,
  'actionRef': ?actionRef,
  'resourceFormat': ?resourceFormat,
  'inputs': {'label': 'Aurora'},
};

Future<PortableDataRoot> _publishedRoot(Map<String, Object?> document) async {
  final rootDirectory = await Directory.systemTemp.createTemp(
    'appearance-mount-plan-',
  );
  addTearDown(() async {
    if (await rootDirectory.exists()) {
      await rootDirectory.delete(recursive: true);
    }
  });
  final portableData = PortableDataRoot(dataDirectoryOverride: rootDirectory);
  final client = await portableData.clientDirectory();
  final file = File(
    '${client.path}/${PresentationMountPlanService.planFileName}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(document));
  return portableData;
}

/// The client's own dark appearance, as the composition hands it to the plan.
Map<String, String> _builtInDarkTokens() => builtInAppearancePresetConfigs
    .firstWhere((config) => config.id == AppearancePresetIds.licoSoda)
    .tokens;

/// The theme the production shell builds from one resolved appearance.
ThemeData _themeFor(PlanAppearanceSnapshot appearance) {
  final owner = AppearancePreferenceOwner()
    ..replacePlanAppearance(appearance.appearance);
  final projection = resolveAppearanceProjection(owner);
  final theme = buildLicoTheme(
    presetId: projection.presetId,
    presets: appearancePresetConfigsFromProjection(projection),
    platformBrightness: Brightness.dark,
  );
  owner.dispose();
  return theme;
}

/// One mounted plan and the values a renderer reads from it.
final class PlanAppearanceSnapshot {
  const PlanAppearanceSnapshot({
    required this.appearance,
    required this.mounted,
    required this.refusals,
    required this.planTokens,
  });

  final PresentationPlanAppearance appearance;
  final List<MountedContribution> mounted;
  final List<({String id, String code, String? field})> refusals;
  final Map<String, String> planTokens;
}

Future<PlanAppearanceSnapshot> _mount(
  Map<String, Object?> document, {
  Map<String, String>? defaults,
}) async {
  final portableData = await _publishedRoot(document);
  final mounted = await const PresentationMountPlanService().mountPublishedPlan(
    portableData,
    appearanceDefaults: defaults ?? _builtInDarkTokens(),
  );
  expect(mounted, isNotNull, reason: 'the published plan must mount');
  return PlanAppearanceSnapshot(
    appearance: mounted!.appearance,
    mounted: mounted.revision.mounted,
    refusals: mounted.revision.refusals
        .map(
          (decision) => (
            id: decision.contribution.id,
            code: decision.refusal!.code,
            field: decision.field,
          ),
        )
        .toList(),
    planTokens: mounted.revision.appearance.tokens,
  );
}

void main() {
  const service = PresentationMountPlanService();

  testWidgets('a published theme contribution changes what is rendered', (
    tester,
  ) async {
    // The plan the host published: one theme resource selected, and two
    // contributions it composes through primitives this build compiled.
    final mounted = await tester.runAsync(
      () => _mount(
        _publishedPlan(
          contributions: [
            _contribution(),
            _contribution(
              id: 'org.licoland.appearance.synthetic/summary',
              primitive: 'progress',
            ),
          ],
          themeTokens: const {
            'brand': '#ff0055',
            'bg-base': '#101020',
            'not-a-role': '#123456',
          },
        ),
      ),
    );

    // The contributions mount through the registered primitive set, and only
    // the roles this build renders reach the renderer.
    expect(mounted!.mounted, hasLength(2));
    expect(mounted.mounted.map((entry) => entry.primitive), [
      DeclarativePrimitive.text,
      DeclarativePrimitive.progress,
    ]);
    expect(mounted.refusals, isEmpty);
    expect(mounted.appearance.isDefault, isFalse);
    expect(mounted.appearance.resourceId, 'org.licoland.theme.aurora');
    expect(mounted.appearance.packageGeneration, 4);
    expect(mounted.planTokens['brand'], '#ff0055');
    expect(mounted.planTokens.containsKey('not-a-role'), isFalse);

    // The projection and adapter the production shell uses carry the plan's
    // values, so the theme a widget renders under changed with the resource.
    final theme = _themeFor(mounted);
    expect(theme.colorScheme.primary, const Color(0xFFFF0055));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF101020));

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: Center(
            child: FilledButton(onPressed: null, child: Text('Apply')),
          ),
        ),
      ),
    );
    // The value the widget actually renders is the contributed one.
    expect(
      Theme.of(tester.element(find.byType(FilledButton))).colorScheme.primary,
      const Color(0xFFFF0055),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      isNull,
    );
    final scaffold = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(Scaffold),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(scaffold.color, const Color(0xFF101020));
  });

  testWidgets('an undeclared action is refused and the rest still renders', (
    tester,
  ) async {
    final mounted = await tester.runAsync(
      () => _mount(
        _publishedPlan(
          contributions: [
            _contribution(),
            _contribution(
              id: 'org.licoland.appearance.synthetic/erase',
              primitive: 'action',
              actionRef: 'org.licoland.action.erase-everything',
            ),
          ],
        ),
      ),
    );

    expect(mounted!.mounted, hasLength(1));
    expect(mounted.mounted.single.primitive, DeclarativePrimitive.text);
    expect(mounted.refusals, hasLength(1));
    expect(
      mounted.refusals.single.id,
      'org.licoland.appearance.synthetic/erase',
    );
    expect(mounted.refusals.single.code, 'action_undeclared');
    expect(mounted.refusals.single.field, 'actionRef');
  });

  testWidgets('a primitive this build did not compile is refused', (
    tester,
  ) async {
    final mounted = await tester.runAsync(
      () => _mount(
        _publishedPlan(
          contributions: [
            _contribution(
              id: 'org.licoland.appearance.synthetic/graph',
              primitive: 'chart',
              resourceFormat: 'licoup.ui.graph-resource.v9',
            ),
          ],
        ),
      ),
    );

    expect(mounted!.mounted, isEmpty);
    expect(mounted.refusals.single.code, 'resource_format_unavailable');
    expect(mounted.refusals.single.field, 'resourceFormat');
  });

  testWidgets('disabling the package falls back to the client appearance', (
    tester,
  ) async {
    // What the native lifecycle publishes after the package is switched off:
    // the theme kind serves the declared default and records why. The withdrawn
    // package contributes nothing.
    final defaults = _builtInDarkTokens();
    final mounted = await tester.runAsync(
      () => _mount(
        _publishedPlan(
          bindings: [
            {'kind': 'theme', 'system': 'appearance'},
            {'kind': 'layout', 'system': 'appearance'},
            {'kind': 'style', 'system': 'appearance'},
            {'kind': 'font', 'system': 'font'},
            {'kind': 'language', 'system': 'locale'},
            {'kind': 'composition', 'system': 'appearance'},
          ],
          fallbacks: [
            {
              'kind': 'theme',
              'resourceId': 'org.licoland.theme.aurora',
              'packageId': 'org.licoland.appearance.synthetic',
              'reason': 'disabled',
            },
          ],
        ),
        defaults: defaults,
      ),
    );

    expect(mounted!.mounted, isEmpty);
    expect(mounted.appearance.isDefault, isTrue);
    expect(mounted.appearance.source, PlanAppearanceSource.declaredDefault);
    expect(mounted.appearance.resourceId, isNull);
    expect(mounted.appearance.packageGeneration, isNull);
    expect(mounted.appearance.fallbackReason, 'disabled');
    expect(
      mounted.appearance.fallback!.resourceId,
      'org.licoland.theme.aurora',
    );
    expect(mounted.planTokens['brand'], defaults['brand']);

    // The withdrawn resource's values are gone: the theme renders the client's
    // own appearance, and the same published document always resolves to it.
    final theme = _themeFor(mounted);
    final builtIn = buildLicoTheme(
      presetId: AppearancePresetIds.licoSoda,
      presets: builtInAppearancePresetConfigs,
      platformBrightness: Brightness.dark,
    );
    expect(theme.colorScheme.primary, builtIn.colorScheme.primary);
    expect(theme.scaffoldBackgroundColor, builtIn.scaffoldBackgroundColor);

    final repeated = await tester.runAsync(
      () => _mount(
        _publishedPlan(
          bindings: [
            {'kind': 'theme', 'system': 'appearance'},
            {'kind': 'font', 'system': 'font'},
          ],
          fallbacks: [
            {
              'kind': 'theme',
              'resourceId': 'org.licoland.theme.aurora',
              'packageId': 'org.licoland.appearance.synthetic',
              'reason': 'disabled',
            },
          ],
        ),
        defaults: defaults,
      ),
    );
    expect(repeated!.planTokens, mounted.planTokens);
    expect(repeated.appearance.fallbackReason, 'disabled');
  });

  test('a document this build cannot own is refused whole', () async {
    final portableData = await _publishedRoot({
      ..._publishedPlan(),
      'widget': 'Container()',
    });

    expect(await service.mountPublishedPlan(portableData), isNull);
    expect(await service.readPublishedPlan(portableData), isNull);
  });

  test('an absent plan leaves the built-in appearance rendering', () async {
    final rootDirectory = await Directory.systemTemp.createTemp(
      'appearance-mount-plan-absent-',
    );
    addTearDown(() async {
      if (await rootDirectory.exists()) {
        await rootDirectory.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: rootDirectory);

    expect(await service.mountPublishedPlan(portableData), isNull);
    expect(await service.readPublishedPlan(portableData), isNull);
  });
}
