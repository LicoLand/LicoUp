import path from "node:path";

const appRoot = "apps/desktop/lib";
const srcRoot = `${appRoot}/src`;
const applicationRoot = `${srcRoot}/application/`;
const presentationRoot = `${srcRoot}/presentation/`;
const frontendRoot = `${srcRoot}/frontend/`;
const compositionRoot = `${srcRoot}/composition/`;

export const PRESENTATION_STATE_PLANES = Object.freeze([
  "appearance",
  "locale",
  "layout",
  "environment",
  "navigation",
  "status",
]);

export const PRESENTATION_BINDING_NAMES = Object.freeze([
  "ShellBinding",
  "AgentsBinding",
  "MonitoringBinding",
  "SkillHubBinding",
  "PluginManagementBinding",
  "MobileRelayBinding",
  "ModelsBinding",
  "SettingsBinding",
  "AgentHubBinding",
  "ConversationBinding",
  "TargetsBinding",
  "SearchBinding",
  "ChromeBinding",
]);

export const RETIRED_PRESENTATION_PATHS = Object.freeze([
  `${srcRoot}/composition/m2_legacy_shell_renderer_transition_adapter.dart`,
  `${srcRoot}/projections/listenable_projection_consumer.dart`,
  `${srcRoot}/projections/adapters/legacy_projection_consumer_source_adapter.dart`,
]);

const requiredDirectories = Object.freeze([
  "packages/presentation_contract/lib",
  `${srcRoot}/application/state`,
  `${srcRoot}/presentation`,
  `${srcRoot}/projections`,
  `${srcRoot}/frontend/binding`,
  `${srcRoot}/composition`,
]);

const implementationRoots = Object.freeze([
  `${srcRoot}/application/`,
  `${srcRoot}/backend/`,
  `${srcRoot}/platform/`,
  `${srcRoot}/projections/`,
  `${srcRoot}/composition/`,
  `${srcRoot}/frontend/`,
]);

const applicationFrameworkTokens = Object.freeze([
  "ChangeNotifier",
  "ValueNotifier",
  "ValueListenable",
  "ListenableBuilder",
  "AnimatedBuilder",
  "Widget",
  "BuildContext",
  "AppLifecycleState",
  "WidgetsBinding",
  "WidgetsBindingObserver",
  "SchedulerBinding",
  "debugPrint",
  "kDebugMode",
]);

const retiredPresentationSymbols = Object.freeze([
  "M2LegacyShellRendererTransitionAdapter",
  "LegacyProjectionConsumerSourceAdapter",
  "ListenableProjectionConsumer",
]);

function stripDartComments(source) {
  let result = "";
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        result += "  ";
        blockComment = false;
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
      }
      continue;
    }
    if (quote != null) {
      if (quote.length === 3 && source.startsWith(quote, index)) {
        result += quote;
        quote = null;
        index += 2;
        continue;
      }
      result += character;
      if (quote.length === 3) {
        continue;
      } else if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      result += "  ";
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      result += "  ";
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = source.startsWith(character.repeat(3), index)
        ? character.repeat(3)
        : character;
      if (quote.length === 3) {
        result += character.repeat(2);
        index += 2;
      }
    }
    result += character;
  }
  return result;
}

function maskDartNonCode(source) {
  const uncommented = stripDartComments(source);
  let result = "";
  let quote = null;
  let escaped = false;
  for (let index = 0; index < uncommented.length; index += 1) {
    const character = uncommented[index];
    if (quote != null) {
      if (quote.length === 3 && uncommented.startsWith(quote, index)) {
        result += "   ";
        quote = null;
        index += 2;
        continue;
      }
      if (quote.length === 3) {
        result += character === "\n" ? "\n" : " ";
        continue;
      } else if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      result += character === "\n" ? "\n" : " ";
      continue;
    }
    if (character === "'" || character === '"') {
      quote = uncommented.startsWith(character.repeat(3), index)
        ? character.repeat(3)
        : character;
      result += quote.length === 3 ? "   " : " ";
      if (quote.length === 3) index += 2;
      continue;
    }
    result += character;
  }
  return result;
}

function importsFrom(source) {
  const imports = [];
  const directive = /^\s*(?:import|export|part)(?!\s+of\b)\s+([\s\S]*?);/gmu;
  for (const match of stripDartComments(source).matchAll(directive)) {
    for (const uri of match[1].matchAll(/['"]([^'"\r\n]+)['"]/gu)) {
      imports.push(uri[1]);
    }
  }
  return imports;
}

