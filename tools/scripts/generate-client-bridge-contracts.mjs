import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const manifestPath = "schemas/client_bridge/manifest.json";
const schemaPrefix = "schemas/client_bridge/";
const dartPrefix = "apps/desktop/lib/src/contracts/generated/";
const allowedNonBridgeOutputs = new Set([
  `${dartPrefix}README.md`,
  `${dartPrefix}conversation_protocol.g.dart`,
]);
const maximumDiagnostics = 20;
const maximumManifestBytes = 64 * 1024;
const maximumSchemaBytes = 256 * 1024;
const maximumPathLength = 240;

class ContractError extends Error {}

function fail(message) {
  throw new ContractError(message);
}

function readBoundedJson(relativePath, maximumBytes, label) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  let stats;
  let source;
  try {
    stats = fs.statSync(absolutePath);
    if (!stats.isFile()) fail(`${label} is not a file: ${relativePath}`);
    if (stats.size > maximumBytes) fail(`${label} is too large: ${relativePath}`);
    source = fs.readFileSync(absolutePath, "utf8");
  } catch (error) {
    if (error instanceof ContractError) throw error;
    fail(`missing or unreadable ${label}: ${relativePath}`);
  }
  try {
    return JSON.parse(source);
  } catch {
    fail(`invalid JSON in ${label}: ${relativePath}`);
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validatePath(value, prefix, suffix, label) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumPathLength ||
    value.includes("\\") ||
    value.includes("\0") ||
    path.posix.isAbsolute(value) ||
    path.posix.normalize(value) !== value ||
    value === ".." ||
    value.startsWith("../") ||
    !value.startsWith(prefix) ||
    !value.endsWith(suffix)
  ) {
    fail(`unsafe or invalid ${label} path`);
  }
  return value;
}

function validateManifest() {
  const manifest = readBoundedJson(
    manifestPath,
    maximumManifestBytes,
    "bridge manifest",
  );
  if (!isRecord(manifest) || manifest.version !== 1) {
    fail("unsupported bridge manifest version");
  }
  if (!Array.isArray(manifest.families) || manifest.families.length !== 7) {
    fail("bridge manifest must contain exactly seven ordered families");
  }

  const ids = new Set();
  const schemas = new Set();
  const dartOutputs = new Set();
  let activeCount = 0;

  for (let index = 0; index < manifest.families.length; index += 1) {
    const family = manifest.families[index];
    if (!isRecord(family)) fail(`invalid bridge family at index ${index}`);
    if (
      typeof family.id !== "string" ||
      !/^[a-z][a-z0-9_]{0,63}$/u.test(family.id)
    ) {
      fail(`invalid bridge family id at index ${index}`);
    }
    if (ids.has(family.id)) fail(`duplicate bridge family id at index ${index}`);
    ids.add(family.id);

    if (family.status !== "active" && family.status !== "planned") {
      fail(`invalid bridge family status at index ${index}`);
    }
    if (family.status === "active") activeCount += 1;

    validatePath(family.schema, schemaPrefix, ".json", "schema");
    validatePath(family.dartOutput, dartPrefix, ".g.dart", "Dart output");

    for (const [value, seen, label] of [
      [family.schema, schemas, "schema"],
      [family.dartOutput, dartOutputs, "Dart output"],
    ]) {
      if (seen.has(value)) fail(`duplicate bridge ${label} path`);
      seen.add(value);
    }
  }
  if (activeCount === 0) {
    fail("bridge manifest must contain at least one active family");
  }
  return manifest;
}

function validateRegisteredFiles(manifest, checkOnly) {
  const diagnostics = [];
  const registeredOutputs = new Set(
    manifest.families.map(({ dartOutput }) => dartOutput),
  );

  for (const family of manifest.families) {
    const schemaExists = fs.existsSync(path.join(repositoryRoot, family.schema));
    const dartExists = fs.existsSync(path.join(repositoryRoot, family.dartOutput));
    if (family.status === "active") {
      if (!schemaExists) diagnostics.push(`missing active schema: ${family.schema}`);
      if (checkOnly && !dartExists) {
        diagnostics.push(`missing active output: ${family.dartOutput}`);
      }
    } else {
      if (schemaExists) diagnostics.push(`planned schema must be absent: ${family.schema}`);
      if (dartExists) diagnostics.push(`planned output must be absent: ${family.dartOutput}`);
    }
  }

  for (const [directory, suffix] of [
    [dartPrefix, ".g.dart"],
  ]) {
    const absoluteDirectory = path.join(repositoryRoot, directory);
    if (!fs.existsSync(absoluteDirectory)) continue;
    const names = fs.readdirSync(absoluteDirectory, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(suffix))
      .map((entry) => entry.name)
      .sort();
    for (const name of names) {
      const relativePath = `${directory}${name}`;
      if (
        !registeredOutputs.has(relativePath) &&
        !allowedNonBridgeOutputs.has(relativePath)
      ) {
        diagnostics.push(`unregistered bridge output: ${relativePath}`);
      }
    }
  }

  if (diagnostics.length > 0) {
    const visible = diagnostics.slice(0, maximumDiagnostics);
    if (diagnostics.length > visible.length) {
      visible.push(
        `additional bridge contract errors omitted: ${diagnostics.length - visible.length}`,
      );
    }
    fail(visible.join("\n"));
  }
}

function readClientErrorSchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  const expected = [
    "code",
    "stage",
    "component",
    "retryable",
    "recovery",
    "presentationArgs",
  ];
  if (
    !isRecord(schema) ||
    schema.title !== "ClientError" ||
    schema.version !== 1 ||
    !Array.isArray(schema.fields) ||
    schema.fields.map(({ name }) => name).join("\0") !== expected.join("\0")
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  for (const field of schema.fields) {
    if (
      field.type === "enum" &&
      (!Array.isArray(field.values) ||
        field.values.length === 0 ||
        new Set(field.values).size !== field.values.length)
    ) {
      fail(`invalid enum in active bridge schema: ${family.schema}`);
    }
  }
  const presentationArgs = schema.fields.find(
    ({ name }) => name === "presentationArgs",
  );
  if (
    presentationArgs.type !== "bounded_string_map" ||
    presentationArgs.maxEntries !== 4 ||
    presentationArgs.maxKeyBytes !== 32 ||
    presentationArgs.maxValueBytes !== 96 ||
    !Array.isArray(presentationArgs.allowedKeys) ||
    presentationArgs.allowedKeys.length === 0 ||
    new Set(presentationArgs.allowedKeys).size !==
      presentationArgs.allowedKeys.length ||
    presentationArgs.allowedKeys.some(
      (key) => typeof key !== "string" || key.length === 0 || key.length > 32,
    )
  ) {
    fail(`invalid presentation arguments in active bridge schema: ${family.schema}`);
  }
  return schema;
}

function readStateSchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  if (
    !isRecord(schema) ||
    schema.title !== "ClientState" ||
    schema.version !== 1 ||
    !Number.isSafeInteger(schema.maxDocumentBytes) ||
    schema.maxDocumentBytes <= 0 ||
    schema.maxDocumentBytes > 16 * 1024 * 1024 ||
    !Array.isArray(schema.collections) ||
    schema.collections.length !== 15 ||
    new Set(schema.collections).size !== schema.collections.length ||
    schema.collections.some(
      (value) =>
        typeof value !== "string" ||
        !/^[a-z][a-z0-9-]{0,63}$/u.test(value),
    ) ||
    JSON.stringify(schema.operations) !== JSON.stringify(["get", "set", "admit"]) ||
    !Array.isArray(schema.failureCodes) ||
    JSON.stringify(schema.failureCodes) !==
      JSON.stringify([
        "invalid_collection",
        "invalid_document",
        "state_operation_failed",
        "migration_lock_unavailable",
        "migration_ledger_invalid",
        "state_newer_than_binary",
        "migration_frontier_incomplete",
        "migration_step_failed",
        "migration_postcondition_failed",
        "update_handoff_mismatch",
        "unsupported_state_shape",
      ])
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  return schema;
}

function readConversationSchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  const validValues = (values, pattern = /^[a-z][a-z0-9-]*$/u) =>
    Array.isArray(values) &&
    values.length > 0 &&
    new Set(values).size === values.length &&
    values.every((value) => typeof value === "string" && pattern.test(value));
  const expectedActions = [
    "conversation.create",
    "conversation.rename",
    "conversation.archive",
    "conversation.clear",
    "conversation.strategy.set",
    "conversation.list",
    "conversation.get",
    "conversation.events.page",
    "conversation.events.search",
    "conversation.event.append",
    "conversation.message.post",
    "conversation.dispatch.after-post",
    "conversation.event.part.append",
    "conversation.event.finalize",
    "conversation.membership.add",
    "conversation.membership.access.set",
    "conversation.membership.leave",
    "conversation.export",
    "conversation.import",
    "conversation.assistant.set",
    "conversation.profile.update",
    "conversation.profile.get",
    "conversation.profile.candidates",
    "conversation.subagent.edge",
  ];
  if (
    !isRecord(schema) ||
    schema.title !== "ConversationBridge" ||
    schema.version !== 1 ||
    !Number.isSafeInteger(schema.maxRequestBytes) ||
    schema.maxRequestBytes <= 0 ||
    schema.maxRequestBytes > 16 * 1024 * 1024 ||
    schema.defaultEventPageSize !== 20 ||
    schema.maxEventPageSize !== 100 ||
    JSON.stringify(schema.actions) !== JSON.stringify(expectedActions) ||
    !validValues(schema.principalKinds) ||
    !validValues(schema.membershipAccess) ||
    !validValues(schema.membershipStatuses) ||
    !validValues(schema.turnStates) ||
    !validValues(schema.eventKinds) ||
    !validValues(schema.eventPartKinds) ||
    !validValues(schema.failureCodes, /^[a-z][a-z0-9_]*$/u)
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  schema.continuousAssistant = readContinuousAssistant(schema, family.schema);
  return schema;
}

function continuityTypeName(name) {
  return name.startsWith("Continuity") ? name : `Continuity${name}`;
}

function uniqueStrings(values, pattern, label) {
  if (
    !Array.isArray(values) ||
    values.length === 0 ||
    new Set(values).size !== values.length ||
    values.some((value) => typeof value !== "string" || !pattern.test(value))
  ) {
    fail(`invalid continuity ${label}`);
  }
  return values;
}

function parseContinuityFieldType(raw) {
  if (typeof raw !== "string") fail("invalid continuity field type");
  if (raw.startsWith("optional:")) {
    return { optional: true, ...parseContinuityFieldType(raw.slice(9)) };
  }
  if (raw.startsWith("array:")) {
    return { array: true, ...parseContinuityFieldType(raw.slice(6)) };
  }
  if (raw.startsWith("enum:")) return { kind: "enum", name: raw.slice(5) };
  if (raw.startsWith("struct:")) return { kind: "struct", name: raw.slice(7) };
  if (raw.startsWith("union:")) return { kind: "union", name: raw.slice(6) };
  if (
    raw === "id" ||
    raw === "label" ||
    raw === "reason" ||
    raw === "digest" ||
    raw === "string" ||
    raw === "i64" ||
    raw === "u64" ||
    raw === "bool"
  ) {
    return { kind: raw };
  }
  fail(`unsupported continuity field type: ${raw}`);
}

function dartContinuityInner(type) {
  switch (type.kind) {
    case "id":
    case "label":
    case "reason":
    case "digest":
    case "string":
      return "String";
    case "i64":
    case "u64":
      return "int";
    case "bool":
      return "bool";
    case "enum":
    case "struct":
    case "union":
      return continuityTypeName(type.name);
    default:
      fail(`unsupported continuity dart type: ${type.kind}`);
  }
}

function dartContinuityType(type) {
  const inner = dartContinuityInner(type);
  if (type.array) return `List<${inner}>`;
  if (type.optional) return `${inner}?`;
  return inner;
}

