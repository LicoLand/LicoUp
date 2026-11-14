import { assembleClientModuleCatalog } from "./client-module-catalog/helpers.mjs";
import { CLIENT_MODULE_ID_ORDER } from "./client-module-catalog/order.mjs";
import { BRIDGE_PACKAGING_RELEASE_MODULES } from "./client-module-catalog/groups/bridge-packaging-release.mjs";
import { FLUTTER_MODULES } from "./client-module-catalog/groups/flutter.mjs";
import { REGRESSION_MODULES } from "./client-module-catalog/groups/regression.mjs";

const CLIENT_MODULE_GROUPS = Object.freeze([
  REGRESSION_MODULES,
  FLUTTER_MODULES,
  BRIDGE_PACKAGING_RELEASE_MODULES,
]);

export const CLIENT_MODULE_CATALOG = assembleClientModuleCatalog(
  CLIENT_MODULE_ID_ORDER,
  CLIENT_MODULE_GROUPS,
);

const moduleById = new Map(CLIENT_MODULE_CATALOG.map((module) => [module.id, module]));

export function clientModuleById(id) {
  return moduleById.get(id) ?? null;
}
