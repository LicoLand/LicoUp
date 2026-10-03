import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/application/features/settings/controller/appearance_preference_owner.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/theme/theme_appearance_source.dart';
import 'package:licoup/src/platform/presentation/file_presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

/// The resource the user asks for in these tests. It is deliberately not a
/// built-in preset id: the owner records the request, and a request is never
/// rewritten into an id the client happens to publish.
PresentationResourceSelection _requestedTheme({int? generation}) =>
    PresentationResourceSelection(
      resourceId: 'org.example.orbital-nights',
      packageId: 'org.example.orbital',
      packageGeneration: generation,
    );

void main() {
  test('a request is recorded exactly as chosen and published once', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    var changes = 0;
    owner.changes.listen((_) => changes += 1);

    final recorded = owner.requestResource(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );

    expect(recorded, isTrue);
    expect(changes, 1);
    final request = owner.requestedResource(PresentationResourceKind.theme);
    expect(request, isNotNull);
    expect(request!.resourceId, 'org.example.orbital-nights');
    expect(request.packageId, 'org.example.orbital');
    expect(request.packageGeneration, 3);
    // The catalogue this owner also carries is untouched: a resource request is
    // one fact, and the built-in style selection is another.
    expect(owner.presetId, AppearancePresetIds.licoSoda);
  });

  test('a repeated request is not rewritten and does not publish again', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    owner.requestResource(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );
    var changes = 0;
    owner.changes.listen((_) => changes += 1);

    final recorded = owner.requestResource(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );

    expect(recorded, isFalse);
    expect(changes, 0);
  });

  test('an unanswered request is unreported, not served and not a fallback',
      () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    owner.requestResource(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );

    final state = owner.resourceState(PresentationResourceKind.theme);

    expect(state.serving, PresentationResourceServing.unreported);
    expect(state.requested?.resourceId, 'org.example.orbital-nights');
    expect(state.servedResourceId, isNull);
    expect(state.fallbackReasonCode, isNull);
    expect(state.rendersRequestedResource, isFalse);
    expect(state.rendersDeclaredAppearance, isTrue);
  });

  test('a report serving the request keeps the identity across generations',
      () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    owner.requestResource(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );

    owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        servedResourceId: 'org.example.orbital-nights',
        packageGeneration: 3,
      ),
    });
    final served = owner.resourceState(PresentationResourceKind.theme);
    expect(served.serving, PresentationResourceServing.requested);
    expect(served.servedPackageGeneration, 3);
    expect(served.fallbackReasonCode, isNull);

    // A reinstall publishes the same identity at a new generation; the user's
    // request still applies, because the identity is the request and the
    // generation is only what the surface reported.
    owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        servedResourceId: 'org.example.orbital-nights',
        packageGeneration: 9,
      ),
    });
    final reinstalled = owner.resourceState(PresentationResourceKind.theme);
    expect(reinstalled.serving, PresentationResourceServing.requested);
    expect(reinstalled.requested, served.requested);
    expect(reinstalled.servedPackageGeneration, 9);
    expect(
      owner.requestedResource(PresentationResourceKind.theme)?.packageGeneration,
      3,
      reason: 'the stored request is what the user chose, not the last report',
    );
  });

  test('disable and uninstall keep the request and record the reason', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    final request = _requestedTheme(generation: 3);
    owner.requestResource(PresentationResourceKind.theme, request);

    for (final reason in [
      PresentationResourceFallbackReason.disabled,
      PresentationResourceFallbackReason.uninstalled,
    ]) {
      owner.replaceResourceReports({
        PresentationResourceKind.theme: PresentationResourceReport(
          fallbackReason: reason,
        ),
      });
      final state = owner.resourceState(PresentationResourceKind.theme);
      expect(state.serving, PresentationResourceServing.fallback);
      expect(state.requested, request);
      expect(state.fallbackReasonCode, reason.id);
      expect(state.rendersDeclaredAppearance, isTrue);
      expect(
        owner.requestedResource(PresentationResourceKind.theme),
        request,
        reason: 'a fallback never rewrites what the user asked for',
      );
    }

    // Switching the package back on restores the choice with no new request.
    owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        servedResourceId: 'org.example.orbital-nights',
        packageGeneration: 4,
      ),
    });
    final restored = owner.resourceState(PresentationResourceKind.theme);
    expect(restored.serving, PresentationResourceServing.requested);
    expect(restored.requested, request);
  });

  test('a report for a kind the user did not request is not a selection', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);

    owner.replaceResourceReports(const {
      PresentationResourceKind.font: PresentationResourceReport(
        servedResourceId: 'org.example.mono',
        packageGeneration: 1,
      ),
    });

    final state = owner.resourceState(PresentationResourceKind.font);
    expect(
      state.serving,
      PresentationResourceServing.unrequested,
      reason: 'a served resource no stored request names is reported as such',
    );
    expect(state.requested, isNull);
    expect(state.servedResourceId, 'org.example.mono');
    expect(state.rendersDeclaredAppearance, isFalse);
    expect(state.rendersRequestedResource, isFalse);
    expect(owner.requestedResource(PresentationResourceKind.font), isNull);
  });

  test('the record read at startup reaches the surface unchanged', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    var changes = 0;
    owner.changes.listen((_) => changes += 1);

    final adopted = owner.adoptResourceSelections({
      'theme': PresentationResourceSelection(
        resourceId: 'org.example.orbital-nights',
        packageId: 'org.example.orbital',
        packageGeneration: 3,
      ),
      // A kind this build does not serve stays recorded for the build that
      // does, instead of being dropped on the way in.
      'orbital-behavior': PresentationResourceSelection(
        resourceId: 'org.example.behavior',
      ),
    });

    expect(adopted, isTrue);
    expect(changes, 1);
    expect(owner.resourceSelections.keys, [
      'theme',
      'orbital-behavior',
    ]);
    expect(
      owner.resourceState(PresentationResourceKind.theme).serving,
      PresentationResourceServing.unreported,
      reason: 'the record is adopted without an availability answer',
    );
    expect(
      owner.adoptResourceSelections(owner.resourceSelections),
      isFalse,
      reason: 'adopting the same record publishes nothing',
    );
    expect(changes, 1);
  });

  test('clearing a request returns the kind to the declared default', () {    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    owner.requestResource(PresentationResourceKind.theme, _requestedTheme());
    owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        fallbackReason: PresentationResourceFallbackReason.disabled,
      ),
    });

    final cleared = owner.requestResource(PresentationResourceKind.theme, null);

    expect(cleared, isTrue);
    expect(owner.resourceSelections, isEmpty);
    final state = owner.resourceState(PresentationResourceKind.theme);
    expect(state.serving, PresentationResourceServing.declaredDefault);
    expect(state.requested, isNull);
    expect(
      state.fallbackReasonCode,
      isNull,
      reason: 'asking for the declared default is not a fallback',
    );
  });

  test('an identical report does not publish a second change', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);
    owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        servedResourceId: 'org.example.orbital-nights',
      ),
    });
    var changes = 0;
    owner.changes.listen((_) => changes += 1);

    final replaced = owner.replaceResourceReports(const {
      PresentationResourceKind.theme: PresentationResourceReport(
        servedResourceId: 'org.example.orbital-nights',
      ),
    });

    expect(replaced, isFalse);
    expect(changes, 0);
  });

  test('every published kind answers with one state and one owner', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);

    final states = owner.resourceStates;

    expect(
      states.map((state) => state.kind).toList(),
      PresentationResourceKind.values,
    );
    expect(
      states.every(
        (state) => state.serving == PresentationResourceServing.declaredDefault,
      ),
      isTrue,
    );
  });

  test('a stored request resolves the same state after a restart', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'appearance-resource-preference-test-',
    );
    addTearDown(() async {
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: temporaryRoot);
    final fallback = PresentationPreferences(
      layoutProfileId: LayoutProfileId.parse('dashboard'),
      appearancePresetId: AppearancePresetIds.defaultSystem,
      localePreference: 'system',
    );
    final repository = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    await repository.setResourceSelection(
      PresentationResourceKind.theme,
      _requestedTheme(generation: 3),
    );
    await repository.setResourceSelection(
      PresentationResourceKind.language,
      PresentationResourceSelection(resourceId: 'org.example.french'),
    );

    // Restart: a new repository and a new owner read only the document.
    final restarted = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    final loaded = (await restarted.load()).preferences;
    final owner = AppearancePreferenceOwner(
      resourceSelections: loaded.resourceSelections,
    );
    addTearDown(owner.dispose);
    final decoded = jsonDecode(
      await File(
        '${(await portableData.clientDirectory()).path}'
        '/appearance-preferences.json',
      ).readAsString(),
    ) as Map;

    expect(
      (decoded['resourceSelections'] as Map).keys,
      containsAll(<String>['theme', 'language']),
    );
    expect(
      owner.requestedResource(PresentationResourceKind.theme),
      _requestedTheme(generation: 3),
    );
    expect(
      owner.resourceState(PresentationResourceKind.theme).serving,
      PresentationResourceServing.unreported,
      reason: 'a restart reads the request; it does not invent an answer',
    );
    expect(
      owner.resourceState(PresentationResourceKind.language).serving,
      PresentationResourceServing.unreported,
    );
  });

  group('ThemeAppearanceSource', () {
    test('renders the requested resource only when it is reported served', () {
      final owner = AppearancePreferenceOwner();
      addTearDown(owner.dispose);
      owner.requestResource(PresentationResourceKind.theme, _requestedTheme());

      final unanswered = ThemeAppearanceSource.fromResourceState(
        owner.resourceState(PresentationResourceKind.theme),
      );
      expect(unanswered.rendersRequestedResource, isFalse);
      expect(unanswered.rendersDeclaredAppearance, isTrue);
      expect(unanswered.isReported, isFalse);
      expect(unanswered.requestedResourceId, 'org.example.orbital-nights');

      owner.replaceResourceReports(const {
        PresentationResourceKind.theme: PresentationResourceReport(
          servedResourceId: 'org.example.orbital-nights',
          packageGeneration: 4,
        ),
      });
      final served = ThemeAppearanceSource.fromResourceState(
        owner.resourceState(PresentationResourceKind.theme),
      );
      expect(served.rendersRequestedResource, isTrue);
      expect(served.rendersDeclaredAppearance, isFalse);
      expect(served.isReported, isTrue);
      expect(served.isFallback, isFalse);
      expect(served.servedPackageGeneration, 4);
    });

    test('reports a fallback reason only when the package owner named one', () {
      final owner = AppearancePreferenceOwner();
      addTearDown(owner.dispose);
      owner.requestResource(PresentationResourceKind.theme, _requestedTheme());

      // The package owner answered "not served" without naming the change.
      owner.replaceResourceReports(const {
        PresentationResourceKind.theme: PresentationResourceReport(),
      });
      final unnamed = ThemeAppearanceSource.fromResourceState(
        owner.resourceState(PresentationResourceKind.theme),
      );
      expect(unnamed.isFallback, isTrue);
      expect(unnamed.isReported, isTrue);
      expect(unnamed.fallbackReasonCode, isNull);

      owner.replaceResourceReports({
        PresentationResourceKind.theme: PresentationResourceReport(
          fallbackReason: PresentationResourceFallbackReason.replaced,
        ),
      });
      final named = ThemeAppearanceSource.fromResourceState(
        owner.resourceState(PresentationResourceKind.theme),
      );
      expect(named.isFallback, isTrue);
      expect(named.fallbackReasonCode, 'replaced');
    });
  });
}
