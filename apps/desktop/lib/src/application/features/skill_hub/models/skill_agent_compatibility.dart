import 'package:licoup/src/application/features/agents/agent_product_names.dart';

const skillCapableAgentIds = <String>{
  'antigravity',
  'claude-code',
  'codex',
  'copilot',
  'cursor',
  'kilo-code',
  'kimi-code',
  'openclaw',
  'opencode',
};

const _sharedAgentSkillIds = <String>{
  'antigravity',
  'codex',
  'copilot',
  'cursor',
  'kilo-code',
  'kimi-code',
  'opencode',
};

const _claudeCompatibleSkillIds = <String>{
  'claude-code',
  'copilot',
  'kimi-code',
  'opencode',
};

const _codexCompatibleSkillIds = <String>{'codex', 'kimi-code'};

String canonicalSkillAgentId(String value) {
  switch (value.trim().toLowerCase()) {
    case 'chatgpt':
    case 'chatgpt-codex':
    case 'codex-cli':
      return 'codex';
    case 'claude':
    case 'claude_cli':
      return 'claude-code';
    case 'github-copilot':
    case 'vscode-copilot':
      return 'copilot';
    case 'kilo':
      return 'kilo-code';
    case 'kimi':
    case 'kimicode':
      return 'kimi-code';
    default:
      return value.trim().toLowerCase();
  }
}

String skillLoaderAgentLabel(String agentId) {
  final canonical = canonicalSkillAgentId(agentId);
  return agentProductDisplayName(canonical) ?? canonical;
}

List<String> skillLoaderAgentIdsForPath({
  required String path,
  required bool isPublic,
  Iterable<String> detectedAgentIds = const [],
}) {
  final normalizedPath = path.replaceAll('\\', '/').toLowerCase();
  final detected = detectedAgentIds
      .map(canonicalSkillAgentId)
      .where(skillCapableAgentIds.contains)
      .toSet();

  Set<String>? supported;
  Set<String> requiredOwners = const {};
  if (_containsDirectory(normalizedPath, '.agents/skills') ||
      _containsDirectory(normalizedPath, '.config/agents/skills')) {
    supported = _sharedAgentSkillIds;
  } else if (_containsDirectory(normalizedPath, '.claude/skills')) {
    supported = _claudeCompatibleSkillIds;
    requiredOwners = const {'claude-code'};
  } else if (_containsDirectory(normalizedPath, '.codex/skills')) {
    supported = _codexCompatibleSkillIds;
    requiredOwners = const {'codex'};
  } else if (_containsDirectory(normalizedPath, '.github/skills') ||
      _containsDirectory(normalizedPath, '.copilot/skills')) {
    supported = const {'copilot'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.cursor/skills')) {
    supported = const {'cursor'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.opencode/skills') ||
      _containsDirectory(normalizedPath, '.config/opencode/skills')) {
    supported = const {'opencode'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.kilo/skills')) {
    supported = const {'kilo-code'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.kimi/skills')) {
    supported = const {'kimi-code'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.gemini/config/skills') ||
      normalizedPath.contains('/.gemini/antigravity/')) {
    supported = const {'antigravity'};
    requiredOwners = supported;
  } else if (_containsDirectory(normalizedPath, '.openclaw/skills')) {
    supported = const {'openclaw'};
    requiredOwners = supported;
  }

  supported ??= isPublic || detected.isEmpty ? skillCapableAgentIds : detected;

  final ordered = <String>{}..addAll(requiredOwners);
  ordered.addAll(supported.where(detected.contains));
  if (ordered.isEmpty) {
    ordered.addAll(supported);
  }
  return List.unmodifiable(ordered);
}

List<String> skillDirectorySegmentsForAgent(String agentId) {
  switch (canonicalSkillAgentId(agentId)) {
    case 'antigravity':
      return const [
        '.gemini/config/skills',
        '.gemini/antigravity/builtin/skills',
      ];
    case 'claude-code':
      return const ['.claude/skills'];
    case 'codex':
      return const ['.codex/skills'];
    case 'copilot':
      return const ['.copilot/skills', '.github/skills'];
    case 'cursor':
      return const ['.cursor/skills'];
    case 'kilo-code':
      return const ['.kilo/skills'];
    case 'kimi-code':
      return const ['.kimi/skills'];
    case 'openclaw':
      return const ['.openclaw/skills'];
    case 'opencode':
      return const ['.opencode/skills', '.config/opencode/skills'];
    default:
      return const [];
  }
}

bool _containsDirectory(String normalizedPath, String directory) {
  final normalizedDirectory = directory.toLowerCase();
  return normalizedPath == normalizedDirectory ||
      normalizedPath.endsWith('/$normalizedDirectory') ||
      normalizedPath.contains('/$normalizedDirectory/');
}
