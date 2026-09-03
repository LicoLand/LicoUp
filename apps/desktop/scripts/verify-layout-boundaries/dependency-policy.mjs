import { NEUTRAL_LAYOUT_CONTRACTS } from "./config.mjs";
import {
  importsFrom,
  maskCommentsAndStrings,
  matchingDelimiter,
  resolveDartImport,
  stripDartComments,
} from "./dart-source.mjs";
import { fail } from "./errors.mjs";
import {
  codeOwnerFor,
  sourceOwnerFor,
  testOwnerFor,
} from "./ownership.mjs";

const destinationPresentationScopeOwners = new Set([
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agents_canvas.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/archived_conversations_settings_section.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/client_update_settings_card.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/layout_profile_selector.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/settings_panel.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/settings_panel_widgets.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/startup_autostart_card.dart",
  "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/destinations/settings_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_agents_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_settings_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/destinations/agents_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/destinations/single_pane_destinations.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_agents_destination.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_settings_destination.dart",
]);

const legacySharedDependencies = new Set([
  "apps/desktop/lib/src/frontend/shared/appearance/appearance_preset_config.dart",
  "apps/desktop/lib/src/frontend/shared/ui/apple_buttons.dart",
  "apps/desktop/lib/src/frontend/shared/ui/apple_control_metrics.dart",
  "apps/desktop/lib/src/frontend/shared/ui/apple_glass.dart",
  "apps/desktop/lib/src/frontend/shared/ui/theme.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_icon_button.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_motion.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_search_capsule.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_radius.dart",
  "apps/desktop/lib/src/frontend/shared/ui/lico_typography.dart",
  "apps/desktop/lib/src/frontend/shared/ui/theme_colors.dart",
]);

const legacySharedUiImports = new Set([
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart|apps/desktop/lib/src/frontend/shared/ui/theme.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_settings_presentation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_folder_sidebar.dart|apps/desktop/lib/src/frontend/shared/ui/lico_motion.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_mobile_settings_presentation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/components/messaging_search_capsule.dart|apps/desktop/lib/src/frontend/shared/ui/lico_search_capsule.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/presentation/messaging_desktop_destination_presentations.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_foundation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_motion.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart|apps/desktop/lib/src/frontend/shared/ui/lico_radius.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_top_strip.dart|apps/desktop/lib/src/frontend/shared/ui/lico_motion.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/mobile/presentation/messaging_mobile_destination_presentations.dart|apps/desktop/lib/src/frontend/shared/ui/lico_content_spacing.dart",
]);

const legacyLayoutStateImports = new Set([
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_shell.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_column.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart",
]);

const layoutStateStorePath =
  "apps/desktop/lib/src/application/features/layout/layout_state_store.dart";
const settingsSectionCatalogPath =
  "apps/desktop/lib/src/frontend/features/settings/ui/settings_section_catalog.dart";
const legacySettingsCatalogImporters = new Set([
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_folder_sidebar.dart",
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart",
]);
const layoutPaletteProjectionPath =
  "apps/desktop/lib/src/frontend/shell/layout_palette_projection.dart";
const builtInLayoutCompositionPath =
  "apps/desktop/lib/src/application/composition/built_in_layout_composition.dart";
const legacyLayoutTestImports = new Set([
  `apps/desktop/test/layout/profiles/dashboard/desktop/dashboard_desktop_test_harness.dart|${layoutPaletteProjectionPath}`,
  `apps/desktop/test/layout/profiles/dashboard/desktop/dashboard_folder_sidebar_test.dart|${layoutPaletteProjectionPath}`,
  `apps/desktop/test/layout/profiles/messaging/desktop/messaging_desktop_test_harness.dart|${layoutPaletteProjectionPath}`,
  `apps/desktop/test/layout/profiles/messaging/mobile/messaging_mobile_test_harness.dart|${layoutPaletteProjectionPath}`,
  `apps/desktop/test/layout/profiles/messaging/desktop/messaging_desktop_bundle_test.dart|${builtInLayoutCompositionPath}`,
]);
const messagingTokenPath =
  "apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart";
