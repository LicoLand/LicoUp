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

const destinationPresentationDefinitionPath =
  "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart";
const sharedRendererRoot = "apps/desktop/lib/src/frontend/shared/";
const appearanceRendererRoot = "apps/desktop/lib/src/frontend/appearance/";
const presentationRoot = "apps/desktop/lib/src/presentation/";

export function isSharedRendererDependency(relativePath) {
  return relativePath.startsWith(sharedRendererRoot);
}

export function isDestinationPresentationScopePath(relativePath) {
  return (
    relativePath === destinationPresentationDefinitionPath ||
    (
      relativePath.startsWith("apps/desktop/lib/src/frontend/layout/profiles/") &&
      relativePath.includes("/destinations/")
    )
  );
}

export function isDirectNeutralDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/presentation/") ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    isSharedRendererDependency(relativePath) ||
    NEUTRAL_LAYOUT_CONTRACTS.has(relativePath)
  );
}

export function isNeutralClosureDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/") ||
    relativePath.startsWith(appearanceRendererRoot) ||
    relativePath.startsWith(presentationRoot) ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    isSharedRendererDependency(relativePath) ||
    NEUTRAL_LAYOUT_CONTRACTS.has(relativePath)
  );
}

export function forbiddenDependencyCode(relativePath) {
  if (isSharedRendererDependency(relativePath)) {
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
    !isDestinationPresentationScopePath(relativePath)
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
      (testOwner != null &&
        resolved.startsWith(`${catalog.config.profileTestFixtureRoot}/`))
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
    fail("layout_dependency_outside_contract", relativePath);
  }
  for (const token of [
    "LayoutRegistry(",
    "registerLayout(",
    "registerLayoutProfile(",
    "built_in_layout_composition",
  ]) {
    if (source.includes(token)) {
      fail("layout_mutable_registration_forbidden", relativePath);
    }
  }
}