function readContinuousAssistant(schema, schemaPath) {
  if (!isRecord(schema.continuousAssistant)) {
    fail("conversation schema must include continuousAssistant");
  }
  const continuity = schema.continuousAssistant;
  const kebab = /^[a-z][a-z0-9-]*$/u;
  const snake = /^[a-z][a-z0-9_]*$/u;
  const stage = /^continuity\/[a-z][a-z0-9-]*$/u;
  const typeName = /^[A-Z][A-Za-z0-9]*$/u;
  if (
    !isRecord(continuity) ||
    continuity.schemaId !== "lico.continuous-assistant.v1" ||
    continuity.version !== 1 ||
    continuity.spanEncoding !== "utf8-byte-range" ||
    continuity.maxPageSize !== 50 ||
    continuity.maxOrientationItems !== 32 ||
    continuity.maxRefs !== 64 ||
    continuity.maxIdBytes !== 128 ||
    continuity.maxLabelBytes !== 256 ||
    continuity.maxReasonBytes !== 128 ||
    continuity.maxDigestBytes !== 128
  ) {
    fail(`unsupported continuous assistant schema in ${schemaPath}`);
  }
  uniqueStrings(continuity.decisionLayers, kebab, "decisionLayers");
  uniqueStrings(continuity.effectClasses, kebab, "effectClasses");
  uniqueStrings(continuity.commands, kebab, "commands");
  uniqueStrings(continuity.ports, kebab, "ports");
  uniqueStrings(continuity.m1Leaves, kebab, "m1Leaves");
  uniqueStrings(continuity.failureCodes, snake, "failureCodes");
  uniqueStrings(continuity.recoveryClasses, snake, "recoveryClasses");
  uniqueStrings(continuity.failureStages, stage, "failureStages");
  if (
    !isRecord(continuity.enums) ||
    !isRecord(continuity.structs) ||
    !isRecord(continuity.unions)
  ) {
    fail(`invalid continuous assistant type tables in ${schemaPath}`);
  }
  if (
    JSON.stringify(continuity.enums.FailureCode) !==
      JSON.stringify(continuity.failureCodes) ||
    JSON.stringify(continuity.enums.FailureStage) !==
      JSON.stringify(continuity.failureStages) ||
    JSON.stringify(continuity.enums.RecoveryClass) !==
      JSON.stringify(continuity.recoveryClasses) ||
    JSON.stringify(continuity.enums.EffectClass) !==
      JSON.stringify(continuity.effectClasses) ||
    JSON.stringify(continuity.enums.DecisionLayer) !==
      JSON.stringify(continuity.decisionLayers)
  ) {
    fail("continuous assistant closed lists must match enum tables");
  }
  for (const [name, values] of Object.entries(continuity.enums)) {
    if (!typeName.test(name)) fail(`invalid continuity enum name: ${name}`);
    uniqueStrings(
      values,
      name === "FailureStage" ? stage : name.endsWith("Code") || name.endsWith("Class")
        ? snake
        : kebab,
      `enum ${name}`,
    );
  }
  for (const [name, definition] of Object.entries(continuity.structs)) {
    if (!typeName.test(name) || !isRecord(definition) || !Array.isArray(definition.fields)) {
      fail(`invalid continuity struct: ${name}`);
    }
    const fieldNames = new Set();
    for (const field of definition.fields) {
      if (
        !isRecord(field) ||
        typeof field.name !== "string" ||
        !/^[a-z][A-Za-z0-9]*$/u.test(field.name) ||
        fieldNames.has(field.name)
      ) {
        fail(`invalid continuity field on ${name}`);
      }
      fieldNames.add(field.name);
      parseContinuityFieldType(field.type);
    }
  }
  for (const [name, definition] of Object.entries(continuity.unions)) {
    if (
      !typeName.test(name) ||
      !isRecord(definition) ||
      definition.tag !== "kind" ||
      !isRecord(definition.variants)
    ) {
      fail(`invalid continuity union: ${name}`);
    }
    for (const [variant, fields] of Object.entries(definition.variants)) {
      if (!kebab.test(variant) || !Array.isArray(fields)) {
        fail(`invalid continuity union variant: ${name}.${variant}`);
      }
      for (const field of fields) {
        if (!isRecord(field) || typeof field.name !== "string") {
          fail(`invalid continuity union field: ${name}.${variant}`);
        }
        parseContinuityFieldType(field.type);
      }
    }
  }
  return continuity;
}

function dartRequiredEnumParse(typeName, expression) {
  return `(() {
      final parsed = ${typeName}.fromWire(${expression});
      if (parsed == ${typeName}.unrecognized) {
        throw const ContinuityContractException(
          ContinuityFailureCode.invalidRequest,
        );
      }
      return parsed;
    })()`;
}

function dartContinuityEnum(name, values) {
  const entries = values.map((value) => {
    const member = pascal(value);
    const rawCamelMember = member[0].toLowerCase() + member.slice(1);
    const camelMember = DART_RESERVED_WORDS.has(rawCamelMember)
      ? `${rawCamelMember}Value`
      : rawCamelMember;
    const line = `  ${camelMember}(${JSON.stringify(value)}),`;
    return line.length <= 80
      ? line
      : `  ${camelMember}(\n    ${JSON.stringify(value)},\n  ),`;
  });
  const condition =
    `      if (candidate != ${name}.unrecognized && candidate.wireName == value) {`;
  const formattedCondition = condition.length <= 80
    ? condition
    : `      if (candidate != ${name}.unrecognized &&\n          candidate.wireName == value) {`;
  return `enum ${name} {
${entries.join("\n")}
  unrecognized('');

  const ${name}(this.wireName);
  final String wireName;

  static ${name} fromWire(Object? value) {
    if (value is! String) return ${name}.unrecognized;
    for (final candidate in ${name}.values) {
${formattedCondition}
        return candidate;
      }
    }
    return ${name}.unrecognized;
  }
}
`;
}

function dartParseExpression(type, expression) {
  if (type.array) {
    const inner = { ...type, array: false };
    return `_continuityList(${expression})
            .map((item) => ${dartParseExpression(inner, "item")})
            .toList(growable: false)`;
  }
  switch (type.kind) {
    case "id":
    case "label":
    case "reason":
    case "digest":
    case "string":
      return `_continuityString(${expression})`;
    case "i64":
    case "u64":
      return `_continuityInt(${expression})`;
    case "bool":
      return `_continuityBool(${expression})`;
    case "enum":
      return dartRequiredEnumParse(continuityTypeName(type.name), expression);
    case "struct":
    case "union":
      return `${continuityTypeName(type.name)}.parse(${expression})`;
    default:
      fail(`unsupported continuity dart parse: ${type.kind}`);
  }
}

function dartFieldParse(field) {
  const type = parseContinuityFieldType(field.type);
  const read = `json[${JSON.stringify(field.name)}]`;
  if (type.optional) {
    return `${field.name}: json.containsKey(${JSON.stringify(field.name)}) && ${read} != null ? ${dartParseExpression({ ...type, optional: false }, read)} : null`;
  }
  return `${field.name}: ${dartParseExpression(type, read)}`;
}