const legacyMessagingTokenImporters = [
  "apps/desktop/lib/src/display/conversation/canonical_group_conversation_pane/header.dart",
  "apps/desktop/lib/src/display/conversation/canonical_group_conversation_pane/pane.dart",
  "apps/desktop/lib/src/display/conversation/canonical_group_conversation_pane/roster.dart",
  "apps/desktop/lib/src/display/conversation/canonical_group_conversation_pane/strategy.dart",
  "apps/desktop/lib/src/display/conversation/canonical_group_conversation_pane/support.dart",
  "apps/desktop/lib/src/frontend/features/agent_hub/ui/agent_hub_panel.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_composer.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane/composition.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_message_group.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_process_status_row.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_quota_ring.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_quota_usage_card.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_scroll_to_latest_button.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart",
  "apps/desktop/lib/src/frontend/features/models/ui/models_panel.dart",
  "apps/desktop/test/agent_conversation_composer_capsules_test.dart",
  "apps/desktop/test/agent_conversation_composer_test.dart",
  "apps/desktop/test/canonical_group_conversation_projection_test.dart",
  "apps/desktop/test/canonical_group_strategy_mode_test.dart",
  "apps/desktop/test/messaging/messaging_contact_list_test.dart",
  "apps/desktop/test/messaging/messaging_conversation_overlay_glass_test.dart",
  "apps/desktop/test/messaging/messaging_participant_flow_test.dart",
  "apps/desktop/test/messaging/messaging_roster_quota_test.dart",
  "apps/desktop/test/messaging/messaging_sidebar_surface_test.dart",
  "apps/desktop/test/messaging/messaging_user_bubble_glass_test.dart",
  "apps/desktop/test/messaging/messaging_workspace_selection_test.dart",
];
const legacyProfilePrivateImports = new Set([
  ...legacyMessagingTokenImporters.map(
    (relativePath) => `${relativePath}|${messagingTokenPath}`,
  ),
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart|apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_column.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart|apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_foundation.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart|apps/desktop/lib/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart",
  "apps/desktop/test/dashboard_desktop_search_interaction_test.dart|apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_search.dart",
]);

export function isAllowedLegacyProfilePrivateImport(importer, imported) {
  return legacyProfilePrivateImports.has(`${importer}|${imported}`);
}

export function isAllowedLegacyLayoutDependency(relativePath) {
  return (
    legacySharedDependencies.has(relativePath) ||
    relativePath === settingsSectionCatalogPath
  );
}

export function isAllowedDestinationPresentationScopePath(relativePath) {
  return destinationPresentationScopeOwners.has(relativePath);
}

export function isDirectNeutralDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/presentation/") ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    NEUTRAL_LAYOUT_CONTRACTS.has(relativePath)
  );
}

export function isNeutralClosureDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/") ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    NEUTRAL_LAYOUT_CONTRACTS.has(relativePath) ||
    relativePath ===
      "apps/desktop/lib/src/application/features/layout/layout_state_store.dart" ||
    relativePath ===
      "apps/desktop/lib/src/application/features/layout/layout_catalog.dart" ||
    relativePath ===
      "apps/desktop/lib/src/application/features/navigation/semantic_destination_catalog.dart"
  );
}

