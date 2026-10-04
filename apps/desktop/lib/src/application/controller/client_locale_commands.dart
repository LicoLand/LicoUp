import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/controller/locale_resource_owner.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/locale/locale_resource_pack.dart';
import 'package:licoup/src/platform/locale/locale_resource_catalog_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';

/// Locale-only commands and localized application copy access.
mixin ClientLocaleCommands on AgentWorkspaceCoordinator {
  LocalePreferenceOwner get localePreferenceOwner;
  LocaleResourceOwner get localeResourceOwner;
  LocaleResourceCatalogService get localeResourceCatalogService;
  PortableDataRoot get portableData;
  LayoutManager get layoutManager;

  String get localePreference => localePreferenceOwner.preference;
  set localePreference(String value) {
    localePreferenceOwner.replace(value);
  }

  /// Interface strings installed on this client, in load order.
  List<LocaleResourcePack> get installedLocaleResources =>
      localeResourceOwner.packs;

  /// Where the client reads installed language resources from.
  String get localeResourceDirectoryPath => localeResourceOwner.directoryPath;

  /// Stable codes for language resource documents that could not be used.
  List<String> get localeResourceLoadErrors => localeResourceOwner.loadErrors;

  /// Reads the installed language resources and publishes what was found.
  ///
  /// The resources drive the rendered interface, so this is the read that makes
  /// an installed resource visible; a first launch loads an empty set.
  Future<LocaleResourceCatalogLoadResult> loadInstalledLocaleResources({
    ApplicationCause? cause,
  }) async {
    final catalog = await localeResourceCatalogService.loadCatalog(
      portableData,
    );
    localeResourceOwner.applyInstalled(
      packs: catalog.packs,
      directoryPath: catalog.directory.path,
      errorCodes: catalog.errors,
      cause: cause,
    );
    return catalog;
  }

  ClientApplicationStrings get clientStrings =>
      ClientApplicationStrings.forPreference(localePreference);

  Future<void> setLocalePreference(
    String value, {
    ApplicationCause? cause,
  }) async {
    final normalized = LocalePreference.normalize(value);
    if (await layoutManager.setLocalePreference(normalized, cause: cause)) {
      localePreferenceOwner.replace(normalized, cause: cause);
    }
  }

  @override
  ClientApplicationStrings get agentWorkspaceStrings => clientStrings;
}
