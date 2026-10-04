// Whether an installed package may load on the client being built.
//
// A package manifest declares `compatibility.clientVersions`: one entry per
// client line it supports. The host decides at install time whether one of those
// entries covers the client it is running, and it refuses the install with
// `package_client_incompatible` when none does
// (`crates/licoup-native/src/ffi/commands/package.rs`), so a declaration that
// stopped covering the current product version would make every shipped package
// unreachable only on a user's machine.
//
// The decision has to be the host's decision, so the requirement grammar and the
// matching rules here are a port of the `semver` crate the contract links, not
// of the narrower range grammar Node ships:
// `crates/licoup-extension-contracts/src/manifest.rs` reads every entry with
// `VersionReq::parse` and matches it with `VersionReq::matches`. A requirement
// this module accepted that the host refused would turn a green gate into a
// rejected install, and one it refused that the host accepted would fail a
// change that installs.
//
// `crates/licoup-extension-contracts/src/manifest.rs` also keeps structural
// validation apart from coverage, and so does this module: a malformed list is
// reported by `clientVersionListRefusals` and never silently reads as "no client
// is supported".
//
// This is not the release declaration form. `tools/scripts/client-release-package-index.mjs`
// evaluates `package-release.json`'s `clientCompatibility`, whose grammar is the
// index's own (`kind: "range"` with `=`, `>`, `>=`, `<`, `<=` over full
// `X.Y.Z`), and it is not what the host reads from a manifest.

/**
 * The longest requirement entry the contract accepts, in bytes
 * (`MAX_RANGE_BYTES` in `crates/licoup-extension-contracts/src/manifest.rs`).
 */
export const MAX_CLIENT_VERSION_RANGE_BYTES = 64;

/**
 * The most comparators `VersionReq::parse` collects (`MAX_COMPARATORS` in the
 * `semver` crate's `parse.rs`).
 */
const MAX_COMPARATORS = 32;

const MAX_U64 = 18446744073709551615n;

const DIGIT_ZERO = 0x30;
const DIGIT_NINE = 0x39;
const UPPER_A = 0x41;
const UPPER_Z = 0x5a;
const LOWER_A = 0x61;
const LOWER_Z = 0x7a;
const HYPHEN = 0x2d;

/**
 * The path shape one installable package manifest has inside its source
 * directory (`PACKAGE_PAYLOAD_MANIFEST_NAME`).
 */
const PACKAGE_MANIFEST_SUFFIX = "/package/manifest.json";

const PACKAGE_MANIFEST_NAME = "manifest.json";

function isAsciiDigit(character) {
  const code = character.codePointAt(0);
  return code >= DIGIT_ZERO && code <= DIGIT_NINE;
}

function trimStartSpaces(input) {
  let index = 0;
  while (input[index] === " ") index += 1;
  return input.slice(index);
}

/**
 * One `u64`-bounded numeric identifier, refusing a leading zero exactly as the
 * crate's `numeric_identifier` does.
 */
function numericIdentifier(input) {
  let length = 0;
  let value = 0n;
  while (length < input.length) {
    const code = input.charCodeAt(length);
    if (code < DIGIT_ZERO || code > DIGIT_NINE) break;
    if (value === 0n && length > 0) return null;
    value = value * 10n + BigInt(code - DIGIT_ZERO);
    if (value > MAX_U64) return null;
    length += 1;
  }
  if (length === 0) return null;
  return { value, rest: input.slice(length) };
}

/** One `*`, `x` or `X` wildcard, as the crate's `wildcard` reads it. */
function wildcard(input) {
  if (input.startsWith("*")) return { rest: input.slice(1) };
  if (input.startsWith("x")) return { rest: input.slice(1) };
  if (input.startsWith("X")) return { rest: input.slice(1) };
  return null;
}

/**
 * One dot-separated identifier run: letters, digits and hyphens in segments
 * split by `.`. `position` is `"pre"` for a prerelease, whose all-numeric
 * segments must not carry a leading zero, and `"build"` for build metadata,
 * which may.
 *
 * An absent first segment is not an error here: the crate returns the empty
 * identifier to its caller, which is what makes `1.2.3-` an empty-segment
 * refusal rather than a parse of something.
 */
