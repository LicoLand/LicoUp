const appRoot = "apps/desktop/lib";
const srcRoot = `${appRoot}/src`;
const transitionPath =
  `${srcRoot}/composition/m2_legacy_shell_renderer_transition_adapter.dart`;

const requiredDirectories = Object.freeze([
  "packages/presentation_contract/lib",
  `${srcRoot}/presentation/shell`,
  `${srcRoot}/projections/adapters`,
  `${srcRoot}/projections/shell`,
  `${srcRoot}/frontend/binding`,
  `${srcRoot}/frontend/shell`,
  `${srcRoot}/composition`,
]);

const legacyFrontendControllerImporters = new Set([
  `${srcRoot}/frontend/features/agents/ui/adaptive_flywheel_dialog.dart`,
  `${srcRoot}/frontend/features/agents/ui/agent_conversation_search_palette.dart`,
  `${srcRoot}/frontend/features/agents/ui/agent_conversation_workspace.dart`,
  `${srcRoot}/frontend/features/agents/ui/agent_usage_panel.dart`,
  `${srcRoot}/frontend/features/agents/ui/agents_canvas.dart`,
  `${srcRoot}/frontend/features/agents/ui/conversation_archive_dialog.dart`,
  `${srcRoot}/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart`,
  `${srcRoot}/frontend/features/agents/ui/messaging/messaging_notification_bell.dart`,
  `${srcRoot}/frontend/features/agents/ui/mobile_widgets_page.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_agent_list.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_agents_home.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_desktop_agent_list.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_local_agent.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_relay_panel/composition.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/mobile_relay_panel/pairing.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart`,
  `${srcRoot}/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart`,
  `${srcRoot}/frontend/features/models/ui/models_panel.dart`,
  `${srcRoot}/frontend/features/plugin_management/ui/adapter_plugin_panel.dart`,
  `${srcRoot}/frontend/features/settings/ui/client_update_settings_card.dart`,
  `${srcRoot}/frontend/features/settings/ui/settings_log_export_tile.dart`,
  `${srcRoot}/frontend/features/settings/ui/settings_panel.dart`,
  `${srcRoot}/frontend/features/settings/ui/startup_autostart_card.dart`,
  `${srcRoot}/frontend/features/skill_hub/ui/skill_hub_panel.dart`,
  `${srcRoot}/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart`,
  `${srcRoot}/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart`,
  `${srcRoot}/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart`,
]);

function importsClientController(source) {
  return /\bimport\s+['"][^'"]*client_controller\.dart['"]/u.test(source);
}