function dartFieldToJson(field) {
  const type = parseContinuityFieldType(field.type);
  const value = field.name;
  if (type.optional) {
    return `    if (${value} != null) {\n      json[${JSON.stringify(field.name)}] = ${dartToJsonExpression({ ...type, optional: false }, `${value}!`)};\n    }`;
  }
  return `    json[${JSON.stringify(field.name)}] = ${dartToJsonExpression(type, value)};`;
}

function dartToJsonExpression(type, expression) {
  if (type.array) {
    const inner = { ...type, array: false };
    return `${expression}.map((item) => ${dartToJsonExpression(inner, "item")}).toList(growable: false)`;
  }
  switch (type.kind) {
    case "id":
    case "label":
    case "reason":
    case "digest":
    case "string":
    case "i64":
    case "u64":
    case "bool":
      return expression;
    case "enum":
      return `${expression}.wireName`;
    case "struct":
    case "union":
      return `${expression}.toJson()`;
    default:
      fail(`unsupported continuity dart emit: ${type.kind}`);
  }
}

function dartContinuityStruct(name, definition) {
  const typeName = continuityTypeName(name);
  const allowed = definition.fields.map((field) => field.name);
  return `final class ${typeName} {
  const ${typeName}({
${definition.fields
  .map((field) => {
    const type = parseContinuityFieldType(field.type);
    return type.optional
      ? `    this.${field.name},`
      : `    required this.${field.name},`;
  })
  .join("\n")}
  });

  factory ${typeName}.parse(Object? value) {
    if (value is! Map) {
      throw const ContinuityContractException(
        ContinuityFailureCode.invalidRequest,
      );
    }
    final json = Map<Object?, Object?>.from(value);
    _continuityRejectUnknownKeys(json, const {${allowed.map((key) => JSON.stringify(key)).join(", ")}});
    return ${typeName}(
${definition.fields.map((field) => `      ${dartFieldParse(field)},`).join("\n")}
    );
  }

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
${definition.fields.map((field) => dartFieldToJson(field)).join("\n")}
    return json;
  }

${definition.fields
  .map((field) => {
    const type = parseContinuityFieldType(field.type);
    return `  final ${dartContinuityType(type)} ${field.name};`;
  })
  .join("\n")}
}
`;
}

function dartContinuityUnion(name, definition) {
  const typeName = continuityTypeName(name);
  const variants = Object.entries(definition.variants);
  const factories = variants
    .map(([wire, fields]) => {
      const variantName = pascal(wire);
      const className = `${typeName}${variantName}`;
      const params = fields
        .map((field) => {
          const type = parseContinuityFieldType(field.type);
          return type.optional
            ? `    this.${field.name},`
            : `    required this.${field.name},`;
        })
        .join("\n");
      const members = fields
        .map((field) => {
          const type = parseContinuityFieldType(field.type);
          return `  final ${dartContinuityType(type)} ${field.name};`;
        })
        .join("\n");
      const allowed = ["kind", ...fields.map((field) => field.name)];
      return `final class ${className} extends ${typeName} {
  const ${className}({
${params}
  });

  factory ${className}.parse(Map<Object?, Object?> json) {
    _continuityRejectUnknownKeys(json, const {${allowed.map((key) => JSON.stringify(key)).join(", ")}});
    return ${className}(
${fields.map((field) => `      ${dartFieldParse(field)},`).join("\n")}
    );
  }

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'kind': ${JSON.stringify(wire)}};
${fields.map((field) => dartFieldToJson(field)).join("\n")}
    return json;
  }

${members}
}
`;
    })
    .join("\n");
  const parseCases = variants
    .map(([wire, ,]) => {
      const variantName = pascal(wire);
      return `      case ${JSON.stringify(wire)}:\n        return ${typeName}${variantName}.parse(json);`;
    })
    .join("\n");
  return `sealed class ${typeName} {
  const ${typeName}();

  factory ${typeName}.parse(Object? value) {
    if (value is! Map) {
      throw const ContinuityContractException(
        ContinuityFailureCode.invalidRequest,
      );
    }
    final json = Map<Object?, Object?>.from(value);
    switch (json['kind']) {
${parseCases}
      default:
        throw const ContinuityContractException(
          ContinuityFailureCode.invalidRequest,
        );
    }
  }

  Map<String, Object?> toJson();
}

${factories}`;
}

function dartContinuityTypes(continuity) {
  const enums = Object.entries(continuity.enums)
    .map(([name, values]) => dartContinuityEnum(continuityTypeName(name), values))
    .join("\n");
  const structs = Object.entries(continuity.structs)
    .map(([name, definition]) => dartContinuityStruct(name, definition))
    .join("\n");
  const unions = Object.entries(continuity.unions)
    .map(([name, definition]) => dartContinuityUnion(name, definition))
    .join("\n");
  return `
const String continuityBridgeSchemaVersion = ${JSON.stringify(continuity.schemaId)};
const String continuitySpanEncoding = ${JSON.stringify(continuity.spanEncoding)};
const int continuityMaxPageSize = ${continuity.maxPageSize};
const int continuityMaxOrientationItems = ${continuity.maxOrientationItems};
const int continuityMaxRefs = ${continuity.maxRefs};
const int continuityMaxIdBytes = ${continuity.maxIdBytes};
const int continuityMaxLabelBytes = ${continuity.maxLabelBytes};
const int continuityMaxReasonBytes = ${continuity.maxReasonBytes};
const int continuityMaxDigestBytes = ${continuity.maxDigestBytes};

${enums}
${dartContinuityEnum("ContinuityCommand", continuity.commands)}
${dartContinuityEnum("ContinuityPort", continuity.ports)}

final class ContinuityContractException implements Exception {
  const ContinuityContractException(this.code);
  final ContinuityFailureCode code;
}

void _continuityRejectUnknownKeys(
  Map<Object?, Object?> json,
  Set<String> allowed,
) {
  for (final key in json.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw const ContinuityContractException(
        ContinuityFailureCode.invalidRequest,
      );
    }
  }
}

String _continuityString(Object? value) {
  if (value is String) return value;
  throw const ContinuityContractException(ContinuityFailureCode.invalidRequest);
}

int _continuityInt(Object? value) {
  if (value is int) return value;
  throw const ContinuityContractException(ContinuityFailureCode.invalidRequest);
}

bool _continuityBool(Object? value) {
  if (value is bool) return value;
  throw const ContinuityContractException(ContinuityFailureCode.invalidRequest);
}

List<Object?> _continuityList(Object? value) {
  if (value is List) return List<Object?>.from(value);
  throw const ContinuityContractException(ContinuityFailureCode.invalidRequest);
}

bool continuityUtf8SpanIsValid(String text, int startByte, int endByte) {
  final bytes = utf8.encode(text);
  if (startByte < 0 || endByte < startByte || endByte > bytes.length) {
    return false;
  }
  return _continuityUtf8Boundary(bytes, startByte) &&
      _continuityUtf8Boundary(bytes, endByte);
}

bool _continuityUtf8Boundary(List<int> bytes, int index) {
  if (index == 0 || index == bytes.length) return true;
  return (bytes[index] & 0xc0) != 0x80;
}

${structs}
${unions}
`;
}