function identifier(input, position) {
  let accumulatedLength = 0;
  let segmentLength = 0;
  let segmentHasNonDigit = false;
  for (;;) {
    const index = accumulatedLength + segmentLength;
    const code = index < input.length ? input.charCodeAt(index) : Number.NaN;
    if ((code >= UPPER_A && code <= UPPER_Z) ||
        (code >= LOWER_A && code <= LOWER_Z) || code === HYPHEN) {
      segmentLength += 1;
      segmentHasNonDigit = true;
    } else if (code >= DIGIT_ZERO && code <= DIGIT_NINE) {
      segmentLength += 1;
    } else {
      const boundary = index < input.length ? input[index] : "";
      if (segmentLength === 0) {
        if (accumulatedLength === 0 && boundary !== ".") {
          return { value: "", rest: input };
        }
        return null;
      }
      if (position === "pre" && segmentLength > 1 && !segmentHasNonDigit &&
          input.startsWith("0", accumulatedLength)) {
        return null;
      }
      accumulatedLength += segmentLength;
      if (boundary === ".") {
        accumulatedLength += 1;
        segmentLength = 0;
        segmentHasNonDigit = false;
      } else {
        return {
          value: input.slice(0, accumulatedLength),
          rest: input.slice(accumulatedLength),
        };
      }
    }
  }
}

/**
 * One version, as `semver::Version::parse` reads it. Build metadata is parsed
 * and dropped, because it is never relevant to whether a requirement matches.
 *
 * Returns `null` for every input the crate refuses, so a caller that must fail
 * closed has one value to test.
 */
export function parseVersion(text) {
  if (typeof text !== "string" || text.length === 0) return null;
  let cursor = text;

  const major = numericIdentifier(cursor);
  if (!major) return null;
  if (!major.rest.startsWith(".")) return null;
  cursor = major.rest.slice(1);

  const minor = numericIdentifier(cursor);
  if (!minor) return null;
  if (!minor.rest.startsWith(".")) return null;
  cursor = minor.rest.slice(1);

  const patch = numericIdentifier(cursor);
  if (!patch) return null;
  cursor = patch.rest;

  let pre = "";
  if (cursor.startsWith("-")) {
    const parsed = identifier(cursor.slice(1), "pre");
    if (!parsed || parsed.value.length === 0) return null;
    pre = parsed.value;
    cursor = parsed.rest;
  }

  if (cursor.startsWith("+")) {
    const parsed = identifier(cursor.slice(1), "build");
    if (!parsed || parsed.value.length === 0) return null;
    cursor = parsed.rest;
  }

  if (cursor.length > 0) return null;
  return { major: major.value, minor: minor.value, patch: patch.value, pre };
}

/** The comparison operator one comparator starts with. */
function readOperator(input) {
  if (input.startsWith("=")) return { op: "exact", rest: input.slice(1) };
  if (input.startsWith(">=")) return { op: "greaterEq", rest: input.slice(2) };
  if (input.startsWith(">")) return { op: "greater", rest: input.slice(1) };
  if (input.startsWith("<=")) return { op: "lessEq", rest: input.slice(2) };
  if (input.startsWith("<")) return { op: "less", rest: input.slice(1) };
  if (input.startsWith("~")) return { op: "tilde", rest: input.slice(1) };
  if (input.startsWith("^")) return { op: "caret", rest: input.slice(1) };
  return { op: "caret", rest: input };
}

/**
 * One `Comparator`: an operator over a partial version. A missing minor or
 * patch is `null`, which is a different claim from `0`.
 */