export function forbiddenDependencyCode(relativePath) {
  if (relativePath === settingsSectionCatalogPath) {
    return null;
  }
  if (
    relativePath === layoutStateStorePath ||
    relativePath === "apps/desktop/lib/src/application/features/layout/layout_catalog.dart" ||
    relativePath === "apps/desktop/lib/src/application/features/navigation/semantic_destination_catalog.dart"
  ) {
    return null;
  }
  if (
    relativePath.includes("/application/controller/") ||
    relativePath.endsWith("/client_controller.dart") ||
    relativePath.includes("/controller/") ||
    /(?:^|\/)[A-Za-z0-9_]*controller\.dart$/u.test(relativePath)
  ) {
    return "layout_complete_controller_import";
  }
  if (/controller_scope\.dart$/u.test(relativePath)) {
    return "layout_controller_scope_import";
  }
  if (relativePath.includes("/frontend/layout/chrome/")) {
    return "layout_shared_styled_chrome_import";
  }
  if (relativePath.endsWith("/frontend/shared/ui/theme.dart")) {
    return "layout_concrete_theme_import";
  }
  if (relativePath.includes("/frontend/shared/ui/")) {
    return "layout_shared_styled_import";
  }
  if (relativePath.includes("/frontend/features/")) {
    return "layout_shared_feature_ui_import";
  }
  if (relativePath.includes("/frontend/shell/")) {
    return "layout_shell_implementation_import";
  }
  if (relativePath.includes("/application/")) {
    return "layout_application_import_forbidden";
  }
  if (
    relativePath.includes("/backend/") ||
    relativePath.includes("/platform/")
  ) {
    return "layout_implementation_import";
  }
  return null;
}

export function containsPublicBusinessPortDeclaration(catalog, relativePath, source) {
  const masked = maskCommentsAndStrings(source);
  const isDestinationContract = relativePath.startsWith(
    "apps/desktop/lib/src/contracts/presentation/destinations/",
  );
  if (!isDestinationContract) {
    return false;
  }
  return (
    /\b(?:abstract\s+interface\s+|abstract\s+|base\s+|final\s+|interface\s+|sealed\s+)?class\s+[A-Z][A-Za-z0-9_]*Port\b/u.test(
      masked,
    ) ||
    /\btypedef\s+[A-Z][A-Za-z0-9_]*Port[A-Za-z0-9_]*\b/u.test(masked)
  );
}

export function forbiddenNeutralPortApiCode(source) {
  const masked = maskCommentsAndStrings(source);
  if (/\bClientController\b/u.test(masked)) {
    return "layout_complete_controller_reference";
  }
  if (/\bBuildContext\b/u.test(masked)) {
    return "layout_neutral_build_context_forbidden";
  }
  if (
    /\bWidgetBuilder\b/u.test(masked) ||
    /\b(?:Widget|[A-Z][A-Za-z0-9_]+Widget)\b/u.test(masked)
  ) {
    return "layout_widget_producing_port_forbidden";
  }
  return null;
}

export function containsDestinationPresentationScope(source) {
  return /\bLayoutDestinationPresentationScope\b/u.test(
    maskCommentsAndStrings(source),
  );
}

export function containsCompleteControllerReference(source) {
  return /\bClientController\b/u.test(maskCommentsAndStrings(source));
}

export function importsFlutterWidgetFramework(source) {
  return importsFrom(source).some((specifier) =>
    /^package:flutter\/(?:cupertino|material|widgets)\.dart$/u.test(specifier),
  );
}

