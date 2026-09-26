import { INFRASTRUCTURE_MODULES } from "./regression/infrastructure.mjs";
import { ADAPTERS_MODULES } from "./regression/adapters.mjs";
import { PACKAGING_MODULES } from "./regression/packaging.mjs";
import { CONVERSATION_WORKFLOW_MODULES } from "./regression/conversation-workflow.mjs";
import { SECURITY_MODULES } from "./regression/security.mjs";
import { PRESENTATION_MODULES } from "./regression/presentation.mjs";

export const REGRESSION_MODULES = Object.freeze([
  ...INFRASTRUCTURE_MODULES,
  ...ADAPTERS_MODULES,
  ...PACKAGING_MODULES,
  ...CONVERSATION_WORKFLOW_MODULES,
  ...SECURITY_MODULES,
  ...PRESENTATION_MODULES,
]);