function resolveLicoupImport(importer, specifier) {
  if (specifier.startsWith("package:licoup/")) {
    return `${appRoot}/${specifier.slice("package:licoup/".length)}`;
  }
  if (specifier.startsWith(".")) {
    return path.posix.normalize(path.posix.join(path.posix.dirname(importer), specifier));
  }
  return null;
}

function implementationImports(relativePath, source) {
  return importsFrom(source)
    .map((specifier) => resolveLicoupImport(relativePath, specifier))
    .filter((candidate) =>
      candidate != null && implementationRoots.some((root) => candidate.startsWith(root)));
}

function classBody(source, className) {
  const masked = maskDartNonCode(source);
  const declaration = new RegExp(
    `\\b(?:abstract\\s+interface\\s+|abstract\\s+|base\\s+|final\\s+|interface\\s+|sealed\\s+)?class\\s+${className}\\b`,
    "u",
  ).exec(masked);
  if (declaration == null) return null;
  const open = masked.indexOf("{", declaration.index + declaration[0].length);
  if (open < 0) return null;
  let depth = 0;
  for (let index = open; index < masked.length; index += 1) {
    if (masked[index] === "{") depth += 1;
    if (masked[index] === "}") {
      depth -= 1;
      if (depth === 0) return masked.slice(open + 1, index);
    }
  }
  return null;
}

function declaredTypes(source) {
  const masked = maskDartNonCode(source);
  return [...masked.matchAll(
    /\b(?:class|enum|mixin|typedef)\s+([A-Z][A-Za-z0-9_]*)\b/gu,
  )].map((match) => match[1]);
}

function hasToken(source, token) {
  return new RegExp(`\\b${token}\\b`, "u").test(maskDartNonCode(source));
}

function pushFailure(failures, rule, relativePath, detail) {
  failures.push([rule, relativePath, detail].filter((value) => value != null));
}