function dartConversationOutput(schema, schemaPath) {
  const enums = [
    ["ConversationPrincipalKind", schema.principalKinds],
    ["ConversationMembershipAccess", schema.membershipAccess],
    ["ConversationMembershipStatus", schema.membershipStatuses],
    ["ConversationTurnState", schema.turnStates],
    ["ConversationEventKind", schema.eventKinds],
    ["ConversationEventPartKind", schema.eventPartKinds],
    ["ConversationFailureCode", schema.failureCodes],
    ["ConversationActionKind", schema.actions],
  ];
  return `// @generated by ${schemaPath}; do not edit.
import 'dart:convert';

${enums.map(([name, values]) => dartEnum(name, values)).join("\n")}
const String conversationBridgeSchemaVersion = 'lico.conversation.v1';
const int conversationBridgeMaxRequestBytes = ${schema.maxRequestBytes};
const int conversationBridgeDefaultEventPageSize = ${schema.defaultEventPageSize};
const int conversationBridgeMaxEventPageSize = ${schema.maxEventPageSize};
${dartContinuityTypes(schema.continuousAssistant)}
`;
}

function readStrategySchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  const validValues = (values, pattern) =>
    Array.isArray(values) &&
    values.length > 0 &&
    new Set(values).size === values.length &&
    values.every((value) => typeof value === "string" && pattern.test(value));
  const expectedActions = [
    "strategy.package.prepare-import",
    "strategy.package.commit-import",
    "strategy.definition.list",
    "strategy.definition.inspect",
    "strategy.runtime.discover",
    "strategy.runtime.list",
    "strategy.binding.update",
    "strategy.binding.replace",
    "strategy.binding.remove",
    "strategy.authorization.preview",
    "strategy.authorization.grant",
    "strategy.authorization.revoke",
    "strategy.run.start",
    "strategy.run.inspect",
    "strategy.run.active",
    "strategy.run.resume",
    "strategy.run.cancel",
    "strategy.run.retry",
    "strategy.assistant.workflow.execute",
    "strategy.assistant.workflow.inspect",
    "strategy.assistant.workflow.cancel",
  ];
  if (
    !isRecord(schema) ||
    schema.title !== "StrategyBridge" ||
    schema.version !== 1 ||
    schema.maxRequestBytes !== 1024 * 1024 ||
    schema.maxPackageBytes !== 8 * 1024 * 1024 ||
    schema.maxStates !== 512 ||
    schema.maxTransitions !== 2048 ||
    schema.maxParallelism !== 8 ||
    JSON.stringify(schema.actions) !== JSON.stringify(expectedActions) ||
    !validValues(schema.bindingKinds, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.runtimeKinds, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.stateKinds, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.transitionModes, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.callbackDecisions, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.runStatuses, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.failureCodes, /^[a-z][a-z0-9_]*$/u) ||
    !validValues(schema.diagnosticStages, /^[a-z][a-z0-9/-]*$/u) ||
    !validValues(schema.diagnosticCodes, /^[a-z][a-z0-9_]*$/u) ||
    !validValues(schema.diagnosticRecoveries, /^[a-z][a-z0-9_]*$/u) ||
    !validValues(schema.diagnosticExpectedKinds, /^[a-z][a-z0-9_]*$/u) ||
    !validValues(schema.diagnosticActualKinds, /^[a-z][a-z0-9_]*$/u) ||
    schema.maxDiagnostics !== 128 ||
    schema.maxDiagnosticPathBytes !== 256 ||
    schema.maxDiagnosticRelatedPaths !== 8
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  return schema;
}

