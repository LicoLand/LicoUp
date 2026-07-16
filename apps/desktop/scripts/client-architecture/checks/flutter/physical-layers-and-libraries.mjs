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
      "package:flutter_client/src/frontend/"
    ],
    allowedPaths: new Set([
      `${flutterSrcRoot}/application/composition/built_in_layout_composition.dart`
    ]),
    message: "application code must not import frontend renderers outside the explicit layout composition root"
  },
  {
    root: `${flutterSrcRoot}/frontend`,
    forbiddenTokens: [
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "frontend must depend on application/contracts/l10n, not backend or platform implementations"
  },
  {
    root: `${flutterSrcRoot}/backend`,
    forbiddenTokens: [
      "package:flutter_client/src/application/",
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/platform/"
    ],
    message: "backend must depend on contracts, not application, frontend, or platform implementation code"
  },
  {
    root: `${flutterSrcRoot}/platform`,
    forbiddenTokens: [
      "package:flutter_client/src/application/",
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/"
    ],
    message: "platform bridge code must depend on contracts, not application, frontend, or backend implementation code"
  },
  {
    root: `${flutterSrcRoot}/contracts`,
    forbiddenTokens: [
      "package:flutter_client/src/application/",
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "contracts must not import implementation layers"
  }
];

const splitTestLibraryRoots = [
  "apps/desktop/test/agents_workspace",
  "apps/desktop/test/distillation",
  "apps/desktop/test/fixtures/client_controller",
];
const splitTestLibraryLineLimits = new Map([
  ["apps/desktop/test/fixtures/client_controller_scenarios.dart", 40],
  ["apps/desktop/test/fixtures/client_controller/bootstrap_scenarios.dart", 520],
  ["apps/desktop/test/fixtures/client_controller/conversation_dispatch_scenarios.dart", 650],
  ["apps/desktop/test/fixtures/client_controller/conversation_orchestration_scenarios.dart", 380],
  ["apps/desktop/test/fixtures/client_controller/history_refresh_scenarios.dart", 470],
  ["apps/desktop/test/fixtures/client_controller/history_runtime_scenarios.dart", 280],
  ["apps/desktop/test/fixtures/client_controller/history_scenarios.dart", 30],
  ["apps/desktop/test/fixtures/client_controller/local_management_scenarios.dart", 20],
  ["apps/desktop/test/fixtures/client_controller/local_management/conversation_archive_scenarios.dart", 250],
  ["apps/desktop/test/fixtures/client_controller/local_management/skill_management_scenarios.dart", 100],
  ["apps/desktop/test/fixtures/client_controller/local_management/target_management_scenarios.dart", 110],
  ["apps/desktop/test/fixtures/client_controller/mobile_history_scenarios.dart", 300],
  ["apps/desktop/test/fixtures/client_controller/routing_scenarios.dart", 550],
  ["apps/desktop/test/fixtures/client_controller/secure_mesh_scenarios.dart", 680],
  ["apps/desktop/test/fixtures/client_controller/target_history_scenarios.dart", 30],
  ["apps/desktop/test/fixtures/client_controller/target_scenarios.dart", 240],
  ["apps/desktop/test/fixtures/client_controller/support/client_controller_routing_harness.dart", 100],
  ["apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_dependencies.dart", 50],
  ["apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_environment.dart", 50],
  ["apps/desktop/test/fixtures/client_controller/support/client_controller_scenario_json.dart", 120],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_job_fixture.dart", 140],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_support.dart", 310],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_fixture.dart", 50],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_support.dart", 280],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_service.dart", 60],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_state_support.dart", 380],
  ["apps/desktop/test/fixtures/client_controller/support/fake_agent_usage_support.dart", 90],
  ["apps/desktop/test/fixtures/client_controller/support/fake_mobile_relay_service.dart", 700],
  ["apps/desktop/test/agents_workspace/agents_workspace_interaction_test.dart", 400],
  ["apps/desktop/test/agents_workspace/agents_workspace_layout_test.dart", 420],
  ["apps/desktop/test/agents_workspace/agents_workspace_renderer_cache_test.dart", 140],
  ["apps/desktop/test/agents_workspace/agents_workspace_renderer_collapse_test.dart", 340],
  ["apps/desktop/test/agents_workspace/agents_workspace_renderer_process_card_test.dart", 530],
  ["apps/desktop/test/agents_workspace/agents_workspace_state_test.dart", 260],
  ["apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart", 60],
  ["apps/desktop/test/distillation/distillation_broker_audit_test.dart", 55],
  ["apps/desktop/test/distillation/distillation_broker_dispatch_test.dart", 90],
  ["apps/desktop/test/distillation/distillation_broker_failure_projection_test.dart", 80],
  ["apps/desktop/test/distillation/distillation_broker_fidelity_retry_test.dart", 100],
  ["apps/desktop/test/distillation/distillation_broker_usage_test.dart", 70],
  ["apps/desktop/test/distillation/distillation_fidelity_reducer_test.dart", 120],
  ["apps/desktop/test/distillation/distillation_input_window_test.dart", 75],
  ["apps/desktop/test/distillation/distillation_lane_contract_test.dart", 75],
  ["apps/desktop/test/distillation/distillation_package_models_test.dart", 70],
  ["apps/desktop/test/distillation/distillation_response_parser_test.dart", 75],
  ["apps/desktop/test/distillation/distillation_result_models_test.dart", 60],
  ["apps/desktop/test/distillation/distillation_semantics_test.dart", 55],
  ["apps/desktop/test/distillation/distillation_source_content_classes_test.dart", 50],
  ["apps/desktop/test/distillation/distillation_usage_audit_test.dart", 75],
  ["apps/desktop/test/distillation/distillation_utf8_test.dart", 30],
  ["apps/desktop/test/distillation/support/distillation_broker_harness.dart", 120],
]);
const agentUsageTimelineRoot =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline";
const agentUsageTimelineFacadePath =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline_data.dart";
const agentUsageTimelineLibraryLineLimits = new Map([
  [agentUsageTimelineFacadePath, 30],
  [`${agentUsageTimelineRoot}/agent_usage_timeline_models.dart`, 90],
  [`${agentUsageTimelineRoot}/agent_usage_timeline_builder.dart`, 260],
  [`${agentUsageTimelineRoot}/agent_usage_source_parser.dart`, 190],
  [`${agentUsageTimelineRoot}/agent_usage_token_breakdown.dart`, 290],
  [`${agentUsageTimelineRoot}/agent_usage_display_names.dart`, 190],
  [`${agentUsageTimelineRoot}/agent_usage_series_color_policy.dart`, 100],
  [`${agentUsageTimelineRoot}/agent_usage_visibility_policy.dart`, 50],
]);
const distillationContractRoot =
  "apps/desktop/lib/src/contracts/routing/distillation";
