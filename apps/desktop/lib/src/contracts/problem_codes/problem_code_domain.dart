/// Prefix allocation for LicoUp problem codes.
///
/// Shape: `LU-<prefix>-<nnnn>`. Prefixes do not overlap. Numeric ranges do
/// not overlap, so a new code cannot collide even if the prefix is omitted.
/// This enum is the allocation authority; mappings live in
/// `problem_code_entries.dart`.
enum ProblemDomain {
  /// Stdio RPC, process IO, request-shape failures. Range 1000-1199.
  rpc('RP', 1000, 1199, 'rpc'),

  /// Canonical Conversation store and group operations. Range 1200-1499.
  conversation('CV', 1200, 1499, 'conversation'),

  /// Agent workspace conversation, dispatch, native session. Range 1500-1899.
  agentConversation('AG', 1500, 1899, 'agent'),

  /// Adaptive Flywheel / strategy envelope. Range 1900-2199.
  strategy('ST', 1900, 2199, 'strategy'),

  /// Native CLI admission. Range 2200-2399.
  cli('CL', 2200, 2399, 'cli'),

  /// Client state get/set. Range 2400-2499.
  clientState('CS', 2400, 2499, 'state'),

  /// Skill Hub. Range 2500-2599.
  skillHub('SK', 2500, 2599, 'skill'),

  /// Target scan and pins. Range 2600-2699.
  targets('TG', 2600, 2699, 'target'),

  /// Mobile relay pairing and command relay. Range 2700-2899.
  mobileRelay('MR', 2700, 2899, 'relay'),

  /// Secure Mesh / secure agent sessions. Range 2900-3199.
  secureMesh('SM', 2900, 3199, 'mesh'),

  /// In-client update. Range 3200-3299.
  clientUpdate('UP', 3200, 3299, 'update'),

  /// LLM Gateway and Telegram channel. Range 3300-3499.
  gateway('GW', 3300, 3499, 'gateway'),

  /// Adapter plugins. Range 3500-3599.
  plugins('PL', 3500, 3599, 'plugin'),

  /// Conversation archive / snapshots. Range 3600-3699.
  archive('AR', 3600, 3699, 'archive'),

  /// Delivery Plan and Subagent MCP. Range 3700-3899.
  delivery('DL', 3700, 3899, 'delivery'),

  /// Native agent driver ProtocolFailure codes. Range 3900-4699.
  nativeAgent('NA', 3900, 4699, 'native'),

  /// Catalog convergence. Range 4700-4799.
  catalog('CB', 4700, 4799, 'catalog'),

  /// MCP transfer. Range 4800-4899.
  mcp('MC', 4800, 4899, 'mcp'),

  /// Optional collaboration plugins. Range 4900-5199.
  collaboration('OC', 4900, 5199, 'collab'),

  /// Shell, lifecycle, shared authorization. Range 5200-5299.
  system('SY', 5200, 5299, 'system'),

  /// Agent usage and resource scans. Range 5300-5399.
  usage('US', 5300, 5399, 'usage'),

  /// Layout catalog and presentation contracts. Range 5400-5499.
  layout('LY', 5400, 5499, 'layout'),

  /// Release-acceptance UI harness. Range 5500-5599.
  releaseAcceptance('RL', 5500, 5599, 'release'),

  /// Unknown legacy code fallback. Range 9900-9999.
  unmapped('XX', 9900, 9999, 'unmapped');

  const ProblemDomain(this.prefix, this.rangeStart, this.rangeEnd, this.id);

  /// Two-letter prefix in the wire form `LU-XX-nnnn`.
  final String prefix;

  /// Inclusive allocated start.
  final int rangeStart;

  /// Inclusive allocated end. New codes in this domain use the next free
  /// integer in the range.
  final int rangeEnd;

  /// Stable domain token for copy payloads.
  final String id;

  bool contains(int number) => number >= rangeStart && number <= rangeEnd;
}