function dartStrategyOutput(schema, schemaPath) {
  const enums = [
    ["StrategyBindingKind", schema.bindingKinds],
    ["StrategyRuntimeKind", schema.runtimeKinds],
    ["StrategyStateKind", schema.stateKinds],
    ["StrategyTransitionMode", schema.transitionModes],
    ["StrategyCallbackDecision", schema.callbackDecisions],
    ["StrategyRunStatus", schema.runStatuses],
    ["StrategyFailureCode", schema.failureCodes],
    ["StrategyWorkflowDiagnosticStage", schema.diagnosticStages],
    ["StrategyWorkflowDiagnosticCode", schema.diagnosticCodes],
    ["StrategyWorkflowDiagnosticRecovery", schema.diagnosticRecoveries],
    ["StrategyWorkflowDiagnosticExpected", schema.diagnosticExpectedKinds],
    ["StrategyWorkflowDiagnosticActualKind", schema.diagnosticActualKinds],
    ["StrategyActionKind", schema.actions],
  ];
  return `// @generated by ${schemaPath}; do not edit.
${enums.map(([name, values]) => dartEnum(name, values)).join("\n")}
const String strategyBridgeSchemaVersion = 'licoup.adaptive-flywheel.bridge.v1';
const int strategyBridgeMaxRequestBytes = ${schema.maxRequestBytes};
const int strategyBridgeMaxPackageBytes = ${schema.maxPackageBytes};
const int strategyBridgeMaxStates = ${schema.maxStates};
const int strategyBridgeMaxTransitions = ${schema.maxTransitions};
const int strategyBridgeMaxParallelism = ${schema.maxParallelism};
const int strategyWorkflowMaxDiagnostics = ${schema.maxDiagnostics};
const int strategyWorkflowMaxDiagnosticPathBytes = ${schema.maxDiagnosticPathBytes};
const int strategyWorkflowMaxRelatedPaths = ${schema.maxDiagnosticRelatedPaths};

final class StrategyWorkflowDiagnostic {
  const StrategyWorkflowDiagnostic({
    required this.code,
    required this.stage,
    this.path = '',
    this.relatedPaths = const [],
    this.membershipId = '',
    this.actual,
    this.limit,
    this.expected = StrategyWorkflowDiagnosticExpected.unknown,
    this.actualKind = StrategyWorkflowDiagnosticActualKind.unknown,
    this.recovery = StrategyWorkflowDiagnosticRecovery.unknown,
    this.line,
    this.column,
  });

  factory StrategyWorkflowDiagnostic.fromJson(Map<String, dynamic> json) {
    final parsedCode = StrategyWorkflowDiagnosticCode.fromWire(json['code']);
    final code = parsedCode == StrategyWorkflowDiagnosticCode.unknown
        ? StrategyWorkflowDiagnosticCode.workflowInvalid
        : parsedCode;
    final parsedStage = StrategyWorkflowDiagnosticStage.fromWire(json['stage']);
    final stage = parsedStage == StrategyWorkflowDiagnosticStage.unknown
        ? StrategyWorkflowDiagnosticStage.workflowCompile
        : parsedStage;
    if (code == StrategyWorkflowDiagnosticCode.workflowSyntaxInvalid) {
      return StrategyWorkflowDiagnostic(
        code: code,
        stage: StrategyWorkflowDiagnosticStage.workflowParse,
        line: _strategyWorkflowNonNegativeInt(json['line']),
        column: _strategyWorkflowNonNegativeInt(json['column']),
      );
    }
    final rawPath = json['path'] is String ? json['path'] as String : '';
    final relatedPaths = json['relatedPaths'] is List
        ? (json['relatedPaths'] as List)
              .whereType<String>()
              .where(_strategyWorkflowValidPointer)
              .take(strategyWorkflowMaxRelatedPaths)
              .toList(growable: false)
        : const <String>[];
    final membership = json['membershipId'] is String
        ? json['membershipId'] as String
        : '';
    return StrategyWorkflowDiagnostic(
      code: code,
      stage: stage,
      path: _strategyWorkflowValidPointer(rawPath) ? rawPath : '',
      relatedPaths: relatedPaths,
      membershipId:
          (stage ==
                      StrategyWorkflowDiagnosticStage
                          .assistantWorkflowPreflight ||
                  stage ==
                      StrategyWorkflowDiagnosticStage
                          .assistantWorkflowRevalidate) &&
              _strategyWorkflowValidId(membership)
          ? membership
          : '',
      actual: _strategyWorkflowNonNegativeInt(json['actual']),
      limit: _strategyWorkflowNonNegativeInt(json['limit']),
      expected: StrategyWorkflowDiagnosticExpected.fromWire(json['expected']),
      actualKind: StrategyWorkflowDiagnosticActualKind.fromWire(
        json['actualKind'],
      ),
      recovery: StrategyWorkflowDiagnosticRecovery.fromWire(json['recovery']),
      line: _strategyWorkflowNonNegativeInt(json['line']),
      column: _strategyWorkflowNonNegativeInt(json['column']),
    );
  }

  final StrategyWorkflowDiagnosticCode code;
  final StrategyWorkflowDiagnosticStage stage;
  final String path;
  final List<String> relatedPaths;
  final String membershipId;
  final int? actual;
  final int? limit;
  final StrategyWorkflowDiagnosticExpected expected;
  final StrategyWorkflowDiagnosticActualKind actualKind;
  final StrategyWorkflowDiagnosticRecovery recovery;
  final int? line;
  final int? column;
}

int? _strategyWorkflowNonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

bool _strategyWorkflowValidId(String value) =>
    value.isNotEmpty &&
    value.length <= strategyWorkflowMaxDiagnosticPathBytes &&
    RegExp(r'^[A-Za-z0-9:._-]+$').hasMatch(value);

bool _strategyWorkflowValidPointer(String value) {
  if (value.isEmpty) return true;
  if (value.length > strategyWorkflowMaxDiagnosticPathBytes ||
      !value.startsWith('/')) {
    return false;
  }
  for (var index = 0; index < value.length; index += 1) {
    if (value.codeUnitAt(index) != 0x7e) continue;
    index += 1;
    if (index >= value.length ||
        (value.codeUnitAt(index) != 0x30 && value.codeUnitAt(index) != 0x31)) {
      return false;
    }
  }
  return true;
}
`;
}

function pascal(value) {
  return value
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
}

function enumField(schema, name) {
  return schema.fields.find((field) => field.name === name).values;
}

const DART_RESERVED_WORDS = new Set([
  "assert",
  "break",
  "case",
  "catch",
  "class",
  "const",
  "continue",
  "default",
  "do",
  "else",
  "enum",
  "extends",
  "false",
  "final",
  "finally",
  "for",
  "if",
  "in",
  "is",
  "new",
  "null",
  "rethrow",
  "return",
  "super",
  "switch",
  "this",
  "throw",
  "true",
  "try",
  "var",
  "void",
  "while",
  "with",
]);

function dartEnum(name, values) {
  const entries = values.map((value) => {
    const member = pascal(value);
    const rawCamelMember = member[0].toLowerCase() + member.slice(1);
    const camelMember = DART_RESERVED_WORDS.has(rawCamelMember)
      ? `${rawCamelMember}Value`
      : rawCamelMember;
    const line = `  ${camelMember}(${JSON.stringify(value)}),`;
    return line.length <= 80
      ? line
      : `  ${camelMember}(\n    ${JSON.stringify(value)},\n  ),`;
  });
  const condition =
    `      if (candidate != ${name}.unknown && candidate.wireName == value) {`;
  const formattedCondition = condition.length <= 80
    ? condition
    : `      if (candidate != ${name}.unknown &&\n          candidate.wireName == value) {`;
  return `enum ${name} {
${entries.join("\n")}
  unknown('');

  const ${name}(this.wireName);
  final String wireName;

  static ${name} fromWire(Object? value) {
    if (value is! String) return ${name}.unknown;
    for (final candidate in ${name}.values) {
${formattedCondition}
        return candidate;
      }
    }
    return ${name}.unknown;
  }
}
`;
}

