import 'package:flutter/foundation.dart'
    show ChangeNotifier, defaultTargetPlatform;

import 'package:licoup/src/application/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
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
    BuiltInLayoutComposition? layoutComposition,
    LayoutManager? layoutManager,
    PresentationPreferencesRepository? presentationPreferencesRepository,
  }) : shellController = ClientShellController(),
       layoutComposition = layoutComposition ?? BuiltInLayoutComposition() {
    final preferredLayout = LayoutProfileDefaults.preferredForPlatform(
      defaultTargetPlatform,
    );
    this.layoutManager =
        layoutManager ??
        LayoutManager(
          catalog: this.layoutComposition.catalog,
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
  final BuiltInLayoutComposition layoutComposition;
  late final LayoutManager layoutManager;

  Iterable<ChangeNotifier> get listenables => [shellController];

  void dispose() {
    layoutManager.dispose();
    shellController.dispose();
  }
}