export function inspectPresentationBoundarySources(sourceByPath) {
  const failures = [];
  const typeOwners = new Map();
  const compositionEntries = [];

  for (const [relativePath, source] of sourceByPath) {
    const masked = maskDartNonCode(source);
    const types = declaredTypes(source);
    for (const type of types) {
      const owners = typeOwners.get(type) ?? [];
      owners.push(relativePath);
      typeOwners.set(type, owners);
    }

    if (relativePath.startsWith(applicationRoot)) {
      if (importsFrom(source).some((specifier) => specifier.startsWith("package:flutter/"))) {
        pushFailure(failures, "presentation_boundary_application_flutter", relativePath);
      }
      if (implementationImports(relativePath, source).some(
        (candidate) => candidate.startsWith(frontendRoot),
      )) {
        pushFailure(failures, "presentation_boundary_application_direction", relativePath);
      }
      for (const token of applicationFrameworkTokens) {
        if (new RegExp(`\\b${token}\\b`, "u").test(masked)) {
          pushFailure(
            failures,
            "presentation_boundary_application_framework_type",
            relativePath,
            token,
          );
        }
      }
      if (/\b(?:notifyListeners|addListener|removeListener)\s*\(/u.test(masked)) {
        pushFailure(failures, "presentation_boundary_application_listener", relativePath);
      }
      if (
        relativePath.endsWith("/client_controller.dart") &&
        /@Deprecated\s*\(/u.test(masked) &&
        /\bClientController\b/u.test(masked)
      ) {
        pushFailure(
          failures,
          "presentation_boundary_deprecated_controller_annotation",
          relativePath,
        );
      }
    }

    if (relativePath.startsWith(presentationRoot)) {
      if (importsFrom(source).some((specifier) => specifier.startsWith("package:flutter/"))) {
        pushFailure(failures, "presentation_boundary_stable_flutter", relativePath);
      }
      if (implementationImports(relativePath, source).length > 0) {
        pushFailure(failures, "presentation_boundary_stable_direction", relativePath);
      }
      if (/\bClientController\b/u.test(masked)) {
        pushFailure(failures, "presentation_boundary_stable_controller", relativePath);
      }
    }

    if (relativePath.startsWith(frontendRoot)) {
      if (implementationImports(relativePath, source).some(
        (candidate) => !candidate.startsWith(frontendRoot),
      )) {
        pushFailure(failures, "presentation_boundary_frontend_direction", relativePath);
      }
      if (/\bClientController\b/u.test(masked)) {
        pushFailure(failures, "presentation_boundary_frontend_controller", relativePath);
      }
    }

    const imports = implementationImports(relativePath, source);
    const importsApplication = imports.some((candidate) => candidate.startsWith(applicationRoot));
    const importsFrontend = imports.some((candidate) => candidate.startsWith(frontendRoot));
    if (!relativePath.startsWith(compositionRoot) && importsApplication && importsFrontend) {
      pushFailure(failures, "presentation_boundary_wiring_outside_composition", relativePath);
    }

    if (relativePath.startsWith(compositionRoot)) {
      compositionEntries.push([relativePath, source]);
    } else if (!relativePath.startsWith(presentationRoot)) {
      for (const bindingName of PRESENTATION_BINDING_NAMES) {
        if (new RegExp(`\\b${bindingName}\\s*\\(`, "u").test(masked)) {
          pushFailure(
            failures,
            "presentation_boundary_wiring_outside_composition",
            relativePath,
            bindingName,
          );
        }
      }
    }

    for (const symbol of retiredPresentationSymbols) {
      if (new RegExp(`\\b${symbol}\\b`, "u").test(masked)) {
        pushFailure(failures, "presentation_boundary_retired_symbol", relativePath, symbol);
      }
    }
  }

  for (const retiredPath of RETIRED_PRESENTATION_PATHS) {
    if (sourceByPath.has(retiredPath)) {
      pushFailure(failures, "presentation_boundary_retired_path", retiredPath);
    }
  }

  const expectedBindingSet = new Set(PRESENTATION_BINDING_NAMES);
  for (const bindingName of PRESENTATION_BINDING_NAMES) {
    const owners = typeOwners.get(bindingName) ?? [];
    if (owners.length !== 1 || !owners[0]?.startsWith(presentationRoot)) {
      pushFailure(
        failures,
        "presentation_boundary_binding_coverage",
        owners[0] ?? presentationRoot,
        bindingName,
      );
      continue;
    }
    const source = sourceByPath.get(owners[0]);
    const body = classBody(source, bindingName);
    if (body == null) {
      pushFailure(failures, "presentation_boundary_binding_surface", owners[0], bindingName);
      continue;
    }
    if (/\b(?:StreamController|dispose|close|initialize|Producer)\b/u.test(body)) {
      pushFailure(failures, "presentation_boundary_binding_lifecycle", owners[0], bindingName);
    }
    if (/\b(?:List|Map|Set)\s*</u.test(body)) {
      pushFailure(failures, "presentation_boundary_binding_mutable_collection", owners[0], bindingName);
    }
  }
  for (const [type, owners] of typeOwners) {
    if (
      type.endsWith("Binding") &&
      owners.some((owner) => owner.startsWith(presentationRoot)) &&
      !expectedBindingSet.has(type)
    ) {
      pushFailure(failures, "presentation_boundary_binding_unexpected", owners[0], type);
    }
  }

  for (const bindingName of PRESENTATION_BINDING_NAMES.filter((name) => name !== "ShellBinding")) {
    const prefix = bindingName.slice(0, -"Binding".length);
    for (const suffix of ["Projection", "Intent", "Effect"]) {
      const typeName = `${prefix}${suffix}`;
      const owners = typeOwners.get(typeName) ?? [];
      if (owners.length !== 1 || !owners[0]?.startsWith(presentationRoot)) {
        pushFailure(
          failures,
          "presentation_boundary_binding_semantics",
          owners[0] ?? presentationRoot,
          typeName,
        );
      }
    }
  }

  const shellOwner = (typeOwners.get("ShellBinding") ?? [])[0];
  const shellBody = shellOwner == null
    ? null
    : classBody(sourceByPath.get(shellOwner), "ShellBinding");
  if (shellBody != null) {
    for (const plane of PRESENTATION_STATE_PLANES) {
      const fieldPattern = "\\bProjectionSource" +
        "\\s*<[^;>]+>\\s+" + plane + "\\s*;";
      const matches = [...shellBody.matchAll(
        new RegExp(fieldPattern, "gu"),
      )];
      if (matches.length !== 1) {
        pushFailure(
          failures,
          "presentation_boundary_state_plane_coverage",
          shellOwner,
          plane,
        );
      }
    }
    if (
      /\bShellProjection\b|\b(?:app|presentation|shell)Revision\b|\brootNotifier\b|\bnotifyListeners\b/u.test(shellBody)
    ) {
      pushFailure(failures, "presentation_boundary_state_planes_combined", shellOwner);
    }
  }

  const compositionSource = compositionEntries.map(([, source]) => source).join("\n");
  const compositionImports = compositionEntries.flatMap(([relativePath, source]) =>
    importsFrom(source).map((specifier) => resolveLicoupImport(relativePath, specifier)));
  const compositionImportsApplication = compositionImports.some((candidate) =>
    candidate?.startsWith(applicationRoot));
  const compositionImportsFrontend = compositionImports.some((candidate) =>
    candidate?.startsWith(frontendRoot));
  if (!compositionImportsApplication || !compositionImportsFrontend) {
    pushFailure(
      failures,
      "presentation_boundary_composition_concrete_edges",
      `${compositionRoot}client_app_composition.dart`,
    );
  }
  for (const bindingName of PRESENTATION_BINDING_NAMES) {
    if (!hasToken(compositionSource, bindingName)) {
      pushFailure(
        failures,
        "presentation_boundary_composition_binding_coverage",
        `${compositionRoot}client_app_composition.dart`,
        bindingName,
      );
    }
  }

  return failures;
}

export function inspectPresentationContractSources(sourceByPath) {
  const failures = [];
  for (const [relativePath, source] of sourceByPath) {
    const masked = maskDartNonCode(source);
    if (importsFrom(source).some((specifier) => specifier.startsWith("package:"))) {
      pushFailure(failures, "presentation_boundary_package_purity", relativePath);
    }
    if (
      /\b(?:Widget|BuildContext|ClientController|ChangeNotifier|ValueNotifier|ValueListenable|StreamController|dispose|close|revision)\b/u.test(masked)
    ) {
      pushFailure(failures, "presentation_boundary_package_surface", relativePath);
    }
  }
  return failures;
}

export function inspectPresentationBoundaryPolicySources(sourceByPath) {
  const failures = [];
  const stalePolicy =
    /\b(?:const|let|var)\s+[A-Za-z0-9_]*(?:legacy|debt|allowlist)[A-Za-z0-9_]*\s*=\s*new\s+(?:Set|Map)\b|\bfunction\s+isAllowedLegacy[A-Za-z0-9_]*\s*\(/iu;
  for (const [relativePath, source] of sourceByPath) {
    if (stalePolicy.test(source)) {
      pushFailure(failures, "presentation_boundary_stale_allowlist", relativePath);
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

  const packagePaths = await collectSourceFiles("packages/presentation_contract/lib", ".dart");
  const packageSourceByPath = new Map(
    await Promise.all(packagePaths.map(async (relativePath) => [relativePath, await readText(relativePath)])),
  );
  for (const [rule, relativePath, detail] of inspectPresentationContractSources(packageSourceByPath)) {
    assert(false, `[${rule}] ${relativePath}${detail == null ? "" : `: ${detail}`}`);
  }
  const contractPubspecPath = "packages/presentation_contract/pubspec.yaml";
  const contractPubspec = await readText(contractPubspecPath);
  for (const rule of inspectPresentationContractPubspec(contractPubspec)) {
    assert(false, `[${rule}] ${contractPubspecPath} must not declare production dependencies`);
  }

  const dartPaths = await context.collectDartSourceFiles();
  const sourceByPath = new Map(
    await Promise.all(dartPaths.map(async (relativePath) => [relativePath, await readText(relativePath)])),
  );
  for (const [rule, relativePath, detail] of inspectPresentationBoundarySources(sourceByPath)) {
    assert(false, `[${rule}] ${relativePath}${detail == null ? "" : `: ${detail}`}`);
  }

  const policyRoots = [
    "apps/desktop/scripts/client-architecture/checks/flutter",
    "apps/desktop/scripts/verify-layout-boundaries",
  ];
  const policyPaths = (await Promise.all(
    policyRoots.map((relativeRoot) => collectSourceFiles(relativeRoot, ".mjs")),
  )).flat();
  const policySourceByPath = new Map(
    await Promise.all(policyPaths.map(async (relativePath) => [relativePath, await readText(relativePath)])),
  );
  for (const [rule, relativePath] of inspectPresentationBoundaryPolicySources(policySourceByPath)) {
    assert(false, `[${rule}] ${relativePath}`);
  }
}
