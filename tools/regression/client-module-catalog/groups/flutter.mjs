import { CONTROLLERS_MODULES } from "./flutter/controllers.mjs";
import { PRESENTATION_CONTRACTS_MODULES } from "./flutter/presentation-contracts.mjs";
import { APPLICATION_SHELL_MODULES } from "./flutter/application-shell.mjs";
import { COLLABORATION_MODULES } from "./flutter/collaboration.mjs";
import { AGENTS_MODULES } from "./flutter/agents.mjs";
import { CONVERSATION_MODULES } from "./flutter/conversation.mjs";
import { MODELS_AND_USAGE_MODULES } from "./flutter/models-and-usage.mjs";

export const FLUTTER_MODULES = Object.freeze([
  ...CONTROLLERS_MODULES,
  ...PRESENTATION_CONTRACTS_MODULES,
  ...APPLICATION_SHELL_MODULES,
  ...COLLABORATION_MODULES,
  ...AGENTS_MODULES,
  ...CONVERSATION_MODULES,
  ...MODELS_AND_USAGE_MODULES,
]);
