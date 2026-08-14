import path from "node:path";

const flutterLibRoot = "apps/desktop/lib";
const flutterSrcRoot = "apps/desktop/lib/src";
const requiredFlutterPhysicalDirs = ["application", "frontend", "backend", "platform", "contracts"];
const allowedFlutterTopLevelDirs = new Set([
  ...requiredFlutterPhysicalDirs
]);
const requiredFrontendFeatureDirs = [
  "agents",
  "mobile_relay",
  "skill_hub",
  "settings",
  "targets"
];
const requiredBackendFeatureDirs = [
  "agents",
  "mobile_relay"
];
const flutterLayerImportRules = [
  {
    root: `${flutterSrcRoot}/application`,
    forbiddenTokens: [
      "package:licoup/src/frontend/"
    ],
    allowedPaths: new Set([
      `${flutterSrcRoot}/application/composition/built_in_layout_composition.dart`
    ]),
    message: "application code must not import frontend renderers outside the explicit layout composition root"
  },
  {
    root: `${flutterSrcRoot}/frontend`,
    forbiddenTokens: [
      "package:licoup/src/backend/",
      "package:licoup/src/platform/"
    ],
    allowedImports: new Map([
      [
        `${flutterSrcRoot}/frontend/features/agents/ui/lico_plan_document_panel.dart`,
        new Set([
          "package:licoup/src/platform/documents/plan_document_reader.dart"
        ])
      ],
      [
        `${flutterSrcRoot}/frontend/features/settings/ui/client_update_settings_card.dart`,
        new Set([
          "package:licoup/src/platform/process/client_process_lifecycle.dart"
        ])
      ]
    ]),
    message: "frontend must depend on application/contracts/l10n, not backend or platform implementations"
  },
  {
    root: `${flutterSrcRoot}/backend`,
    forbiddenTokens: [
      "package:licoup/src/application/",
      "package:licoup/src/frontend/",
      "package:licoup/src/platform/"
    ],
    message: "backend must depend on contracts, not application, frontend, or platform implementation code"
  },
  {
    root: `${flutterSrcRoot}/platform`,
    forbiddenTokens: [
      "package:licoup/src/application/",
      "package:licoup/src/frontend/",
      "package:licoup/src/backend/"
    ],
    message: "platform bridge code must depend on contracts, not application, frontend, or backend implementation code"
  },
  {
    root: `${flutterSrcRoot}/contracts`,
    forbiddenTokens: [
      "package:licoup/src/application/",
      "package:licoup/src/frontend/",
      "package:licoup/src/backend/",
      "package:licoup/src/platform/"
    ],
    message: "contracts must not import implementation layers"
  }
];

const splitTestLibraryRoots = [
  "apps/desktop/test/agents_workspace",
  "apps/desktop/test/fixtures/client_controller",
];
const splitTestLibraryRegistry = new Set([
  "apps/desktop/test/fixtures/client_controller_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/bootstrap_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/conversation_dispatch_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_refresh_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_runtime_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_runtime/message_dispatch_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_runtime/session_selection_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_runtime/streaming_projection_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_runtime/streaming_readback_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/history_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/local_management_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/local_management/conversation_archive_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/local_management/skill_freshness_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/local_management/skill_management_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/local_management/target_management_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/mobile_history_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/preload_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/secure_mesh_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/target_history_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/target_scenarios.dart",
  "apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_dependencies.dart",
  "apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_environment.dart",
  "apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_json.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_job_fixture.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_fixture.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_runtime_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_service.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_state_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_usage_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_mobile_relay_service.dart",
  "apps/desktop/test/fixtures/client_controller/support/no_preload_client_controller.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_interaction_test.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_layout_test.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_renderer_cache_test.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_renderer_collapse_test.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_renderer_process_card_test.dart",
  "apps/desktop/test/agents_workspace/agents_workspace_state_test.dart",
  "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
]);
const agentUsageTimelineRoot =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline";
const agentUsageTimelineFacadePath =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline_data.dart";
const agentUsageTimelineLibraryLeaves = new Set([
  agentUsageTimelineFacadePath,
  `${agentUsageTimelineRoot}/agent_usage_timeline_models.dart`,
  `${agentUsageTimelineRoot}/agent_usage_timeline_builder.dart`,
  `${agentUsageTimelineRoot}/agent_usage_source_parser.dart`,
  `${agentUsageTimelineRoot}/agent_usage_token_breakdown.dart`,
  `${agentUsageTimelineRoot}/agent_usage_display_names.dart`,
  `${agentUsageTimelineRoot}/agent_usage_series_color_policy.dart`,
  `${agentUsageTimelineRoot}/agent_usage_visibility_policy.dart`,
]);