function dartClientErrorOutput(schema, schemaPath) {
  const allowedKeys = schema.fields.find(
    ({ name }) => name === "presentationArgs",
  ).allowedKeys;
  return `// @generated by ${schemaPath}; do not edit.
${dartEnum("ClientErrorCode", enumField(schema, "code"))}
${dartEnum("ClientErrorStage", enumField(schema, "stage"))}
${dartEnum("ClientErrorComponent", enumField(schema, "component"))}
${dartEnum("ClientErrorRecovery", enumField(schema, "recovery"))}
final class ClientError {
  const ClientError({
    required this.code,
    required this.stage,
    required this.component,
    required this.retryable,
    required this.recovery,
    this.presentationArgs = const <String, String>{},
  });

  factory ClientError.fromJson(Map<String, Object?> json) {
    final rawArgs = json['presentationArgs'];
    final args = <String, String>{};
    if (rawArgs is Map) {
      for (final entry in rawArgs.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String &&
            value is String &&
            _allowedPresentationKeys.contains(key) &&
            key.length <= 32 &&
            value.length <= 96 &&
            args.length < 4) {
          args[key] = value;
        }
      }
    }
    return ClientError(
      code: ClientErrorCode.fromWire(json['code']),
      stage: ClientErrorStage.fromWire(json['stage']),
      component: ClientErrorComponent.fromWire(json['component']),
      retryable: json['retryable'] == true,
      recovery: ClientErrorRecovery.fromWire(json['recovery']),
      presentationArgs: Map.unmodifiable(args),
    );
  }

  final ClientErrorCode code;
  final ClientErrorStage stage;
  final ClientErrorComponent component;
  final bool retryable;
  final ClientErrorRecovery recovery;
  final Map<String, String> presentationArgs;

  bool get isUnknown =>
      code == ClientErrorCode.unknown ||
      stage == ClientErrorStage.unknown ||
      component == ClientErrorComponent.unknown ||
      recovery == ClientErrorRecovery.unknown;

  Map<String, Object> toJson() => <String, Object>{
    'code': code.wireName,
    'stage': stage.wireName,
    'component': component.wireName,
    'retryable': retryable,
    'recovery': recovery.wireName,
    'presentationArgs': presentationArgs,
  };

  static const _allowedPresentationKeys = <String>{
${allowedKeys.map((key) => `    ${JSON.stringify(key)},`).join("\n")}
  };
}
`;
}

function dartStateOutput(schema, schemaPath) {
  return `// @generated by ${schemaPath}; do not edit.
import 'dart:convert';

const int clientStateMaxDocumentBytes = ${schema.maxDocumentBytes};
const String clientStateSchemaVersion = 'v0.0.1:schema:definition-1';

${dartEnum("ClientStateCollection", schema.collections)}
final class ClientStateDocument {
  ClientStateDocument({
    required this.schemaVersion,
    required this.collection,
    Map<String, Object?> content = const <String, Object?>{},
  }) : content = Map<String, Object?>.unmodifiable(content) {
    _validate();
  }

  factory ClientStateDocument.fromJson(Map<String, Object?> json) {
    final collection = ClientStateCollection.fromWire(json['collection']);
    if (collection == ClientStateCollection.unknown) {
      throw const FormatException('invalid_collection');
    }
    final content = Map<String, Object?>.from(json)
      ..remove('schemaVersion')
      ..remove('collection');
    return ClientStateDocument(
      schemaVersion: json['schemaVersion'] is String
          ? json['schemaVersion']! as String
          : '',
      collection: collection,
      content: content,
    );
  }

  final String schemaVersion;
  final ClientStateCollection collection;
  final Map<String, Object?> content;

  void _validate() {
    if (schemaVersion != clientStateSchemaVersion ||
        collection == ClientStateCollection.unknown) {
      throw const FormatException('invalid_document');
    }
    try {
      if (utf8.encode(jsonEncode(toJson())).length >
          clientStateMaxDocumentBytes) {
        throw const FormatException('invalid_document');
      }
    } on JsonUnsupportedObjectError {
      throw const FormatException('invalid_document');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'collection': collection.wireName,
    ...content,
  };
}

final class ClientStateGetRequest {
  const ClientStateGetRequest({required this.collection});
  final ClientStateCollection collection;
  Map<String, Object?> toJson() => <String, Object?>{
    'collection': collection.wireName,
  };
}

final class ClientStateSetRequest {
  ClientStateSetRequest({required this.collection, required this.document}) {
    if (collection == ClientStateCollection.unknown ||
        collection != document.collection) {
      throw const FormatException('invalid_document');
    }
  }
  final ClientStateCollection collection;
  final ClientStateDocument document;
  Map<String, Object?> toJson() => <String, Object?>{
    'collection': collection.wireName,
    'document': document.toJson(),
  };
}

final class ClientStateGetResult {
  const ClientStateGetResult({
    required this.collection,
    required this.document,
  });

  factory ClientStateGetResult.fromJson(Map<String, Object?> json) {
    final collection = ClientStateCollection.fromWire(json['collection']);
    final rawDocument = json['document'];
    if (json['ok'] != true ||
        collection == ClientStateCollection.unknown ||
        rawDocument is! Map) {
      throw const FormatException('invalid_state_response');
    }
    final document = ClientStateDocument.fromJson(
      Map<String, Object?>.from(rawDocument),
    );
    if (collection != document.collection) {
      throw const FormatException('invalid_state_response');
    }
    return ClientStateGetResult(collection: collection, document: document);
  }

  final ClientStateCollection collection;
  final ClientStateDocument document;
}

final class ClientStateActivity {
  const ClientStateActivity({
    required this.schemaVersion,
    required this.eventId,
    required this.type,
    required this.target,
    required this.createdAt,
  });

  factory ClientStateActivity.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw const FormatException('invalid_state_response');
      }
      return value;
    }

    final schemaVersion = requiredString('schemaVersion');
    if (schemaVersion != clientStateSchemaVersion) {
      throw const FormatException('invalid_state_response');
    }
    return ClientStateActivity(
      schemaVersion: schemaVersion,
      eventId: requiredString('eventId'),
      type: requiredString('type'),
      target: requiredString('target'),
      createdAt: requiredString('createdAt'),
    );
  }

  final String schemaVersion;
  final String eventId;
  final String type;
  final String target;
  final String createdAt;
}

final class ClientStateSetResult {
  const ClientStateSetResult({
    required this.collection,
    required this.document,
    required this.activity,
  });

  factory ClientStateSetResult.fromJson(Map<String, Object?> json) {
    final get = ClientStateGetResult.fromJson(json);
    final rawActivity = json['activity'];
    if (rawActivity is! Map) {
      throw const FormatException('invalid_state_response');
    }
    return ClientStateSetResult(
      collection: get.collection,
      document: get.document,
      activity: ClientStateActivity.fromJson(
        Map<String, Object?>.from(rawActivity),
      ),
    );
  }

  final ClientStateCollection collection;
  final ClientStateDocument document;
  final ClientStateActivity activity;
}

${dartEnum("ClientStateFailureCode", schema.failureCodes)}
final class ClientStateFailure implements Exception {
  const ClientStateFailure({required this.code});

  factory ClientStateFailure.fromJson(Map<String, Object?> json) =>
      ClientStateFailure(code: ClientStateFailureCode.fromWire(json['code']));

  final ClientStateFailureCode code;

  Map<String, Object> toJson() => <String, Object>{'code': code.wireName};

  @override
  String toString() => 'ClientStateFailure(\${code.wireName})';
}
`;
}

function readPackageSchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  const validValues = (values, pattern) =>
    Array.isArray(values) &&
    values.length > 0 &&
    new Set(values).size === values.length &&
    values.every((value) => typeof value === "string" && pattern.test(value));
  const expectedOperations = [
    "package.catalog",
    "package.install.plan",
    "package.install.confirm",
    "package.install.apply",
    "package.import",
    "package.enable",
    "package.disable",
    "package.uninstall.preview",
    "package.uninstall.drain",
    "package.uninstall.collect",
    "package.recover",
    "package.update.preview",
    "package.update.apply",
    "package.activate",
    "package.resource.select",
  ];
  if (
    !isRecord(schema) ||
    schema.title !== "PackageBridge" ||
    schema.version !== 1 ||
    schema.maxRequestBytes !== 1024 * 1024 ||
    schema.maxArchiveBytes !== 256 * 1024 * 1024 ||
    schema.maxRegistrations !== 32 ||
    schema.maxInstances !== 64 ||
    JSON.stringify(schema.operations) !== JSON.stringify(expectedOperations) ||
    !validValues(schema.sources, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.lifecycles, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.instanceLifecycles, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.remainingWorkChoices, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.registrationOwners, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.maintenanceOperations, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.preservedFacts, /^[a-z][a-z0-9-]*$/u) ||
    !validValues(schema.failureCodes, /^[a-z][a-z0-9_]*$/u) ||
    JSON.stringify(schema.maintenanceOperations) !==
      JSON.stringify(["update-apply", "activation"])
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  return schema;
}

function dartPackageOutput(schema, schemaPath) {
  const enums = [
    ["PackageOperation", schema.operations],
    ["PackageSourceKind", schema.sources],
    ["PackageLifecycleKind", schema.lifecycles],
    ["PackageInstanceLifecycle", schema.instanceLifecycles],
    ["PackageRemainingWorkChoice", schema.remainingWorkChoices],
    ["PackageRegistrationOwner", schema.registrationOwners],
    ["PackageMaintenanceOperation", schema.maintenanceOperations],
    ["PackagePreservedFact", schema.preservedFacts],
    ["PackageFailureCode", schema.failureCodes],
  ];
  return `// @generated by ${schemaPath}; do not edit.
${enums.map(([name, values]) => dartEnum(name, values)).join("\n")}
const String packageBridgeSchemaVersion = 'licoup.package-lifecycle.bridge.v1';
const int packageBridgeMaxRequestBytes = ${schema.maxRequestBytes};
const int packageBridgeMaxArchiveBytes = ${schema.maxArchiveBytes};
const int packageBridgeMaxRegistrations = ${schema.maxRegistrations};
const int packageBridgeMaxInstances = ${schema.maxInstances};
`;
}

function renderFamily(family) {
  switch (family.id) {
    case "client_error": {
      const schema = readClientErrorSchema(family);
      return dartClientErrorOutput(schema, family.schema);
    }
    case "state": {
      const schema = readStateSchema(family);
      return dartStateOutput(schema, family.schema);
    }
    case "conversation": {
      const schema = readConversationSchema(family);
      return formatDart(
        dartConversationOutput(schema, family.schema),
        family.dartOutput,
      );
    }
    case "strategy": {
      const schema = readStrategySchema(family);
      return dartStrategyOutput(schema, family.schema);
    }
    case "package": {
      const schema = readPackageSchema(family);
      return dartPackageOutput(schema, family.schema);
    }
    default:
      fail(`unsupported active bridge family: ${family.id}`);
  }
}

function formatDart(source, outputPath) {
  const result = spawnSync("dart", [
    "format", "--output=show", "--summary=none", `--stdin-name=${outputPath}`,
  ], {
    cwd: repositoryRoot,
    encoding: "utf8",
    input: source,
  });
  if (result.status !== 0 || typeof result.stdout !== "string") {
    fail("dart format rejected generated bridge output");
  }
  return result.stdout;
}

function atomicWrite(relativePath, content) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  const directory = path.dirname(absolutePath);
  fs.mkdirSync(directory, { recursive: true });
  let temporaryPath;
  let descriptor;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    temporaryPath = path.join(
      directory,
      `.${path.basename(relativePath)}.${process.pid}.${attempt}.tmp`,
    );
    try {
      descriptor = fs.openSync(temporaryPath, "wx", 0o644);
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }
  if (descriptor === undefined) fail(`unable to stage generated output: ${relativePath}`);
  try {
    fs.writeFileSync(descriptor, content, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporaryPath, absolutePath);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    if (temporaryPath && fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
  }
}

function reconcileOutput(relativePath, content, checkOnly) {
  let current = null;
  try {
    current = fs.readFileSync(path.join(repositoryRoot, relativePath), "utf8");
  } catch (error) {
    if (error?.code !== "ENOENT") fail(`unreadable generated output: ${relativePath}`);
  }
  if (current === content) return null;
  if (checkOnly) return `stale generated output: ${relativePath}`;
  atomicWrite(relativePath, content);
  return null;
}

function main() {
  const args = process.argv.slice(2);
  if (args.some((argument) => argument !== "--check") || args.length > 1) {
    fail("usage: generate-client-bridge-contracts.mjs [--check]");
  }
  const checkOnly = args[0] === "--check";
  const manifest = validateManifest();
  validateRegisteredFiles(manifest, checkOnly);

  const diagnostics = [];
  for (const family of manifest.families) {
    if (family.status !== "active") continue;
    const diagnostic = reconcileOutput(
      family.dartOutput,
      renderFamily(family),
      checkOnly,
    );
    if (diagnostic) diagnostics.push(diagnostic);
  }
  if (diagnostics.length > 0) fail(diagnostics.join("\n"));
}

try {
  main();
} catch (error) {
  const message =
    error instanceof ContractError
      ? error.message
      : "client bridge contract generation failed";
  process.stderr.write(`${message.slice(0, 4096)}\n`);
  process.exitCode = 1;
}
