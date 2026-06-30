#!/usr/bin/env node
import { createServer } from "node:http";
import { randomBytes, randomUUID, createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import process from "node:process";

const PROCESS_IDENTITY_PROTOCOL_VERSION = "v0.0.1:risk-control:process-identity-1";

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    runtimeConfig: "",
    requireRuntimeConfig: false,
    expectedRuntimeKind: "",
    expectedEdition: ""
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--runtime-config" && next) {
      options.runtimeConfig = next;
      index += 1;
    } else if (arg === "--require-runtime-config") {
      options.requireRuntimeConfig = true;
    } else if (arg === "--expected-runtime-kind" && next) {
      options.expectedRuntimeKind = next;
      index += 1;
    } else if (arg === "--expected-edition" && next) {
      options.expectedEdition = next;
      index += 1;
    } else {
      throw new Error(`Unknown client runtime option: ${arg}`);
    }
  }
  return options;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function loadRuntimeConfig(options) {
  if (!options.runtimeConfig) {
    if (options.requireRuntimeConfig) {
      throw new Error("client runtime requires --runtime-config");
    }
    return {};
  }
  const config = readJson(options.runtimeConfig);
  if (options.expectedRuntimeKind && config.runtimeKind !== options.expectedRuntimeKind) {
    throw new Error(`unexpected runtime kind: ${config.runtimeKind}`);
  }
  if (options.expectedEdition && config.edition !== options.expectedEdition) {
    throw new Error(`unexpected runtime edition: ${config.edition}`);
  }
  return config;
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > 1024 * 1024) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function sendJson(response, statusCode, body) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  response.end(`${JSON.stringify(body)}\n`);
}

function sha256Base64Url(value) {
  return createHash("sha256").update(value).digest("base64url");
}

function safeReadJson(path) {
  if (!path || !existsSync(path)) {
    return null;
  }
  try {
    return readJson(path);
  } catch {
    return null;
  }
}

function expectedClaimToken() {
  const file = process.env.LICO_PROCESS_IDENTITY_CLAIM_TOKEN_FILE;
  if (!file) {
    return "";
  }
  try {
    return readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

function healthPayload(config, startedAtUnix) {
  const featureProfile = safeReadJson(config.featureProfile);
  const discovery = config.discovery || {};
  return {
    ok: true,
    status: "running",
    runtimeKind: "client-local",
    edition: "client-local",
    serverId: discovery.serverId || `lico-client-local-runtime-${config.port || 0}`,
    serverLabel: discovery.serverLabel || "LicoLite Client Local Runtime",
    configVersion: discovery.configVersion || "",
    bootstrapBaseUrl: discovery.bootstrapBaseUrl || "",
    activeServiceUrl: discovery.activeServiceUrl || "",
    advertisedBaseUrl: discovery.advertisedBaseUrl || "",
    startedAtUnix,
    featureProfile: featureProfile
      ? {
          schemaVersion: featureProfile.schemaVersion || "",
          edition: featureProfile.edition || "",
          activeFeatureIds: featureProfile.features || featureProfile.activeFeatureIds || []
        }
      : null
  };
}

function identityPackage(body, config) {
  const serverId = config.discovery?.serverId || `lico-client-local-runtime-${config.port || 0}`;
  const publicKey = String(body.processPublicKeySpkiBase64 || "");
  const processKeyId = `process_${randomUUID()}`;
  return {
    schemaVersion: "v0.0.1:schema:definition-1",
    protocolVersion: PROCESS_IDENTITY_PROTOCOL_VERSION,
    packageId: `pkg_${randomUUID()}`,
    serverId,
    serverTrustPin: `sha256:${sha256Base64Url(serverId)}`,
    clientId: String(body.clientId || ""),
    installationId: String(body.installationId || ""),
    clientFingerprint: body.clientFingerprint && typeof body.clientFingerprint === "object"
      ? body.clientFingerprint
      : {},
    defaultIdentityHash: String(body.defaultIdentityHash || ""),
    processKey: {
      processKeyId,
      publicKeyHash: `sha256:${sha256Base64Url(publicKey)}`,
      publicKeySpkiBase64: publicKey,
      algorithm: "Ed25519"
    },
    capability: {
      key: randomBytes(32).toString("base64url"),
      scopes: ["client-local-runtime"],
      issuedAtUnix: Math.floor(Date.now() / 1000)
    },
    issuedAtUnix: Math.floor(Date.now() / 1000)
  };
}

async function handleClaim(request, response, config) {
  const raw = await readRequestBody(request);
  const body = raw.trim() ? JSON.parse(raw) : {};
  const expected = expectedClaimToken();
  if (expected && body.claimToken !== expected) {
    sendJson(response, 200, {
      ok: false,
      status: "invalid_claim_token"
    });
    return;
  }
  const packageBody = identityPackage(body, config);
  sendJson(response, 200, {
    ok: true,
    status: "claimed",
    protocolVersion: PROCESS_IDENTITY_PROTOCOL_VERSION,
    clientIdentityPackage: packageBody,
    serverIdentity: {
      serverId: packageBody.serverId,
      keyId: "client-local-runtime",
      publicKeyEd25519: randomBytes(32).toString("base64url"),
      trustPin: packageBody.serverTrustPin
    }
  });
}

async function main() {
  const options = parseArgs();
  const config = loadRuntimeConfig(options);
  const host = config.host || "127.0.0.1";
  const port = Number(config.port || 17328);
  const startedAtUnix = Math.floor(Date.now() / 1000);
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", `http://${host}:${port}`);
      if (request.method === "GET" && url.pathname === "/api/healthz") {
        sendJson(response, 200, healthPayload(config, startedAtUnix));
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/process-identity/bootstrap/claim") {
        await handleClaim(request, response, config);
        return;
      }
      sendJson(response, 404, {
        ok: false,
        status: "not_found"
      });
    } catch (error) {
      sendJson(response, 500, {
        ok: false,
        status: "error",
        error: error instanceof Error ? error.message : String(error)
      });
    }
  });
  server.listen(port, host, () => {
    process.stdout.write(`[lico-client-runtime] listening on http://${host}:${port}\n`);
  });
  const shutdown = () => server.close(() => process.exit(0));
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((error) => {
  process.stderr.write(`[lico-client-runtime] ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});
