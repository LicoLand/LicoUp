import * as adaptiveFlywheel from "./adaptive-flywheel.mjs";
import * as agentTabOrder from "./agent-tab-order.mjs";
import * as appearancePresentation from "./appearance-presentation.mjs";
import * as canonicalConversation from "./canonical-conversation.mjs";
import * as clientState from "./client-state.mjs";
import * as mobileRelay from "./mobile-relay.mjs";
import * as workspaceManifest from "./workspace-manifest.mjs";
import * as gatewayCredentialCustody from "./gateway-credential-custody.mjs";
import { createGenericJsonCodec } from "./generic-json.mjs";

const CODEC_MAP = {
  "adaptive-flywheel": adaptiveFlywheel,
  "agent-tab-order": agentTabOrder,
  "appearance-presentation": appearancePresentation,
  "canonical-conversation": canonicalConversation,
  "client-state": clientState,
  "mobile-relay": mobileRelay,
  "workspace-manifest": workspaceManifest,
  "gateway-credential-custody": gatewayCredentialCustody,
  "agent-tool-allowlist": createGenericJsonCodec("agent-tool-allowlist"),
  "current-view": createGenericJsonCodec("current-view"),
  "mobile-home-layout": createGenericJsonCodec("mobile-home-layout"),
  "skill-hub-preferences": createGenericJsonCodec("skill-hub-preferences"),
};

export function getCodec(domainId) {
  const codec = CODEC_MAP[domainId];
  if (!codec) {
    throw new Error(`No codec registered for domain: "${domainId}"`);
  }
  return codec;
}

export function getAllCodecs() {
  return CODEC_MAP;
}