export function containsProfileIdentityBranch(source) {
  const masked = maskCommentsAndStrings(source);
  const identity = /\bprofileId\b|\bprofile\.id\b|\bLayoutProfileId\.[A-Za-z_]\w*/u;
  const conditional = /\b(?:if|switch)\s*\(/gu;
  for (const match of masked.matchAll(conditional)) {
    const open = masked.indexOf("(", match.index);
    const close = matchingDelimiter(
      masked,
      open,
      "(",
      ")",
      "layout_profile_identity_branch_unclosed",
    );
    if (identity.test(masked.slice(open + 1, close))) {
      return true;
    }
  }
  return (
    /(?:\bprofileId\b|\bprofile\.id\b)\s*(?:==|!=)|(?:==|!=)\s*(?:\bprofileId\b|\bprofile\.id\b)/u.test(
      masked,
    ) ||
    /\bLayoutProfileId\.[A-Za-z_]\w*\s*(?:==|!=)|(?:==|!=)\s*LayoutProfileId\.[A-Za-z_]\w*/u.test(
      masked,
    ) ||
    /(?:\bprofileId\b|\bprofile\.id\b)[^;\n?]*\?/u.test(masked) ||
    /\bcase\s+LayoutProfileId\.[A-Za-z_]\w*/u.test(masked)
  );
}

export function containsConcreteProfileIdentityBranch(source) {
  const uncommented = stripDartComments(source);
  return (
    (uncommented.includes("LayoutProfileId.parse(") &&
      containsProfileIdentityBranch(source)) ||
    /(?:\bprofileId\b|\bprofile\.id\b)(?:\.value)?\s*(?:==|!=)\s*['"][a-z]+(?:-[a-z]+)*['"]|['"][a-z]+(?:-[a-z]+)*['"]\s*(?:==|!=)\s*(?:\bprofileId\b|\bprofile\.id\b)(?:\.value)?/u.test(
      uncommented,
    )
  );
}

export function validateOwnedDartSource(catalog, relativePath, source) {
  const sourceOwner = sourceOwnerFor(catalog, relativePath);
  const testOwner = testOwnerFor(catalog, relativePath);
  const owner = sourceOwner ?? testOwner;
  if (owner == null) {
    fail("layout_owned_path_ambiguous", relativePath);
  }
  if (sourceOwner != null && containsProfileIdentityBranch(source)) {
    fail("layout_profile_identity_branch_forbidden", relativePath);
  }
  if (
    sourceOwner != null &&
    containsDestinationPresentationScope(source) &&
    !isAllowedDestinationPresentationScopePath(relativePath)
  ) {
    fail("layout_destination_presentation_scope_forbidden", relativePath);
  }
  if (sourceOwner != null && containsCompleteControllerReference(source)) {
    fail("layout_complete_controller_reference", relativePath);
  }
  for (const specifier of importsFrom(source)) {
    if (
      specifier.startsWith("dart:") ||
      specifier.startsWith("package:flutter/") ||
      (testOwner != null &&
        specifier.startsWith("package:flutter_localizations/")) ||
      (testOwner != null && specifier.startsWith("package:flutter_test/"))
    ) {
      continue;
    }
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null) {
      fail("layout_external_import_forbidden", relativePath);
    }
    const importedOwner = codeOwnerFor(catalog, resolved);
    if (importedOwner != null) {
      if (importedOwner.profile !== owner.profile) {
        fail("layout_cross_profile_import", relativePath);
      }
      if (importedOwner.surface !== owner.surface) {
        fail("layout_cross_surface_import", relativePath);
      }
      continue;
    }
    if (
      isDirectNeutralDependency(resolved) ||
      legacySharedUiImports.has(`${relativePath}|${resolved}`) ||
      (resolved === layoutStateStorePath &&
        legacyLayoutStateImports.has(relativePath)) ||
      (resolved === settingsSectionCatalogPath &&
        legacySettingsCatalogImporters.has(relativePath)) ||
      (testOwner != null &&
        legacyLayoutTestImports.has(`${relativePath}|${resolved}`)) ||
      (testOwner != null &&
        (resolved.startsWith(`${catalog.config.profileTestFixtureRoot}/`) ||
          resolved ===
            "apps/desktop/lib/src/frontend/shared/ui/theme.dart"))
    ) {
      continue;
    }
    const forbiddenCode = forbiddenDependencyCode(resolved);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
    if (resolved.includes("/application/")) {
      fail("layout_application_import_forbidden", relativePath);
    }
    fail("layout_import_not_allowlisted", relativePath);
  }
  for (const token of [
    "LayoutRegistry(",
    "registerLayout(",
    "registerLayoutProfile(",
    "built_in_layout_composition",
  ]) {
    if (
      token === "built_in_layout_composition" &&
      relativePath ===
        "apps/desktop/test/layout/profiles/messaging/desktop/messaging_desktop_bundle_test.dart"
    ) {
      continue;
    }
    if (source.includes(token)) {
      fail("layout_mutable_registration_forbidden", relativePath);
    }
  }
}