const distillationContractFacadePath =
  "apps/desktop/lib/src/contracts/routing/distillation_package.dart";
const distillationContractLibraryLineLimits = new Map([
  [`${distillationContractRoot}/distillation_package_models.dart`, 130],
  [`${distillationContractRoot}/distillation_usage_audit.dart`, 100],
  [`${distillationContractRoot}/distillation_result_models.dart`, 60],
  [`${distillationContractRoot}/distillation_semantics.dart`, 180],
  [`${distillationContractRoot}/distillation_utf8.dart`, 30],
  [`${distillationContractRoot}/distillation_input_window.dart`, 170],
  [`${distillationContractRoot}/distillation_source_content_classes.dart`, 90],
  [`${distillationContractRoot}/distillation_fidelity_reducer.dart`, 140],
  [`${distillationContractRoot}/distillation_lane_contract.dart`, 120],
  [`${distillationContractRoot}/distillation_response_parser.dart`, 80],
]);
const distillationContractDependencies = new Map([
  ["distillation_package_models.dart", []],
  ["distillation_usage_audit.dart", ["distillation_package_models.dart"]],
  ["distillation_result_models.dart", [
    "distillation_package_models.dart",
    "distillation_usage_audit.dart",
  ]],
  ["distillation_semantics.dart", []],
  ["distillation_utf8.dart", []],
  ["distillation_input_window.dart", [
    "distillation_semantics.dart",
    "distillation_utf8.dart",
  ]],
  ["distillation_source_content_classes.dart", [
    "distillation_input_window.dart",
    "distillation_semantics.dart",
  ]],
  ["distillation_fidelity_reducer.dart", [
    "distillation_package_models.dart",
    "distillation_semantics.dart",
    "distillation_source_content_classes.dart",
  ]],
  ["distillation_lane_contract.dart", [
    "distillation_input_window.dart",
    "distillation_result_models.dart",
    "distillation_source_content_classes.dart",
    "distillation_usage_audit.dart",
  ]],
  ["distillation_response_parser.dart", ["distillation_package_models.dart"]],
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
      for (const token of rule.forbiddenTokens) {
        assert(
          !source.includes(token),
          `${relativePath}:${lineNumberForToken(source, token)} ${rule.message}; forbidden import token ${token}`
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
    sourceLineCount,
  } = context;
  for (const relativePath of await collectDartSourceFiles()) {
    const source = await readText(relativePath);
    const legacyDirective = source.match(/^\s*part(?:\s+of)?\b/m);
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
    sourceLineCount,
  } = context;
  const testFiles = ["apps/desktop/test/fixtures/client_controller_scenarios.dart"];
  for (const root of splitTestLibraryRoots) {
    testFiles.push(...await collectSourceFiles(root, ".dart"));
  }
  for (const relativePath of testFiles) {
    const source = await readText(relativePath);
    const legacyDirective = source.match(/^\s*part(?:\s+of)?\b/m);
    assert(
      legacyDirective === null,
      `${relativePath}:${legacyDirective ? lineNumberForToken(source, legacyDirective[0].trim()) : 1} split test libraries must remain independently importable without part directives`
    );
    const maxLines = splitTestLibraryLineLimits.get(relativePath);
    assert(maxLines !== undefined, `${relativePath} must have an explicit split-test line limit`);
    if (maxLines !== undefined) {
      assert(
        sourceLineCount(source) <= maxLines,
        `${relativePath} exceeds its focused test-library limit (${maxLines} lines maximum)`
      );
    }
  }
  for (const relativePath of splitTestLibraryLineLimits.keys()) {
    assert(testFiles.includes(relativePath), `${relativePath} split-test limit must name a current library`);
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
    sourceLineCount,
  } = context;
  const leafPaths = [...agentUsageTimelineLibraryLineLimits.keys()]
    .filter((relativePath) => relativePath !== agentUsageTimelineFacadePath);
  const discoveredLeaves = await collectSourceFiles(agentUsageTimelineRoot, ".dart");
  assert(
    sameSet(discoveredLeaves, leafPaths),
    "agent usage timeline leaves must exactly match the architecture-owned responsibility set"
  );
  for (const [relativePath, maxLines] of agentUsageTimelineLibraryLineLimits) {
    const source = await readText(relativePath);
    assert(
      !/^\s*part(?:\s+of)?\b/m.test(source),
      `${relativePath} must remain an independently importable library without part directives`
    );
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its agent-usage responsibility limit (${maxLines} lines maximum)`
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


async function enforceDistillationContractLibraries(context) {
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
    sourceLineCount,
  } = context;
  const leafPaths = [...distillationContractLibraryLineLimits.keys()];
  const discoveredLeaves = await collectSourceFiles(
    distillationContractRoot,
    ".dart"
  );
  assert(
    sameSet(discoveredLeaves, leafPaths),
    "distillation contract leaves must exactly match the architecture-owned responsibility set"
  );

  for (const [relativePath, maxLines] of distillationContractLibraryLineLimits) {
    const source = await readText(relativePath);
    const basename = path.basename(relativePath);
    assert(
      !/^\s*part(?:\s+of)?\b/m.test(source),
      `${relativePath} must remain an independently importable library without part directives`
    );
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its distillation responsibility limit (${maxLines} lines maximum)`
    );
    assert(
      !source.includes("distillation_package.dart"),
      `${relativePath} must not depend back on the distillation facade`
    );

    const localImports = [...source.matchAll(/^import '([^']+\.dart)';$/gm)]
      .map((match) => path.posix.basename(match[1]))
      .filter((dependency) => dependency.startsWith("distillation_"))
      .sort();
    const allowedImports = [...(distillationContractDependencies.get(basename) || [])]
      .sort();
    assert(
      sameSet(localImports, allowedImports),
      `${relativePath} must preserve its one-way distillation dependency contract`
    );

    const testPath = `apps/desktop/test/distillation/${basename.replace(/\.dart$/u, "_test.dart")}`;
    assert(
      await exists(testPath),
      `${relativePath} must retain its dedicated leaf regression test`
    );
    if (await exists(testPath)) {
      const testSource = await readText(testPath);
      assert(
        testSource.includes(`/distillation/${basename}';`) &&
          !testSource.includes("distillation_package.dart"),
        `${testPath} must validate its leaf directly without the aggregate facade`
      );
    }
  }

  const facade = await readText(distillationContractFacadePath);
  const exportedLeaves = [...facade.matchAll(/^export 'distillation\/([^']+\.dart)'/gm)]
    .map((match) => match[1]);
  const expectedExports = [
    "distillation_fidelity_reducer.dart",
    "distillation_input_window.dart",
    "distillation_lane_contract.dart",
    "distillation_package_models.dart",
    "distillation_response_parser.dart",
    "distillation_result_models.dart",
    "distillation_source_content_classes.dart",
    "distillation_usage_audit.dart",
  ];
  assert(
    sourceLineCount(facade) <= 40 &&
      !/^import /m.test(facade) &&
      !/^(?:class|enum|typedef|mixin|extension|sealed) /m.test(facade) &&
      sameSet(exportedLeaves, expectedExports) &&
      [...facade.matchAll(/^export /gm)].every((match) =>
        facade.slice(match.index, facade.indexOf(";", match.index) + 1).includes(" show ") ||
        facade.slice(match.index, facade.indexOf(";", match.index) + 1).includes("\n    show")
      ),
    "distillation root must remain a thin restricted eight-export facade"
  );

  const inputWindow = await readText(
    `${distillationContractRoot}/distillation_input_window.dart`
  );
  assert(
    inputWindow.includes("const int distillationInputMaxTurns = 48;") &&
      inputWindow.includes("const int distillationInputMaxBytes = 64 * 1024;") &&
      inputWindow.includes("const int distillationInputMaxApproxTokens = 12 * 1024;") &&
      inputWindow.includes("const int distillationInputMaxTurnBytes = 8 * 1024;"),
    "distillation input window must preserve the 48-turn, 64-KiB, 12K-token, and 8-KiB-per-turn limits"
  );
  assert(
    !await exists("apps/desktop/test/distillation_broker_test.dart"),

    "retired aggregate distillation broker regression must stay removed"
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
    sourceLineCount,
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
      if (specifier.startsWith("package:flutter_client/")) {
        dependency = `${flutterLibRoot}/${specifier.slice("package:flutter_client/".length)}`;
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
    sourceLineCount,
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
  await enforceDistillationContractLibraries(context);
  const workbenchChromeFacadePath =
    "apps/desktop/lib/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_chrome.dart";
  const workbenchChromeLeafLimits = new Map([
    ["workbench_desktop_navigation.dart", 240],
    ["workbench_desktop_search.dart", 320],
    ["workbench_desktop_status.dart", 100],
    ["workbench_desktop_topbar.dart", 240]
  ]);
  const workbenchChromeRoot = path.posix.dirname(workbenchChromeFacadePath);
  const workbenchChromeFacadeSource = await readText(workbenchChromeFacadePath);
  const workbenchChromeExports = [...workbenchChromeFacadeSource.matchAll(
    /^export '([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(workbenchChromeExports, [...workbenchChromeLeafLimits.keys()]) &&
      sourceLineCount(workbenchChromeFacadeSource) <= 5 &&
      !/^import /mu.test(workbenchChromeFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(workbenchChromeFacadeSource),
    "Workbench desktop chrome root must remain an exact four-leaf export facade"
  );
  const workbenchChromeSources = {};
  for (const [leaf, maxLines] of workbenchChromeLeafLimits) {
    const source = await readText(`${workbenchChromeRoot}/${leaf}`);
    workbenchChromeSources[leaf] = source;
    assert(
      sourceLineCount(source) <= maxLines &&
        !/^\s*part(?:\s+of)?\b/mu.test(source) &&
        !source.includes("workbench_desktop_chrome.dart"),
      `${leaf} must remain a bounded ordinary library without reverse facade coupling`
    );
  }
  assert(
    workbenchChromeSources["workbench_desktop_topbar.dart"].includes("WorkbenchDesktopNavigation") &&
      workbenchChromeSources["workbench_desktop_topbar.dart"].includes("WorkbenchDesktopSearch") &&
      workbenchChromeSources["workbench_desktop_search.dart"].includes("Autocomplete<_WorkbenchSearchItem>") &&
      workbenchChromeSources["workbench_desktop_navigation.dart"].includes("_WorkbenchAgentRobotIconPainter") &&
      workbenchChromeSources["workbench_desktop_status.dart"].includes("ValueListenableBuilder<LayoutChromeSnapshot>"),
    "Workbench topbar, search, navigation, and status leaves must retain separate interaction ownership"
  );
  const conversationPaneFacadePath =
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane.dart";
  const conversationPaneLeafLimits = new Map([
    ["actions.dart", 160],
    ["composition.dart", 240],
    ["header.dart", 340],
    ["resize.dart", 140]
  ]);
  const conversationPaneRoot = conversationPaneFacadePath.replace(/\.dart$/u, "");
  const conversationPaneFacadeSource = await readText(conversationPaneFacadePath);
  const conversationPaneExports = [...conversationPaneFacadeSource.matchAll(
    /^export 'agent_conversation_pane\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(conversationPaneExports, [...conversationPaneLeafLimits.keys()]) &&
      sourceLineCount(conversationPaneFacadeSource) <= 5 &&
      !/^import /mu.test(conversationPaneFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(conversationPaneFacadeSource),
    "agent conversation pane root must remain an exact four-leaf export facade"
  );
  const conversationPaneSources = {};
  for (const [leaf, maxLines] of conversationPaneLeafLimits) {
    const source = await readText(`${conversationPaneRoot}/${leaf}`);
    conversationPaneSources[leaf] = source;
    assert(
      sourceLineCount(source) <= maxLines &&
        !/^\s*part(?:\s+of)?\b/mu.test(source) &&
        !source.includes("agent_conversation_pane.dart"),
      `${leaf} must remain a bounded pane library without reverse facade coupling`
    );
  }
  assert(
    conversationPaneSources["composition.dart"].includes("agent_conversation_pane/actions.dart") &&
      conversationPaneSources["composition.dart"].includes("agent_conversation_pane/header.dart") &&
      conversationPaneSources["composition.dart"].includes("conversationParityDisclosureCopy") &&
      conversationPaneSources["actions.dart"].includes("ArchiveAgentConversationsButton") &&
      conversationPaneSources["resize.dart"].includes("PaneEdgeDragHandle") &&
      conversationPaneSources["header.dart"].includes("ConversationPaneHeader"),
    "conversation pane composition, actions, resize, and header leaves must retain separate ownership"
  );
  const messageBlocksFacadePath =
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart";
  const messageBlocksLeafLimits = new Map([
    ["disclosures.dart", 320],
    ["dispatcher.dart", 80],
    ["role_blocks.dart", 220],
    ["subagent.dart", 220]
  ]);
  const messageBlocksRoot = messageBlocksFacadePath.replace(/\.dart$/u, "");
  const messageBlocksFacadeSource = await readText(messageBlocksFacadePath);
  const messageBlocksExports = [...messageBlocksFacadeSource.matchAll(
    /^export 'agent_conversation_message_blocks\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(messageBlocksExports, [...messageBlocksLeafLimits.keys()]) &&
      sourceLineCount(messageBlocksFacadeSource) <= 5 &&
      !/^import /mu.test(messageBlocksFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(messageBlocksFacadeSource),
    "agent conversation message blocks root must remain an exact four-leaf export facade"
  );
  const messageBlocksSources = {};
  for (const [leaf, maxLines] of messageBlocksLeafLimits) {
    const source = await readText(`${messageBlocksRoot}/${leaf}`);
    messageBlocksSources[leaf] = source;
    assert(
      sourceLineCount(source) <= maxLines &&
        !/^\s*part(?:\s+of)?\b/mu.test(source) &&
        !source.includes("agent_conversation_message_blocks.dart"),
      `${leaf} must remain a bounded message block library without reverse facade coupling`
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
  const mobileRelayPanelLeafLimits = new Map([
    ["composition.dart", 210],
    ["pairing.dart", 300],
    ["qr.dart", 140],
    ["scan.dart", 70],
    ["trust.dart", 220]
  ]);
  const mobileRelayPanelRoot = mobileRelayPanelFacadePath.replace(/\.dart$/u, "");
  const mobileRelayPanelFacadeSource = await readText(mobileRelayPanelFacadePath);
  const mobileRelayPanelExports = [...mobileRelayPanelFacadeSource.matchAll(
    /^export 'mobile_relay_panel\/([^']+)';$/gmu
  )].map((match) => match[1]);
  assert(
    sameSet(mobileRelayPanelExports, [...mobileRelayPanelLeafLimits.keys()]) &&
      sourceLineCount(mobileRelayPanelFacadeSource) <= 6 &&
      !/^import /mu.test(mobileRelayPanelFacadeSource) &&
      !/^(?:class|enum|typedef|mixin|extension) /mu.test(mobileRelayPanelFacadeSource),
    "mobile relay panel root must remain an exact five-leaf export facade"
  );
  const mobileRelayPanelSources = {};
  for (const [leaf, maxLines] of mobileRelayPanelLeafLimits) {
    const source = await readText(`${mobileRelayPanelRoot}/${leaf}`);
    mobileRelayPanelSources[leaf] = source;
    assert(
      sourceLineCount(source) <= maxLines &&
        !/^\s*part(?:\s+of)?\b/mu.test(source) &&
        !source.includes("mobile_relay_panel.dart"),
      `${leaf} must remain a bounded Mobile Relay panel library without reverse facade coupling`
    );
  }
  assert(
    mobileRelayPanelSources["composition.dart"].includes("MobileRelayPairingWorkspaceCard") &&
      mobileRelayPanelSources["composition.dart"].includes("MobileRelayScanPairingPrompt") &&
      mobileRelayPanelSources["composition.dart"].includes("MobileRelayTrustVerificationCard") &&
      mobileRelayPanelSources["pairing.dart"].includes("mobile_relay_panel/qr.dart") &&
      mobileRelayPanelSources["pairing.dart"].includes("configureMobileRelayGateway") &&
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