function readComparator(input) {
  const operator = readOperator(input);
  const defaultOperator = input.length === operator.rest.length;
  let op = operator.op;
  let cursor = trimStartSpaces(operator.rest);

  const major = numericIdentifier(cursor);
  if (!major) return null;
  cursor = major.rest;

  let minor = null;
  let hasWildcard = false;
  if (cursor.startsWith(".")) {
    cursor = cursor.slice(1);
    const found = wildcard(cursor);
    if (found) {
      hasWildcard = true;
      if (defaultOperator) op = "wildcard";
      cursor = found.rest;
    } else {
      const parsed = numericIdentifier(cursor);
      if (!parsed) return null;
      minor = parsed.value;
      cursor = parsed.rest;
    }
  }

  let patch = null;
  if (cursor.startsWith(".")) {
    cursor = cursor.slice(1);
    const found = wildcard(cursor);
    if (found) {
      if (defaultOperator) op = "wildcard";
      cursor = found.rest;
    } else if (hasWildcard) {
      return null;
    } else {
      const parsed = numericIdentifier(cursor);
      if (!parsed) return null;
      patch = parsed.value;
      cursor = parsed.rest;
    }
  }

  // A prerelease and build metadata are only readable on a comparator that names
  // a patch, so `1.2-alpha` is refused rather than read as a partial version.
  let pre = "";
  if (patch !== null && cursor.startsWith("-")) {
    const parsed = identifier(cursor.slice(1), "pre");
    if (!parsed || parsed.value.length === 0) return null;
    pre = parsed.value;
    cursor = parsed.rest;
  }

  if (patch !== null && cursor.startsWith("+")) {
    const parsed = identifier(cursor.slice(1), "build");
    if (!parsed || parsed.value.length === 0) return null;
    cursor = parsed.rest;
  }

  return {
    comparator: { op, major: major.value, minor, patch, pre },
    rest: trimStartSpaces(cursor),
  };
}

/** Every comma-separated comparator, or `null` for the first refusal. */
function readComparators(text) {
  const comparators = [];
  let cursor = text;
  let depth = 0;
  for (;;) {
    const parsed = readComparator(cursor);
    if (!parsed) return null;
    comparators.push(parsed.comparator);
    if (parsed.rest.length === 0) return comparators;
    if (!parsed.rest.startsWith(",")) return null;
    cursor = trimStartSpaces(parsed.rest.slice(1));
    depth += 1;
    if (depth === MAX_COMPARATORS) return null;
  }
}

/**
 * The comparators of one version requirement, as `semver::VersionReq::parse`
 * reads it, or `null` for every input the crate refuses.
 *
 * An empty list is the crate's `VersionReq::STAR` and not a refusal: `*` alone
 * is a requirement that covers every release, and `*, 1.2.3` is the refusal,
 * because a wildcard that is not the only comparator names nothing.
 */
export function parseRequirement(text) {
  if (typeof text !== "string") return null;
  const cursor = trimStartSpaces(text);
  if (wildcard(cursor)) {
    const rest = trimStartSpaces(cursor.slice(1));
    return rest.length === 0 ? [] : null;
  }
  return readComparators(cursor);
}

/**
 * The crate's prerelease ordering: a real release sorts above every
 * prerelease, all-numeric segments compare numerically, a numeric segment sorts
 * below one with letters, and the rest compares in ASCII order.
 *
 * The ported identifiers are ASCII-only by construction, so the string
 * comparisons below order the same code points the crate's byte ordering does.
 */
function comparePrerelease(left, right) {
  if (left === right) return 0;
  if (left === "") return 1;
  if (right === "") return -1;

  const leftFields = left.split(".");
  const rightFields = right.split(".");
  for (let index = 0; index < leftFields.length; index += 1) {
    if (index >= rightFields.length) return 1;
    const ordering = comparePrereleaseField(leftFields[index], rightFields[index]);
    if (ordering !== 0) return ordering;
  }
  return leftFields.length === rightFields.length ? 0 : -1;
}

function comparePrereleaseField(left, right) {
  const leftNumeric = [...left].every(isAsciiDigit);
  const rightNumeric = [...right].every(isAsciiDigit);
  if (leftNumeric && rightNumeric) {
    if (left.length !== right.length) return left.length < right.length ? -1 : 1;
    return left === right ? 0 : (left < right ? -1 : 1);
  }
  if (leftNumeric) return -1;
  if (rightNumeric) return 1;
  return left === right ? 0 : (left < right ? -1 : 1);
}

