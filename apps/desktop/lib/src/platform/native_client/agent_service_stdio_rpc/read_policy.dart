/// Explicit stateless query routes whose native handlers read current local
/// state on each call. Lifecycle commands and process-local services retain
/// the ordered command lane; command names alone do not imply read safety.
bool stdioRpcArgsUseReadPool(List<String> args) => switch (args) {
  ['agent-hub', 'catalog', ...] ||
  ['adapter', 'catalog', ...] ||
  ['agent-usage', 'report', ...] ||
  ['agents', 'pair', 'list', ...] ||
  ['conversations', 'list', ...] ||
  ['skill', 'list', ...] ||
  ['skill', 'usage', 'report', ...] => true,
  _ => false,
};
