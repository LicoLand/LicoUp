import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/presentation/layout/layout_catalog.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';

final class ClientPresentationComponentAssembly {
  ClientPresentationComponentAssembly({
    required this.layoutCatalog,
    required this.layoutManager,
  }) : appearancePreferenceOwner = AppearancePreferenceOwner(),
       localePreferenceOwner = LocalePreferenceOwner(),
       functionalStatusRuntime = FunctionalStatusRuntime() {
    if (!identical(layoutManager.catalog, layoutCatalog)) {
      throw const FormatException('layout_manager_catalog_identity_mismatch');
    }
  }

  final AppearancePreferenceOwner appearancePreferenceOwner;
  final LocalePreferenceOwner localePreferenceOwner;
  final FunctionalStatusRuntime functionalStatusRuntime;
  final LayoutCatalog layoutCatalog;
  final LayoutManager layoutManager;

  void dispose() {
    layoutManager.dispose();
    functionalStatusRuntime.dispose();
    localePreferenceOwner.dispose();
    appearancePreferenceOwner.dispose();
  }
}