function matchesExact(comparator, version) {
  if (version.major !== comparator.major) return false;
  if (comparator.minor !== null && version.minor !== comparator.minor) return false;
  if (comparator.patch !== null && version.patch !== comparator.patch) return false;
  return version.pre === comparator.pre;
}

function matchesGreater(comparator, version) {
  if (version.major !== comparator.major) return version.major > comparator.major;
  if (comparator.minor === null) return false;
  if (version.minor !== comparator.minor) return version.minor > comparator.minor;
  if (comparator.patch === null) return false;
  if (version.patch !== comparator.patch) return version.patch > comparator.patch;
  return comparePrerelease(version.pre, comparator.pre) > 0;
}

function matchesLess(comparator, version) {
  if (version.major !== comparator.major) return version.major < comparator.major;
  if (comparator.minor === null) return false;
  if (version.minor !== comparator.minor) return version.minor < comparator.minor;
  if (comparator.patch === null) return false;
  if (version.patch !== comparator.patch) return version.patch < comparator.patch;
  return comparePrerelease(version.pre, comparator.pre) < 0;
}

function matchesTilde(comparator, version) {
  if (version.major !== comparator.major) return false;
  if (comparator.minor !== null && version.minor !== comparator.minor) return false;
  if (comparator.patch !== null && version.patch !== comparator.patch) {
    return version.patch > comparator.patch;
  }
  return comparePrerelease(version.pre, comparator.pre) >= 0;
}

function matchesCaret(comparator, version) {
  if (version.major !== comparator.major) return false;
  if (comparator.minor === null) return true;
  if (comparator.patch === null) {
    return comparator.major > 0n
      ? version.minor >= comparator.minor
      : version.minor === comparator.minor;
  }
  if (comparator.major > 0n) {
    if (version.minor !== comparator.minor) return version.minor > comparator.minor;
    if (version.patch !== comparator.patch) return version.patch > comparator.patch;
  } else if (comparator.minor > 0n) {
    if (version.minor !== comparator.minor) return false;
    if (version.patch !== comparator.patch) return version.patch > comparator.patch;
  } else if (version.minor !== comparator.minor || version.patch !== comparator.patch) {
    return false;
  }
  return comparePrerelease(version.pre, comparator.pre) >= 0;
}

function matchesComparator(comparator, version) {
  switch (comparator.op) {
    case "exact":
    case "wildcard":
      return matchesExact(comparator, version);
    case "greater":
      return matchesGreater(comparator, version);
    case "greaterEq":
      return matchesExact(comparator, version) || matchesGreater(comparator, version);
    case "less":
      return matchesLess(comparator, version);
    case "lessEq":
      return matchesExact(comparator, version) || matchesLess(comparator, version);
    case "tilde":
      return matchesTilde(comparator, version);
    default:
      return matchesCaret(comparator, version);
  }
}

/**
 * Whether one version satisfies one parsed requirement.
 *
 * Every comparator must match. A prerelease version additionally needs one
 * comparator that names its exact major, minor and patch together with a
 * non-empty prerelease, so `>=0.3.0, <1.0.0` matches `0.3.0` and refuses
 * `1.0.0-rc.1` for a reason other than its numbers.
 */
export function requirementMatches(requirement, version) {
  for (const comparator of requirement) {
    if (!matchesComparator(comparator, version)) return false;
  }
  if (version.pre === "") return true;
  return requirement.some((comparator) =>
    comparator.major === version.major &&
    comparator.minor === version.minor &&
    comparator.patch === version.patch &&
    comparator.pre !== "");
}

/**
 * Whether a manifest's declared list covers one client version.
 *
 * This is `Compatibility::covers`: an unparseable client version is covered by
 * nothing, an unparseable entry is covered by nothing, and the rest is the
 * `any` over the declared entries.
 */