async function enforceFlutterLayerIsolation(context) {
  const {
    assert,
    collectSourceFiles,
    fail,
    lineNumberForToken,
    readText,
  } = context;
  for (const rule of flutterLayerImportRules) {
    let files;
    try {
      files = await collectSourceFiles(rule.root, ".dart");
    } catch (error) {
      fail(`${rule.root} must be readable for Flutter layer isolation: ${error.message}`);
      continue;
    }
    for (const relativePath of files) {
      if (rule.allowedPaths?.has(relativePath)) {
        continue;
      }
      const source = await readText(relativePath);
      const imports = [...source.matchAll(/\bimport\s+['\"]([^'\"]+)['\"]/g)]
        .map((match) => match[1]);
      const allowedImports = rule.allowedImports?.get(relativePath) ?? new Set();
      for (const token of rule.forbiddenTokens) {
        const forbiddenImport = imports.find(
          (candidate) => candidate.includes(token) && !allowedImports.has(candidate)
        );
        assert(
          forbiddenImport === undefined,
          `${relativePath}:${lineNumberForToken(source, forbiddenImport ?? token)} ${rule.message}; forbidden import token ${forbiddenImport ?? token}`
        );
      }
    }
  }
}


async function enforceNormalDartLibraries(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  for (const relativePath of await collectDartSourceFiles()) {
    const source = await readText(relativePath);
    const legacyDirective = source.match(/^[ \t]*part[ \t]+(?:of[ \t]+)?/m);
    assert(
      legacyDirective === null,
      `${relativePath}:${legacyDirective ? lineNumberForToken(source, legacyDirective[0].trim()) : 1} Flutter modules must use independently importable libraries instead of part directives`
    );
  }
}


async function enforceSplitTestLibraries(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const testFiles = ["apps/desktop/test/fixtures/client_controller_scenarios.dart"];
  for (const root of splitTestLibraryRoots) {
    testFiles.push(...await collectSourceFiles(root, ".dart"));
  }
  for (const relativePath of testFiles) {
    const source = await readText(relativePath);
    const legacyDirective = source.match(/^[ \t]*part[ \t]+(?:of[ \t]+)?/m);
    assert(
      legacyDirective === null,
      `${relativePath}:${legacyDirective ? lineNumberForToken(source, legacyDirective[0].trim()) : 1} split test libraries must remain independently importable without part directives`
    );
    assert(
      splitTestLibraryRegistry.has(relativePath),
      `${relativePath} must be registered in the split-test library registry`
    );
  }
  for (const relativePath of splitTestLibraryRegistry) {
    assert(testFiles.includes(relativePath), `${relativePath} split-test registry must name a current library`);
  }
  for (const retiredPath of [
    "apps/desktop/test/agents_workspace_layout_test.dart",
    "apps/desktop/test/agents_workspace/agents_workspace_renderer_test.dart",
    "apps/desktop/test/client_target_history_test.dart",
    "apps/desktop/test/client_history_test.dart",
  ]) {
    assert(!await exists(retiredPath), `${retiredPath} retired aggregate test must stay removed`);
  }
}

async function enforceAgentUsageTimelineLibraries(context) {
  const {
    assert,
    collectSourceFiles,
    readText,
    sameSet,
  } = context;
  const leafPaths = [...agentUsageTimelineLibraryLeaves]
    .filter((relativePath) => relativePath !== agentUsageTimelineFacadePath);
  const discoveredLeaves = await collectSourceFiles(agentUsageTimelineRoot, ".dart");
  assert(
    sameSet(discoveredLeaves, leafPaths),
    "agent usage timeline leaves must exactly match the architecture-owned responsibility set"
  );
  for (const relativePath of agentUsageTimelineLibraryLeaves) {
    const source = await readText(relativePath);
    assert(
      !/^[ \t]*part[ \t]+(?:of[ \t]+)?/m.test(source),
      `${relativePath} must remain an independently importable library without part directives`
    );
    if (relativePath !== agentUsageTimelineFacadePath) {
      assert(
        !source.includes("agent_usage_timeline_data.dart"),
        `${relativePath} must not depend back on the timeline facade`
      );
    }
  }
  const facade = await readText(agentUsageTimelineFacadePath);
  assert(
    !/^import /m.test(facade) &&
      !/^(?:class|enum|typedef|mixin|extension) /m.test(facade) &&
      [...facade.matchAll(/^export /gm)].length === leafPaths.length,
    "agent usage timeline root must remain a thin seven-leaf export facade"
  );
  const builder = await readText(
    `${agentUsageTimelineRoot}/agent_usage_timeline_builder.dart`
  );
  assert(
    builder.includes("const int agentUsageTimelineDayCount = 30;") &&
      builder.includes("AgentUsageChartGrouping.agent") &&
      builder.includes("AgentUsageChartGrouping.model"),
    "agent usage timeline builder must preserve the 30-day agent/model contract"
  );
}


async function findFlutterDependencyCycle(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const files = await collectDartSourceFiles();
  const knownFiles = new Set(files);
  const graph = new Map(files.map((relativePath) => [relativePath, []]));
  const directivePattern = /^\s*(?:import|export|part)\s+['"]([^'"]+)['"]/gm;

  for (const relativePath of files) {
    const source = await readText(relativePath);
    for (const match of source.matchAll(directivePattern)) {
      const specifier = match[1];
      let dependency = null;
      if (specifier.startsWith("package:licoup/")) {
        dependency = `${flutterLibRoot}/${specifier.slice("package:licoup/".length)}`;
      } else if (!specifier.includes(":")) {
        dependency = path.posix.normalize(
          path.posix.join(path.posix.dirname(relativePath), specifier)
        );
      }
      if (dependency && knownFiles.has(dependency)) {
        graph.get(relativePath).push(dependency);
      }
    }
  }

  const visited = new Set();
  const visiting = new Set();
  const stack = [];

  function visit(relativePath) {
    if (visiting.has(relativePath)) {
      const cycleStart = stack.lastIndexOf(relativePath);
      return [...stack.slice(cycleStart), relativePath];
    }
    if (visited.has(relativePath)) {
      return null;
    }
    visiting.add(relativePath);
    stack.push(relativePath);
    for (const dependency of graph.get(relativePath)) {
      const cycle = visit(dependency);
      if (cycle) {
        return cycle;
      }
    }
    stack.pop();
    visiting.delete(relativePath);
    visited.add(relativePath);
    return null;
  }

  for (const relativePath of files) {
    const cycle = visit(relativePath);
    if (cycle) {
      return cycle;
    }
  }
  return null;
}

export async function checkFlutterPhysicalLayersAndLibraries(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const flutterTopLevelDirs = await readImmediateDirectoryNames(flutterSrcRoot);
  for (const requiredDir of requiredFlutterPhysicalDirs) {
    assert(
      flutterTopLevelDirs.includes(requiredDir),
      `${flutterSrcRoot}/${requiredDir} must exist for hard frontend/backend/platform architecture`
    );
  }
  for (const topLevelDir of flutterTopLevelDirs) {
    assert(
      allowedFlutterTopLevelDirs.has(topLevelDir),
      `${flutterSrcRoot}/${topLevelDir} is not an allowed top-level Flutter source directory`
    );
  }
  const flutterFrontendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/frontend/features`);
  for (const featureDir of requiredFrontendFeatureDirs) {
    assert(
      flutterFrontendFeatureDirs.includes(featureDir),
      `${flutterSrcRoot}/frontend/features/${featureDir} must exist as a frontend feature directory`
    );
  }
  const flutterBackendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/backend/features`);
  for (const featureDir of requiredBackendFeatureDirs) {
    assert(
      flutterBackendFeatureDirs.includes(featureDir),
      `${flutterSrcRoot}/backend/features/${featureDir} must exist as a backend feature directory`
    );
  }
  await enforceFlutterLayerIsolation(context);
  await enforceNormalDartLibraries(context);
  await enforceSplitTestLibraries(context);
  await enforceAgentUsageTimelineLibraries(context);
  const dashboardChromeFacadePath =
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_chrome.dart";
  const dashboardChromeLeaves = [
    "dashboard_desktop_search.dart",
    "dashboard_folder_sidebar.dart"
  ];
  const dashboardChromeRoot = path.posix.dirname(dashboardChromeFacadePath);
  const dashboardChromeFacadeSource = await readText(dashboardChromeFacadePath);
  const dashboardChromeExports = [...dashboardChromeFacadeSource.matchAll(
    /^export '([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(dashboardChromeExports, dashboardChromeLeaves) &&
      !/^import /mu.test(dashboardChromeFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(dashboardChromeFacadeSource),
    "Dashboard desktop chrome root must remain an exact two-leaf export facade"
  );
  const dashboardChromeSources = {};
  for (const leaf of dashboardChromeLeaves) {
    const source = await readText(`${dashboardChromeRoot}/${leaf}`);
    dashboardChromeSources[leaf] = source;
    assert(
      !/^[ \t]*part[ \t]+(?:of[ \t]+)?/mu.test(source) &&
        !source.includes("dashboard_desktop_chrome.dart"),
      `${leaf} must remain an ordinary library without reverse facade coupling`
    );
  }
  assert(
    dashboardChromeSources["dashboard_desktop_search.dart"].includes("Autocomplete<_DashboardSearchItem>") &&
      dashboardChromeSources["dashboard_folder_sidebar.dart"].includes("DashboardDesktopSearch") &&
      dashboardChromeSources["dashboard_folder_sidebar.dart"].includes("DashboardFolderSidebar"),
    "Dashboard folder sidebar and search leaves must retain separate interaction ownership"
  );
  const conversationPaneFacadePath =
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane.dart";
  const conversationPaneLeaves = [
    "actions.dart",
    "composition.dart",
    "header.dart",
    "resize.dart"
  ];
  const conversationPaneRoot = conversationPaneFacadePath.replace(/\.dart$/u, "");
  const conversationPaneFacadeSource = await readText(conversationPaneFacadePath);
  const conversationPaneExports = [...conversationPaneFacadeSource.matchAll(
    /^export 'agent_conversation_pane\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(conversationPaneExports, conversationPaneLeaves) &&
      conversationPaneFacadeSource.includes("export 'agent_conversation_pane_presentation.dart';") &&
      !/^import /mu.test(conversationPaneFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(conversationPaneFacadeSource),
    "agent conversation pane root must remain an exact four-leaf export facade"
  );
  const conversationPaneSources = {};
  const conversationPaneLeafPaths = new Set(
    conversationPaneLeaves.map((leaf) => `${conversationPaneRoot}/${leaf}`)
  );
  const resolveConversationPaneImport = (from, specifier) => {
    if (specifier.startsWith("package:licoup/")) {
      return path.posix.join(
        "apps/desktop/lib",
        specifier.slice("package:licoup/".length)
      );
    }
    return specifier.startsWith(".")
      ? path.posix.normalize(path.posix.join(path.posix.dirname(from), specifier))
      : null;
  };
  const conversationPaneImportGraph = new Map();
  for (const leaf of conversationPaneLeaves) {
    const leafPath = `${conversationPaneRoot}/${leaf}`;
    const source = await readText(leafPath);
    conversationPaneSources[leaf] = source;
    const crossLeafImports = [...source.matchAll(
      /^\s*import\s+['"]([^'"]+)['"][^;]*;/gmu
    )]
      .map((match) => resolveConversationPaneImport(leafPath, match[1]))
      .filter((target) => conversationPaneLeafPaths.has(target));
    conversationPaneImportGraph.set(leafPath, crossLeafImports);
    assert(
      !/^[ \t]*part[ \t]+(?:of[ \t]+)?/mu.test(source) &&
        !source.includes("agent_conversation_pane.dart") &&
        !source.includes("ClientController"),
      `${leaf} must remain a pane library without reverse facade coupling`
    );
  }
  assert(
    [...conversationPaneImportGraph.values()].every((targets) => targets.length === 0) &&
      conversationPaneSources["composition.dart"].includes("AgentConversationPaneState") &&
      conversationPaneSources["composition.dart"].includes("AgentConversationPaneActions") &&
      conversationPaneSources["actions.dart"].includes("ArchiveAgentConversationsButton") &&
      conversationPaneSources["resize.dart"].includes("PaneEdgeDragHandle") &&
      conversationPaneSources["header.dart"].includes("AgentConversationHeaderState") &&
      !(await exists(`${conversationPaneRoot}/recent_sessions.dart`)),
    "conversation pane leaves must have zero cross-leaf imports, zero ClientController access, and no hidden recent-sessions leaf"
  );
  const messageBlocksFacadePath =
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart";
  const messageBlocksLeaves = [
    "disclosures.dart",
    "dispatcher.dart",
    "role_blocks.dart",
    "subagent.dart"
  ];
  const messageBlocksRoot = messageBlocksFacadePath.replace(/\.dart$/u, "");
  const messageBlocksFacadeSource = await readText(messageBlocksFacadePath);
  const messageBlocksExports = [...messageBlocksFacadeSource.matchAll(
    /^export 'agent_conversation_message_blocks\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(messageBlocksExports, messageBlocksLeaves) &&
      !/^import /mu.test(messageBlocksFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(messageBlocksFacadeSource),
    "agent conversation message blocks root must remain an exact four-leaf export facade"
  );
  const messageBlocksSources = {};
  for (const leaf of messageBlocksLeaves) {
    const source = await readText(`${messageBlocksRoot}/${leaf}`);
    messageBlocksSources[leaf] = source;
    assert(
      !/^[ \t]*part[ \t]+(?:of[ \t]+)?/mu.test(source) &&
        !source.includes("agent_conversation_message_blocks.dart"),
      `${leaf} must remain a message block library without reverse facade coupling`
    );
  }
  assert(
    messageBlocksSources["dispatcher.dart"].includes("AgentConversationMessageKind.user") &&
      messageBlocksSources["dispatcher.dart"].includes("AgentConversationSubagentCardBlock") &&
      messageBlocksSources["disclosures.dart"].includes("splitMessageDisplayBlocks(data)") &&
      messageBlocksSources["disclosures.dart"].includes("_RecommendedPluginsDisclosure") &&
      messageBlocksSources["role_blocks.dart"].includes("AgentConversationUserMessageBlock") &&
      messageBlocksSources["role_blocks.dart"].includes("AgentConversationAssistantDocumentBlock") &&
      messageBlocksSources["subagent.dart"].includes("conversationMessagePreviewText") &&
      messageBlocksSources["subagent.dart"].includes("widget.message.childMessages"),
    "message block dispatcher, disclosures, role, and subagent leaves must retain separate ownership"
  );
  const mobileRelayPanelFacadePath =
    "apps/desktop/lib/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart";
  const mobileRelayPanelLeaves = [
    "composition.dart",
    "pairing.dart",
    "qr.dart",
    "scan.dart",
    "trust.dart"
  ];
  const mobileRelayPanelRoot = mobileRelayPanelFacadePath.replace(/\.dart$/u, "");
  const mobileRelayPanelFacadeSource = await readText(mobileRelayPanelFacadePath);
  const mobileRelayPanelExports = [...mobileRelayPanelFacadeSource.matchAll(
    /^export 'mobile_relay_panel\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(mobileRelayPanelExports, mobileRelayPanelLeaves) &&
      !/^import /mu.test(mobileRelayPanelFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(mobileRelayPanelFacadeSource),
    "mobile relay panel root must remain an exact five-leaf export facade"
  );
  const mobileRelayPanelSources = {};
  for (const leaf of mobileRelayPanelLeaves) {
    const source = await readText(`${mobileRelayPanelRoot}/${leaf}`);
    mobileRelayPanelSources[leaf] = source;
    assert(
      !/^[ \t]*part[ \t]+(?:of[ \t]+)?/mu.test(source) &&
        !source.includes("mobile_relay_panel.dart"),
      `${leaf} must remain a Mobile Relay panel library without reverse facade coupling`
    );
  }
  assert(
    mobileRelayPanelSources["composition.dart"].includes("MobileRelayPairingWorkspaceCard") &&
      mobileRelayPanelSources["composition.dart"].includes("MobileRelayScanPairingPrompt") &&
      mobileRelayPanelSources["composition.dart"].includes("MobileRelayTrustVerificationCard") &&
      mobileRelayPanelSources["pairing.dart"].includes("mobile_relay_panel/qr.dart") &&
      mobileRelayPanelSources["pairing.dart"].includes("configureMobileRelayStation") &&
      mobileRelayPanelSources["qr.dart"].includes("MobileRelayPairingQrFrame") &&
      mobileRelayPanelSources["scan.dart"].includes("MobileRelayScanPairingPrompt") &&
      mobileRelayPanelSources["trust.dart"].includes("MobileRelayTrustVerificationCard") &&
      !mobileRelayPanelSources["qr.dart"].includes("ClientController") &&
      !mobileRelayPanelSources["scan.dart"].includes("ClientController") &&
      !mobileRelayPanelSources["trust.dart"].includes("ClientController"),
    "Mobile Relay composition, pairing, QR, scan, and trust leaves must retain separate ownership"
  );
  const flutterDependencyCycle = await findFlutterDependencyCycle(context);
  assert(
    flutterDependencyCycle === null,
    `Flutter source imports must form an acyclic dependency graph: ${(flutterDependencyCycle || []).join(" -> ")}`
  );

  return { mobileRelayPanelFacadeSource, mobileRelayPanelSources };
}
