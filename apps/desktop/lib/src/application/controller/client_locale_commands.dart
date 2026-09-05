import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';

/// Locale-only commands and localized application copy access.
mixin ClientLocaleCommands on AgentWorkspaceCoordinator {
  LocalePreferenceOwner get localePreferenceOwner;
  LayoutManager get layoutManager;

  String get localePreference => localePreferenceOwner.preference;
  set localePreference(String value) {
    localePreferenceOwner.replace(value);
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