export function clientVersionsCover(clientVersions, clientVersion) {
  if (!Array.isArray(clientVersions)) return false;
  const version = parseVersion(clientVersion);
  if (!version) return false;
  return clientVersions.some((declared) => {
    const requirement = typeof declared === "string" ? parseRequirement(declared) : null;
    return requirement !== null && requirementMatches(requirement, version);
  });
}

/**
 * Why a declared list is structurally unusable, as
 * `Compatibility::validate` refuses it: the list is required, and every entry
 * must be a non-empty requirement within the contract's byte bound that the
 * grammar can evaluate.
 *
 * An empty list is a refusal rather than "no client is supported", and a
 * malformed entry is a refusal rather than a version this build happens not to
 * match, which is what keeps the two verdicts apart.
 */
export function clientVersionListRefusals(clientVersions) {
  if (!Array.isArray(clientVersions) || clientVersions.length === 0) {
    return ["compatibility.clientVersions must declare at least one client line"];
  }
  const refusals = [];
  for (const [index, declared] of clientVersions.entries()) {
    const where = `compatibility.clientVersions[${index}]`;
    if (typeof declared !== "string" || declared.length === 0) {
      refusals.push(`${where} must be a non-empty version requirement`);
    } else if (Buffer.byteLength(declared, "utf8") > MAX_CLIENT_VERSION_RANGE_BYTES) {
      refusals.push(
        `${where} is longer than ${MAX_CLIENT_VERSION_RANGE_BYTES} bytes: ${declared}`);
    } else if (parseRequirement(declared) === null) {
      refusals.push(`${where} is not a version requirement this contract evaluates: ${declared}`);
    }
  }
  return refusals;
}

/**
 * Every package manifest whose client compatibility has to cover the client
 * being built.
 *
 * Two sources, because either alone leaves a way around the gate: every tracked
 * manifest at the path shape an installable package has, and the manifest of
 * every package the release set declares. A package the release set ships is
 * therefore always checked, even from a source directory that does not use the
 * `package/` name.
 */
export function clientPackageManifestPaths({ trackedFiles = [], declaredSources = [] } = {}) {
  const paths = new Set();
  for (const file of trackedFiles) {
    if (typeof file === "string" && file.endsWith(PACKAGE_MANIFEST_SUFFIX)) {
      paths.add(file);
    }
  }
  for (const source of declaredSources) {
    if (typeof source === "string" && source.length > 0) {
      paths.add(`${source.replace(/\/+$/u, "")}/${PACKAGE_MANIFEST_NAME}`);
    }
  }
  return [...paths].sort();
}

/**
 * The compatibility verdict of every package manifest, one record per package.
 *
 * `manifests` is one `{ path, manifest }` per path from
 * [`clientPackageManifestPaths`]; a caller that could not read or parse one
 * passes `manifest: null` and the `readError` it saw rather than dropping the
 * entry, so a vanished or malformed manifest is reported instead of shrinking
 * the checked set.
 */
export function evaluateClientPackageCompatibility({ productVersion, manifests }) {
  const version = parseVersion(productVersion);
  return manifests.map(({ path: manifestPath, manifest, readError = "" }) => {
    if (readError) {
      return Object.freeze({
        path: manifestPath,
        packageId: "",
        clientVersions: [],
        covered: false,
        reasons: Object.freeze([readError]),
        clientVersionParses: version !== null,
      });
    }
    const declared = manifest?.compatibility?.clientVersions;
    const refusals = clientVersionListRefusals(declared);
    const covered = refusals.length === 0 && clientVersionsCover(declared, productVersion);
    const reasons = [...refusals];
    if (reasons.length === 0 && !covered) {
      reasons.push(
        `no declared line covers ${productVersion}: ${declared.join(", ")}`);
    }
    return Object.freeze({
      path: manifestPath,
      packageId: typeof manifest?.id === "string" ? manifest.id : "",
      clientVersions: Array.isArray(declared) ? [...declared] : [],
      covered,
      reasons: Object.freeze(reasons),
      clientVersionParses: version !== null,
    });
  });
}
