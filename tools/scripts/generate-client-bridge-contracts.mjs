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
const rustPrefix = "crates/licoup-native/src/ffi/generated/";
const dartPrefix = "apps/desktop/lib/src/contracts/generated/";
const allowedNonBridgeOutputs = new Set([
  `${rustPrefix}mod.rs`,
  `${dartPrefix}README.md`,
  `${dartPrefix}secure_mesh_capability_catalog.g.dart`,
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
  if (!Array.isArray(manifest.families) || manifest.families.length !== 6) {
    fail("bridge manifest must contain exactly six ordered families");
  }

  const ids = new Set();
  const schemas = new Set();
  const rustOutputs = new Set();
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
    validatePath(family.rustOutput, rustPrefix, ".rs", "Rust output");
    validatePath(family.dartOutput, dartPrefix, ".g.dart", "Dart output");

    for (const [value, seen, label] of [
      [family.schema, schemas, "schema"],
      [family.rustOutput, rustOutputs, "Rust output"],
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
    manifest.families.flatMap(({ rustOutput, dartOutput }) => [
      rustOutput,
      dartOutput,
    ]),
  );

  for (const family of manifest.families) {
    const schemaExists = fs.existsSync(path.join(repositoryRoot, family.schema));
    const rustExists = fs.existsSync(path.join(repositoryRoot, family.rustOutput));
    const dartExists = fs.existsSync(path.join(repositoryRoot, family.dartOutput));
    if (family.status === "active") {
      if (!schemaExists) diagnostics.push(`missing active schema: ${family.schema}`);
      if (checkOnly && !rustExists) {
        diagnostics.push(`missing active output: ${family.rustOutput}`);
      }
      if (checkOnly && !dartExists) {
        diagnostics.push(`missing active output: ${family.dartOutput}`);
      }
    } else {
      if (schemaExists) diagnostics.push(`planned schema must be absent: ${family.schema}`);
      if (rustExists) diagnostics.push(`planned output must be absent: ${family.rustOutput}`);
      if (dartExists) diagnostics.push(`planned output must be absent: ${family.dartOutput}`);
    }
  }

  for (const [directory, suffix] of [
    [rustPrefix, ".rs"],
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
    JSON.stringify(schema.operations) !== JSON.stringify(["get", "set"]) ||
    !Array.isArray(schema.failureCodes) ||
    JSON.stringify(schema.failureCodes) !==
      JSON.stringify([
        "invalid_collection",
        "invalid_document",
        "state_operation_failed",
      ])
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  return schema;
}

function readSecureMeshSchema(family) {
  const schema = readBoundedJson(
    family.schema,
    maximumSchemaBytes,
    "active bridge schema",
  );
  const validStrings = (values, pattern) =>
    Array.isArray(values) &&
    values.length > 0 &&
    new Set(values).size === values.length &&
    values.every((value) => typeof value === "string" && pattern.test(value));
  if (
    !isRecord(schema) ||
    schema.title !== "SecureMeshBridge" ||
    schema.version !== 1 ||
    schema.protocolVersion !== "licomesh.secure-mesh.v1" ||
    !Number.isSafeInteger(schema.maxRequestBytes) ||
    schema.maxRequestBytes <= 0 ||
    schema.maxRequestBytes > 16 * 1024 * 1024 ||
    !Number.isSafeInteger(schema.maxDepth) ||
    schema.maxDepth <= 0 ||
    schema.maxDepth > 128 ||
    !Number.isSafeInteger(schema.maxNodes) ||
    schema.maxNodes <= 0 ||
    schema.maxNodes > 1_000_000 ||
    !Number.isSafeInteger(schema.maxCollectionEntries) ||
    schema.maxCollectionEntries <= 0 ||
    schema.maxCollectionEntries > schema.maxNodes ||
    !Number.isSafeInteger(schema.maxStringBytes) ||
    schema.maxStringBytes <= 0 ||
    schema.maxStringBytes > schema.maxRequestBytes ||
    !validStrings(schema.actions, /^secure_mesh\.[a-zA-Z][a-zA-Z0-9.]*$/u) ||
    !validStrings(schema.failureCodes, /^[a-z][a-z0-9_]*$/u) ||
    JSON.stringify(schema.failureCodes) !==
      JSON.stringify([
        "unsupported_action",
        "invalid_payload",
        "forbidden_secret_material",
        "native_operation_failed",
      ]) ||
    !validStrings(schema.fileStatuses, /^[a-z][a-z0-9_]*$/u) ||
    !validStrings(schema.skillStatuses, /^[a-z][a-z0-9_]*$/u) ||
    !validStrings(schema.approvalStatuses, /^[a-z][a-z0-9_]*$/u) ||
    !validStrings(schema.approvalDecisions, /^[a-z][a-z0-9_]*$/u) ||
    JSON.stringify(schema.forbiddenFields) !==
      JSON.stringify([
        "privateKey",
        "privateKeyMaterial",
        "secret",
        "seed",
        "token",
        "credential",
        "absolutePath",
      ])
  ) {
    fail(`unsupported active bridge schema: ${family.schema}`);
  }
  return schema;
}

function pascal(value) {
  return value
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
}

function secureMeshVariant(action) {
  if (action === "secure_mesh.status") return "SecureMeshStatus";
  return pascal(action.replace(/^secure_mesh\./u, ""));
}

function enumField(schema, name) {
  return schema.fields.find((field) => field.name === name).values;
}

function rustEnum(name, values) {
  return `#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ${name} {
${values
  .map((value) => `    #[serde(rename = ${JSON.stringify(value)})]\n    ${pascal(value)},`)
  .join("\n")}
}
`;
}

function rustClientErrorOutput(schema, schemaPath) {
  return `// @generated by ${schemaPath}; do not edit.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

${rustEnum("ClientErrorCode", enumField(schema, "code"))}
${rustEnum("ClientErrorStage", enumField(schema, "stage"))}
${rustEnum("ClientErrorComponent", enumField(schema, "component"))}
${rustEnum("ClientErrorRecovery", enumField(schema, "recovery"))}
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientError {
    pub code: ClientErrorCode,
    pub stage: ClientErrorStage,
    pub component: ClientErrorComponent,
    pub retryable: bool,
    pub recovery: ClientErrorRecovery,
    #[serde(rename = "presentationArgs", default, skip_serializing_if = "BTreeMap::is_empty")]
    pub presentation_args: BTreeMap<String, String>,
}

impl ClientError {
    pub fn new(
        code: ClientErrorCode,
        stage: ClientErrorStage,
        component: ClientErrorComponent,
        retryable: bool,
        recovery: ClientErrorRecovery,
    ) -> Self {
        Self {
            code,
            stage,
            component,
            retryable,
            recovery,
            presentation_args: BTreeMap::new(),
        }
    }

    pub fn with_presentation_arg(mut self, key: &str, value: &str) -> Self {
        const ALLOWED_KEYS: &[&str] = &[
${schema.fields
  .find(({ name }) => name === "presentationArgs")
  .allowedKeys.map((key) => `            ${JSON.stringify(key)},`)
  .join("\n")}
        ];
        if self.presentation_args.len() < 4
            && ALLOWED_KEYS.contains(&key)
            && key.len() <= 32
            && value.len() <= 96
        {
            self.presentation_args.insert(key.to_owned(), value.to_owned());
        }
        self
    }
}
`;
}

function dartEnum(name, values) {
  const entries = values.map((value) => {
    const member = pascal(value);
    const camelMember = member[0].toLowerCase() + member.slice(1);
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

function dartSecureMeshActionEnum(actions) {
  const entries = actions.map((action) => {
    const variant = secureMeshVariant(action);
    const member = variant[0].toLowerCase() + variant.slice(1);
    return `  ${member}(${JSON.stringify(action)}),`;
  });
  return `enum SecureMeshAction {
${entries.join("\n")}
  unknown('');

  const SecureMeshAction(this.wireName);
  final String wireName;

  static SecureMeshAction fromWire(Object? value) {
    if (value is! String) return SecureMeshAction.unknown;
    for (final candidate in SecureMeshAction.values) {
      if (candidate != SecureMeshAction.unknown &&
          candidate.wireName == value) {
        return candidate;
      }
    }
    return SecureMeshAction.unknown;
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

function rustStateOutput(schema, schemaPath) {
  return `// @generated by ${schemaPath}; do not edit.
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use serde_json::Value;
use std::collections::BTreeMap;

pub const CLIENT_STATE_SCHEMA_VERSION: &str = "v0.0.1:schema:definition-1";
pub const CLIENT_STATE_MAX_DOCUMENT_BYTES: usize = ${schema.maxDocumentBytes};

${rustEnum("ClientStateCollection", schema.collections)}
impl ClientStateCollection {
    pub const fn as_str(self) -> &'static str {
        match self {
${schema.collections
  .map((value) => `            Self::${pascal(value)} => ${JSON.stringify(value)},`)
  .join("\n")}
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ClientStateDocument {
    #[serde(rename = "schemaVersion")]
    pub schema_version: String,
    pub collection: ClientStateCollection,
    #[serde(flatten)]
    pub content: BTreeMap<String, Value>,
}

impl ClientStateDocument {
    pub fn for_collection(
        collection: ClientStateCollection,
        value: Value,
    ) -> Result<Self, &'static str> {
        let mut object = match value {
            Value::Object(object) => object,
            value => {
                let mut object = serde_json::Map::new();
                object.insert("items".to_owned(), value);
                object
            }
        };
        object.insert(
            "schemaVersion".to_owned(),
            Value::String(CLIENT_STATE_SCHEMA_VERSION.to_owned()),
        );
        object.insert(
            "collection".to_owned(),
            Value::String(collection.as_str().to_owned()),
        );
        Self::from_value(Value::Object(object))
    }

    pub fn from_value(value: Value) -> Result<Self, &'static str> {
        let mut object = value.as_object().cloned().ok_or("invalid_document")?;
        let schema_version = object
            .remove("schemaVersion")
            .and_then(|value| value.as_str().map(str::to_owned))
            .filter(|value| value == CLIENT_STATE_SCHEMA_VERSION)
            .ok_or("invalid_document")?;
        let collection = object
            .remove("collection")
            .ok_or("invalid_collection")
            .and_then(|value| {
                serde_json::from_value(value).map_err(|_| "invalid_collection")
            })?;
        let document = Self {
            schema_version,
            collection,
            content: object.into_iter().collect(),
        };
        let size = serde_json::to_vec(&document)
            .map_err(|_| "invalid_document")?
            .len();
        if size > CLIENT_STATE_MAX_DOCUMENT_BYTES {
            return Err("invalid_document");
        }
        Ok(document)
    }

    pub fn into_value(self) -> Value {
        serde_json::to_value(self).expect("generated client-state document serializes")
    }
}

impl<'de> Deserialize<'de> for ClientStateDocument {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        Self::from_value(value).map_err(D::Error::custom)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientStateGetRequest {
    pub collection: ClientStateCollection,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ClientStateSetRequest {
    pub collection: ClientStateCollection,
    pub document: ClientStateDocument,
}

impl<'de> Deserialize<'de> for ClientStateSetRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct Wire {
            collection: ClientStateCollection,
            document: ClientStateDocument,
        }
        let wire = Wire::deserialize(deserializer)?;
        if wire.collection != wire.document.collection {
            return Err(D::Error::custom("invalid_document"));
        }
        Ok(Self {
            collection: wire.collection,
            document: wire.document,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientStateGetResult {
    pub ok: bool,
    pub collection: ClientStateCollection,
    pub document: ClientStateDocument,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientStateActivity {
    #[serde(rename = "schemaVersion")]
    pub schema_version: String,
    #[serde(rename = "eventId")]
    pub event_id: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub target: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Value>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientStateSetResult {
    pub ok: bool,
    pub collection: ClientStateCollection,
    pub document: ClientStateDocument,
    pub activity: ClientStateActivity,
}

${rustEnum("ClientStateFailureCode", schema.failureCodes)}
impl ClientStateFailureCode {
    pub const fn as_str(self) -> &'static str {
        match self {
${schema.failureCodes
  .map((value) => `            Self::${pascal(value)} => ${JSON.stringify(value)},`)
  .join("\n")}
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClientStateFailure {
    pub code: ClientStateFailureCode,
}

impl ClientStateFailure {
    pub const fn new(code: ClientStateFailureCode) -> Self {
        Self { code }
    }
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
  ClientStateSetRequest({
    required this.collection,
    required this.document,
  }) {
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

  Map<String, Object> toJson() => <String, Object>{
    'code': code.wireName,
  };

  @override
  String toString() => 'ClientStateFailure(\${code.wireName})';
}
`;
}

function rustSecureMeshOutput(schema, schemaPath) {
  const actionVariants = schema.actions
    .map(
      (action) =>
        `    #[serde(rename = ${JSON.stringify(action)})]\n    ${secureMeshVariant(action)},`,
    )
    .join("\n");
  const actionNames = schema.actions
    .map(
      (action) =>
        `            Self::${secureMeshVariant(action)} => ${JSON.stringify(action)},`,
    )
    .join("\n");
  const forbidden = schema.forbiddenFields
    .map((field) => `    ${JSON.stringify(field)},`)
    .join("\n");
  const projections = [
    "SecureMeshCapabilityProjection",
    "SecureMeshSelectedCustody",
    "SecureMeshMlsPublicIdentity",
    "SecureMeshMlsTrustedIdentity",
    "SecureMeshMlsContentContext",
    "SecureMeshMlsRequest",
    "SecureMeshMlsResponse",
    "SecureMeshKtPinnedAuthority",
    "SecureMeshKtRequest",
    "SecureMeshKtResponse",
    "SecureMeshApprovalRequest",
    "SecureMeshFileSyncTransfer",
    "SecureMeshSkillSyncTransfer",
  ]
    .map(
      (name) => `#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct ${name} {
    #[serde(flatten)]
    pub fields: BTreeMap<String, Value>,
}
`,
    )
    .join("\n");
  return `// @generated by ${schemaPath}; do not edit.
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub const SECURE_MESH_PROTOCOL_VERSION: &str = ${JSON.stringify(schema.protocolVersion)};
pub const SECURE_MESH_MAX_REQUEST_BYTES: usize = ${schema.maxRequestBytes};
pub const SECURE_MESH_MAX_DEPTH: usize = ${schema.maxDepth};
pub const SECURE_MESH_MAX_NODES: usize = ${schema.maxNodes};
pub const SECURE_MESH_MAX_COLLECTION_ENTRIES: usize = ${schema.maxCollectionEntries};
pub const SECURE_MESH_MAX_STRING_BYTES: usize = ${schema.maxStringBytes};
const FORBIDDEN_FIELDS: &[&str] = &[
${forbidden}
];

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum SecureMeshAction {
${actionVariants}
}

impl SecureMeshAction {
    pub const fn as_str(self) -> &'static str {
        match self {
${actionNames}
        }
    }
}

${rustEnum("SecureMeshFailureCode", schema.failureCodes)}
impl SecureMeshFailureCode {
    pub const fn as_str(self) -> &'static str {
        match self {
${schema.failureCodes
  .map((code) => `            Self::${pascal(code)} => ${JSON.stringify(code)},`)
  .join("\n")}
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SecureMeshFailure {
    pub code: SecureMeshFailureCode,
}

impl SecureMeshFailure {
    pub const fn new(code: SecureMeshFailureCode) -> Self {
        Self { code }
    }
}

impl std::fmt::Display for SecureMeshFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code.as_str())
    }
}

impl std::error::Error for SecureMeshFailure {}

#[derive(Clone, Debug, PartialEq)]
pub struct SecureMeshRequest {
    pub action: SecureMeshAction,
    pub params: Value,
    pub authorize: bool,
}

impl SecureMeshRequest {
    pub fn new(action: SecureMeshAction, params: Value) -> Result<Self, SecureMeshFailure> {
        if !params.is_object() {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        validate_value(&params)?;
        let request = Self { action, params, authorize: false };
        let size = serde_json::to_vec(&request)
            .map_err(|_| SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload))?
            .len();
        if size > SECURE_MESH_MAX_REQUEST_BYTES {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        Ok(request)
    }

    pub fn from_value(value: Value) -> Result<Self, SecureMeshFailure> {
        validate_value(&value)?;
        let mut object = value
            .as_object()
            .cloned()
            .ok_or_else(|| SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload))?;
        if object
            .keys()
            .any(|key| key != "action" && key != "params" && key != "authorize")
        {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        let action = object
            .remove("action")
            .ok_or_else(|| SecureMeshFailure::new(SecureMeshFailureCode::UnsupportedAction))
            .and_then(|value| serde_json::from_value(value).map_err(|_| {
                SecureMeshFailure::new(SecureMeshFailureCode::UnsupportedAction)
            }))?;
        let params = object.remove("params").unwrap_or_else(|| Value::Object(Map::new()));
        let authorize = object
            .remove("authorize")
            .map(|value| value.as_bool().ok_or_else(|| {
                SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload)
            }))
            .transpose()?
            .unwrap_or(false);
        let mut request = Self::new(action, params)?;
        request.authorize = authorize;
        Ok(request)
    }
}

impl Serialize for SecureMeshRequest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut object = Map::new();
        object.insert("action".to_owned(), Value::String(self.action.as_str().to_owned()));
        object.insert("params".to_owned(), self.params.clone());
        if self.authorize {
            object.insert("authorize".to_owned(), Value::Bool(true));
        }
        Value::Object(object).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SecureMeshRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::from_value(Value::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SecureMeshResult {
    value: Value,
}

impl SecureMeshResult {
    pub fn from_value(value: Value) -> Result<Self, SecureMeshFailure> {
        if !value.is_object() {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        validate_value(&value)?;
        Ok(Self { value })
    }

    pub const fn value(&self) -> &Value {
        &self.value
    }

    pub fn into_value(self) -> Value {
        self.value
    }
}

impl Serialize for SecureMeshResult {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.value.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SecureMeshResult {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::from_value(Value::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}

fn validate_value(root: &Value) -> Result<(), SecureMeshFailure> {
    let mut stack = vec![(root, 1usize)];
    let mut nodes = 0usize;
    while let Some((value, depth)) = stack.pop() {
        if depth > SECURE_MESH_MAX_DEPTH {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        nodes = nodes.checked_add(1).ok_or_else(|| {
            SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload)
        })?;
        if nodes > SECURE_MESH_MAX_NODES {
            return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
        }
        match value {
            Value::String(value) if value.len() > SECURE_MESH_MAX_STRING_BYTES => {
                return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
            }
            Value::Array(values) => {
                if values.len() > SECURE_MESH_MAX_COLLECTION_ENTRIES {
                    return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
                }
                stack.extend(values.iter().rev().map(|value| (value, depth + 1)));
            }
            Value::Object(values) => {
                if values.len() > SECURE_MESH_MAX_COLLECTION_ENTRIES {
                    return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
                }
                for (key, value) in values.iter().rev() {
                    if key.len() > SECURE_MESH_MAX_STRING_BYTES {
                        return Err(SecureMeshFailure::new(SecureMeshFailureCode::InvalidPayload));
                    }
                    if FORBIDDEN_FIELDS
                        .iter()
                        .any(|forbidden| key.eq_ignore_ascii_case(forbidden))
                    {
                        return Err(SecureMeshFailure::new(
                            SecureMeshFailureCode::ForbiddenSecretMaterial,
                        ));
                    }
                    stack.push((value, depth + 1));
                }
            }
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {}
        }
    }
    Ok(())
}

${projections}
${rustEnum("SecureMeshFileSyncStatus", schema.fileStatuses)}
${rustEnum("SecureMeshSkillSyncStatus", schema.skillStatuses)}
${rustEnum("SecureMeshApprovalStatus", schema.approvalStatuses)}
${rustEnum("SecureMeshApprovalDecision", schema.approvalDecisions)}
`;
}

function dartSecureMeshOutput(schema, schemaPath) {
  const templateDirectory = "tools/templates/client_bridge";
  const projectionFiles = [
    "secure_mesh_capability_models.dart",
    "secure_mesh_kt_models.dart",
    "secure_mesh_mls_models.dart",
    "secure_mesh_file_sync_models.dart",
    "secure_mesh_skill_sync_models.dart",
    "secure_mesh_approval_models.dart",
  ];
  const projections = projectionFiles
    .map((name) => {
      const relativePath = `${templateDirectory}/${name}`;
      const source = fs.readFileSync(path.join(repositoryRoot, relativePath), "utf8");
      return source.replace(/^import .*;\n+/gmu, "").trim();
    })
    .join("\n\n");
  const forbidden = schema.forbiddenFields
    .map((field) => `  ${JSON.stringify(field).replaceAll('"', "'")},`)
    .join("\n");
  return `// @generated by ${schemaPath}; do not edit.
import 'dart:collection';
import 'dart:convert';

import 'package:licoup/src/contracts/generated/secure_mesh_capability_catalog.g.dart';

const String secureMeshProtocolVersion = ${JSON.stringify(schema.protocolVersion).replaceAll('"', "'")};
const int secureMeshMaxRequestBytes = ${schema.maxRequestBytes};
const int secureMeshMaxDepth = ${schema.maxDepth};
const int secureMeshMaxNodes = ${schema.maxNodes};
const int secureMeshMaxCollectionEntries = ${schema.maxCollectionEntries};
const int secureMeshMaxStringBytes = ${schema.maxStringBytes};
const Set<String> _secureMeshForbiddenFields = <String>{
${forbidden}
};

${dartSecureMeshActionEnum(schema.actions)}
${dartEnum("SecureMeshFailureCode", schema.failureCodes)}

final class SecureMeshFailure implements Exception {
  const SecureMeshFailure({required this.code});

  factory SecureMeshFailure.fromJson(Map<String, Object?> json) {
    final code = SecureMeshFailureCode.fromWire(json['code']);
    return SecureMeshFailure(
      code: code == SecureMeshFailureCode.unknown
          ? SecureMeshFailureCode.nativeOperationFailed
          : code,
    );
  }

  final SecureMeshFailureCode code;

  Map<String, Object> toJson() => <String, Object>{'code': code.wireName};

  @override
  String toString() => 'SecureMeshFailure(\${code.wireName})';
}

final class SecureMeshRequest {
  SecureMeshRequest({
    required this.action,
    Map<String, Object?> params = const <String, Object?>{},
    this.authorize = false,
  }) : params = Map<String, Object?>.unmodifiable(params) {
    if (action == SecureMeshAction.unknown) {
      throw const SecureMeshFailure(
        code: SecureMeshFailureCode.unsupportedAction,
      );
    }
    _validateSecureMeshValue(this.params);
    if (utf8.encode(jsonEncode(toJson())).length > secureMeshMaxRequestBytes) {
      throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
    }
  }

  factory SecureMeshRequest.fromJson(Map<String, Object?> json) {
    final action = SecureMeshAction.fromWire(json['action']);
    final rawParams = json['params'];
    if (rawParams != null && rawParams is! Map) {
      throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
    }
    return SecureMeshRequest(
      action: action,
      params: rawParams == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(rawParams as Map),
      authorize: json['authorize'] == true,
    );
  }

  final SecureMeshAction action;
  final Map<String, Object?> params;
  final bool authorize;

  Map<String, Object?> toJson() => <String, Object?>{
    'action': action.wireName,
    'params': params,
    if (authorize) 'authorize': true,
  };
}

final class SecureMeshResult {
  SecureMeshResult.fromJson(Map<String, Object?> json)
    : value = Map<String, Object?>.unmodifiable(json),
      ok = json['ok'] == true,
      protocolVersion = json['protocolVersion'] is String
          ? json['protocolVersion']! as String
          : '',
      productionReady = json['productionReady'] == true {
    _validateSecureMeshValue(value);
    if (!ok) {
      throw SecureMeshFailure.fromJson(json);
    }
  }

  final Map<String, Object?> value;
  final bool ok;
  final String protocolVersion;
  final bool productionReady;
}

void _validateSecureMeshValue(Object? root) {
  final stack = <(Object?, int)>[(root, 1)];
  var nodes = 0;
  while (stack.isNotEmpty) {
    final (value, depth) = stack.removeLast();
    nodes += 1;
    if (depth > secureMeshMaxDepth || nodes > secureMeshMaxNodes) {
      throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
    }
    if (value is String) {
      if (utf8.encode(value).length > secureMeshMaxStringBytes) {
        throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
      }
    } else if (value is List) {
      if (value.length > secureMeshMaxCollectionEntries) {
        throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
      }
      for (final nested in value.reversed) {
        stack.add((nested, depth + 1));
      }
    } else if (value is Map) {
      if (value.length > secureMeshMaxCollectionEntries) {
        throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
      }
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String ||
            utf8.encode(key).length > secureMeshMaxStringBytes) {
          throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
        }
        if (_secureMeshForbiddenFields.any(
          (forbidden) => forbidden.toLowerCase() == key.toLowerCase(),
        )) {
          throw const SecureMeshFailure(
            code: SecureMeshFailureCode.forbiddenSecretMaterial,
          );
        }
        stack.add((entry.value, depth + 1));
      }
    } else if (value != null && value is! bool && value is! num) {
      throw const SecureMeshFailure(code: SecureMeshFailureCode.invalidPayload);
    }
  }
}

${projections}
`;
}

function renderFamily(family) {
  switch (family.id) {
    case "client_error": {
      const schema = readClientErrorSchema(family);
      return [
        formatRust(rustClientErrorOutput(schema, family.schema)),
        dartClientErrorOutput(schema, family.schema),
      ];
    }
    case "state": {
      const schema = readStateSchema(family);
      return [
        formatRust(rustStateOutput(schema, family.schema)),
        dartStateOutput(schema, family.schema),
      ];
    }
    case "secure_mesh": {
      const schema = readSecureMeshSchema(family);
      return [
        formatRust(rustSecureMeshOutput(schema, family.schema)),
        dartSecureMeshOutput(schema, family.schema),
      ];
    }
    default:
      fail(`unsupported active bridge family: ${family.id}`);
  }
}

function formatRust(source) {
  const result = spawnSync("rustfmt", ["--edition", "2024", "--emit", "stdout"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    input: source,
  });
  if (result.status !== 0 || typeof result.stdout !== "string") {
    fail("rustfmt rejected generated bridge output");
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
    const [rust, dart] = renderFamily(family);
    const outputs = [
      [family.rustOutput, rust],
      [family.dartOutput, dart],
    ];
    for (const [relativePath, content] of outputs) {
      const diagnostic = reconcileOutput(relativePath, content, checkOnly);
      if (diagnostic) diagnostics.push(diagnostic);
    }
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
