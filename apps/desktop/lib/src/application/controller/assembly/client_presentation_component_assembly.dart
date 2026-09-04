import 'dart:io' show Platform;

import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/layout/built_in_layout_catalog.dart';
import 'package:licoup/src/application/features/layout/layout_catalog.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientPresentationComponentAssembly {
  ClientPresentationComponentAssembly({
    required PortableDataRoot portableData,
    LayoutCatalog? layoutCatalog,
    LayoutStateStore? layoutStateStore,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
  }) : shellController = ClientShellController() {
    this.layoutCatalog = layoutCatalog ?? createBuiltInLayoutCatalog();
    this.layoutStateStore =
        layoutStateStore ?? LayoutStateStore(this.layoutCatalog);
    if (!identical(this.layoutStateStore.catalog, this.layoutCatalog)) {
      throw const FormatException('layout_state_catalog_identity_mismatch');
    }
    final preferredLayout = switch (Platform.operatingSystem) {
      'macos' ||
      'windows' ||
      'ios' ||
      'android' => LayoutProfileId.parse('messaging'),
      _ => LayoutProfileId.parse('dashboard'),
    };
    this.layoutManager =
        layoutManager ??
        LayoutManager(
          catalog: this.layoutCatalog,
          preferencesRepository:
              presentationPreferencesRepository ??
              FilePresentationPreferencesRepository(
                portableData: portableData,
                fallback: PresentationPreferences(
                  layoutProfileId: preferredLayout,
                  appearancePresetId: AppearancePresetIds.defaultSystem,
                  localePreference: LocalePreference.system,
                ),
              ),
          canonicalFallback: PresentationPreferences(
            layoutProfileId: preferredLayout,
            appearancePresetId: AppearancePresetIds.defaultSystem,
            localePreference: LocalePreference.system,
          ),
          preferredDefaultId: preferredLayout,
          initialEnvironment: LayoutEnvironment.fromConstraints(
            surface: LayoutRuntimeSurface.desktop,
            width: 1280,
            height: 800,
            textScale: 1,
            hasPointer: true,
            hasKeyboard: true,
          ),
        );
  }

  final ClientShellController shellController;
  late final LayoutCatalog layoutCatalog;
  late final LayoutStateStore layoutStateStore;
  late final LayoutManager layoutManager;

  void dispose() {
    layoutManager.dispose();
    layoutStateStore.dispose();
    shellController.dispose();
  }
}
