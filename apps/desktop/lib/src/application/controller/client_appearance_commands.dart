import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/features/settings/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:licoup/src/platform/presentation/presentation_mount_plan_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Appearance-only commands and state access.
mixin ClientAppearanceCommands {
  AppearancePreferenceOwner get appearancePreferenceOwner;
  LayoutManager get layoutManager;
  PortableDataRoot get portableData;
  AppearancePresetCatalogService get appearancePresetCatalogService;
  PresentationMountPlanService get presentationMountPlanService;

  String get appearancePresetId => appearancePreferenceOwner.presetId;
  ReduceMotionPreference get reduceMotion =>
      appearancePreferenceOwner.reduceMotion;
  String get loadingEffectId => appearancePreferenceOwner.loadingEffectId;

  /// What the mounted native plan contributes to this client's interface.
  List<MountedContribution> get planContributions =>
      appearancePreferenceOwner.planContributions;
  set appearancePresetId(String value) {
    appearancePreferenceOwner.replacePreset(value);
  }

  List<AppearancePresetConfig> get appearancePresetConfigs =>
      appearancePreferenceOwner.presets;
  List<AppearancePresetConfig> get selectableAppearancePresetConfigs =>
      appearancePreferenceOwner.selectablePresets;
  String get appearancePresetDirectoryPath =>
      appearancePreferenceOwner.directoryPath;
  List<String> get appearancePresetLoadErrors =>
      appearancePreferenceOwner.loadErrors;

  Future<void> setAppearancePreset(
    String presetId, {
    ApplicationCause? cause,
  }) async {
    if (!hasAppearancePresetConfig(presetId, appearancePresetConfigs)) {
      presetId = AppearancePresetIds.defaultSystem;
    }
    if (await layoutManager.setAppearancePreset(presetId, cause: cause)) {
      appearancePreferenceOwner.replacePreset(presetId, cause: cause);
    }
  }

  Future<void> setReduceMotion(
    ReduceMotionPreference preference, {
    ApplicationCause? cause,
  }) async {
    if (!await layoutManager.setReduceMotion(preference, cause: cause)) {
      throw StateError('reduce_motion_preference_write_failed');
    }
    appearancePreferenceOwner.replaceReduceMotion(preference, cause: cause);
  }

  Future<void> setLoadingEffect(String id, {ApplicationCause? cause}) async {
    if (!await layoutManager.setLoadingEffect(id, cause: cause)) {
      throw StateError('loading_effect_preference_write_failed');
    }
    appearancePreferenceOwner.replaceLoadingEffect(id, cause: cause);
  }

  bool applyAppearancePresetCatalog(AppearancePresetCatalogLoadResult catalog) {
    return appearancePreferenceOwner.applyCatalog(
      configs: catalog.configs,
      directoryPath: catalog.directory.path,
      errorCodes: catalog.errors,
    );
  }

  /// Adopts the appearance the published native mount plan serves.
  ///
  /// An absent plan is not a failure: the client keeps rendering the built-in
  /// appearance it already resolved. The plan's tokens are read over the
  /// client's own rendering, so a resource that publishes a subset of the roles
  /// changes those roles and leaves the rest of the appearance in place.
  ///
  /// The contributions the same revision mounted are adopted with it, in plan
  /// order. They are what the plan decided this client renders, so the owner
  /// receives them from the registry that decided it rather than from the
  /// document.
  Future<void> loadPresentationMountPlan() async {
    final mounted = await presentationMountPlanService.mountPublishedPlan(
      portableData,
      appearanceDefaults: _appearanceRenderingTokens(),
    );
    appearancePreferenceOwner.replacePlanContributions(
      mounted?.revision.mounted ?? const [],
    );
    appearancePreferenceOwner.replacePlanAppearance(mounted?.appearance);
  }

  Map<String, String> _appearanceRenderingTokens() {
    for (final preset in appearancePresetConfigs) {
      if (preset.mode == AppearancePresetMode.dark &&
          preset.tokens.isNotEmpty) {
        return preset.tokens;
      }
    }
    for (final preset in appearancePresetConfigs) {
      if (preset.tokens.isNotEmpty) return preset.tokens;
    }
    return const <String, String>{};
  }
}