export function inspectPresentationBoundarySources(sourceByPath) {
  const failures = [];
  const stablePaths = [...sourceByPath.keys()].filter((relativePath) =>
    relativePath === `${appRoot}/app.dart` ||
    relativePath.startsWith(`${srcRoot}/presentation/`) ||
    relativePath.startsWith(`${srcRoot}/projections/adapters/`) ||
    relativePath.startsWith(`${srcRoot}/projections/shell/`) ||
    relativePath.startsWith(`${srcRoot}/frontend/binding/`) ||
    relativePath.startsWith(`${srcRoot}/frontend/shell/`));
  for (const relativePath of stablePaths) {
    const source = sourceByPath.get(relativePath) ?? "";
    if (/\bClientController\b/u.test(source)) {
      failures.push(["presentation_boundary_complete_controller_forbidden", relativePath]);
    }
    if (source.includes("m2_legacy_shell_renderer_transition_adapter.dart")) {
      failures.push(["presentation_boundary_transition_import_forbidden", relativePath]);
    }
  }
  for (const [relativePath, source] of sourceByPath) {
    if (!relativePath.startsWith(`${srcRoot}/presentation/`)) continue;
    if (/package:licoup\/src\/(?:application|backend|platform|composition|frontend|projections)\//u.test(source)) {
      failures.push(["presentation_boundary_stable_direction", relativePath]);
    }
    if (/\bStreamController\b|\b(?:void|Future<void>)\s+dispose\s*\(/u.test(source)) {
      failures.push(["presentation_boundary_producer_lifecycle_forbidden", relativePath]);
    }
  }
  for (const [relativePath, source] of sourceByPath) {
    if (!relativePath.startsWith(`${srcRoot}/frontend/`) || !importsClientController(source)) {
      continue;
    }
    if (!legacyFrontendControllerImporters.has(relativePath)) {
      failures.push(["presentation_boundary_new_controller_debt", relativePath]);
    }
  }
  return failures;
}

export function inspectPresentationContractPubspec(source) {
  return /^(?:dependencies|dependency_overrides):/mu.test(source)
    ? ["presentation_boundary_package_dependency_surface"]
    : [];
}

export async function checkPresentationBoundary(context) {
  const { assert, collectSourceFiles, exists, readText } = context;
  for (const relativePath of requiredDirectories) {
    assert(
      await exists(relativePath),
      `[presentation_boundary_required_directory] ${relativePath} must exist`,
    );
  }

  const packageSources = await collectSourceFiles(
    "packages/presentation_contract/lib",
    ".dart",
  );
  for (const relativePath of packageSources) {
    const source = await readText(relativePath);
    assert(
      !/\b(?:import|export)\s+['"]package:/u.test(source),
      `[presentation_boundary_package_purity] ${relativePath} must remain SDK-only`,
    );
    assert(
      !/\b(?:Widget|BuildContext|ClientController|dispose|close|revision)\b/u.test(source),
      `[presentation_boundary_package_surface] ${relativePath} leaks renderer, lifecycle, implementation, or revision API`,
    );
  }
  const contractPubspecPath = "packages/presentation_contract/pubspec.yaml";
  const contractPubspec = await readText(contractPubspecPath);
  for (const rule of inspectPresentationContractPubspec(contractPubspec)) {
    assert(false, `[${rule}] ${contractPubspecPath} must not declare production dependencies`);
  }

  const dartPaths = await context.collectDartSourceFiles();
  const sourceByPath = new Map(
    await Promise.all(
      dartPaths.map(async (relativePath) => [relativePath, await readText(relativePath)]),
    ),
  );
  for (const [rule, relativePath] of inspectPresentationBoundarySources(sourceByPath)) {
    assert(false, `[${rule}] ${relativePath}`);
  }

  assert(
    await exists(transitionPath),
    `[presentation_boundary_transition_missing] ${transitionPath} must exist`,
  );
  const transitionSource = await readText(transitionPath);
  for (const destination of [
    "agents",
    "monitoring",
    "skillHub",
    "pluginManagement",
    "mobileRelay",
    "models",
    "settings",
    "agentHub",
  ]) {
    assert(
      transitionSource.includes(`ClientSection.${destination} =>`),
      `[presentation_boundary_transition_destination] ${transitionPath} must cover ClientSection.${destination}`,
    );
  }
  assert(
    transitionSource.includes("OpenShellAgent(agentId)") &&
      !transitionSource.includes("selectConversationAgent("),
    `[presentation_boundary_open_agent_intent] ${transitionPath} must route Agent Hub selection through ShellIntent`,
  );
  assert(
    !transitionSource.includes("_controller.addListener"),
    `[presentation_boundary_root_controller_listener] ${transitionPath} must consume focused shell projections instead of the root controller notifier`,
  );

  const shellSource = await readText(`${srcRoot}/frontend/shell/client_shell.dart`);
  assert(
    /required this\.binding/u.test(shellSource) && /final ShellBinding binding;/u.test(shellSource),
    `[presentation_boundary_shell_binding] ClientShell must accept ShellBinding`,
  );
  assert(
    !/\bAnimatedBuilder\b/u.test(shellSource),
    `[presentation_boundary_root_rebuild] ClientShell must not restore a root AnimatedBuilder`,
  );
}
