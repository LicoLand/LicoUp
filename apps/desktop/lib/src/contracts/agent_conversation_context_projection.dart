import 'agent_conversation_message.dart';

String visibleUnstructuredConversationMessageText(
  String role,
  String text, {
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
}) {
  if (isInternalConversationRole(role)) {
    return '';
  }
  final normalizedRole = role.toLowerCase().trim();
  final visible =
      _isAntigravityConversation(
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      )
      ? _visibleAntigravityMessageText(normalizedRole, text)
      : normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractUserAuthoredText(text)
      : _stripGeneratedContextBlocks(text);
  return _finalizeVisibleConversationText(visible);
}

String _finalizeVisibleConversationText(String visible) {
  final trimmed = visible.trim();
  if (trimmed.isEmpty ||
      _generatedControlText(trimmed) ||
      _generatedOperationalNoticeText(trimmed) ||
      _generatedStructuredResultText(trimmed) ||
      _generatedAutomationChecklistText(trimmed) ||
      _antigravitySystemBoilerplateText(trimmed) ||
      _backgroundContextPromptText(trimmed)) {
    return '';
  }
  return trimmed;
}

bool _isAntigravityConversation({
  required String agentId,
  required String adapterId,
  required String sourceClient,
  required String sourceTool,
  required String hostApp,
}) {
  final evidence = [
    agentId,
    adapterId,
    sourceClient,
    sourceTool,
    hostApp,
  ].join(' ').toLowerCase();
  return evidence.contains('antigravity');
}

String _visibleAntigravityMessageText(String normalizedRole, String text) {
  if (_hiddenAntigravityRole(normalizedRole)) {
    return '';
  }
  final visible = normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractAntigravityUserRequest(text)
      : _stripAntigravitySystemMessages(text);
  final generic = normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractUserAuthoredText(visible)
      : _stripGeneratedContextBlocks(visible);
  return _stripAntigravityArtifactNoise(_stripAntigravityProtocolTags(generic));
}

bool _hiddenAntigravityRole(String normalizedRole) {
  return switch (normalizedRole) {
    'user' ||
    'human' ||
    'planner_response' ||
    'agent' ||
    'assistant' ||
    'generic' => false,
    _ => true,
  };
}

String _extractAntigravityUserRequest(String text) {
  final cleaned = _stripAntigravitySystemMessages(text);
  final requests = _antigravityUserRequestRegex()
      .allMatches(cleaned)
      .map((match) => match.group(1) ?? '')
      .map(_stripAntigravityProtocolTags)
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (requests.isNotEmpty) {
    return requests.join('\n\n');
  }
  return _stripAntigravityProtocolTags(cleaned);
}

String _stripAntigravitySystemMessages(String text) {
  var cleaned = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_antigravitySystemBlockRegex(), '\n');
  final paragraphs = cleaned.split(RegExp(r'\n\s*\n'));
  cleaned = paragraphs
      .where((paragraph) => !_antigravitySystemBoilerplateText(paragraph))
      .join('\n\n');
  cleaned = cleaned
      .split('\n')
      .where((line) => !_antigravitySystemBoilerplateText(line))
      .join('\n');
  return _stripAntigravityProtocolTags(cleaned);
}

String _stripAntigravityProtocolTags(String text) {
  return text.replaceAll(_antigravityProtocolTagRegex(), '').trim();
}

String _stripAntigravityArtifactNoise(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (_looksLikeAntigravityArtifactDump(lines)) {
    return '';
  }
  return lines
      .where((line) => !_antigravityInternalEventLine(line))
      .map(_stripAntigravityLineGutter)
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

bool _looksLikeAntigravityArtifactDump(List<String> lines) {
  final nonBlank = lines.where((line) => line.trim().isNotEmpty).length;
  if (nonBlank < 6) {
    return false;
  }
  final gutterLines = lines
      .where((line) => _antigravityLineGutterRegex().hasMatch(line))
      .length;
  return gutterLines >= 4 && gutterLines / nonBlank >= 0.35;
}

String _stripAntigravityLineGutter(String line) {
  if (RegExp(r'^\s*\d+[.)]\s+\S').hasMatch(line)) {
    return line.trimRight();
  }
  final match = _antigravityLineGutterRegex().firstMatch(line);
  if (match == null) {
    return line.trimRight();
  }
  final indent = match.group(1) ?? '';
  final content = match.group(2) ?? '';
  return '$indent$content'.trimRight();
}

bool _antigravityInternalEventLine(String line) {
  final normalized = line.trim().toLowerCase();
  return normalized == 'conversation_history' ||
      normalized == 'user_input' ||
      normalized == 'planner_response' ||
      normalized == 'list_directory' ||
      normalized == 'view_file' ||
      normalized == 'grep_search' ||
      normalized == 'run_command' ||
      normalized == 'code_action' ||
      normalized == 'generate_image' ||
      normalized == 'read_url_content';
}

RegExp _antigravityUserRequestRegex() => RegExp(
  r'<\s*USER[_-]?REQUEST\b[^>]*>([\s\S]*?)<\s*/\s*USER[_-]?REQUEST\s*>',
  caseSensitive: false,
);

RegExp _antigravitySystemBlockRegex() => RegExp(
  r'<\s*SYSTEM[_-]?MESSAGE\b[^>]*>[\s\S]*?<\s*/\s*SYSTEM[_-]?MESSAGE\s*>',
  caseSensitive: false,
);

RegExp _antigravityProtocolTagRegex() => RegExp(
  r'</?\s*(?:USER[_-]?REQUEST|SYSTEM[_-]?MESSAGE)\b[^>]*>',
  caseSensitive: false,
);

RegExp _antigravityLineGutterRegex() =>
    RegExp(r'^(\s*)\d{1,6}\s*(?:[│|:]\s?|\s{2,})(.*)$');

bool isInternalConversationRole(String role) {
  final normalized = role.toLowerCase().trim();
  return normalized == 'system' ||
      normalized == 'developer' ||
      normalized == 'subagent_prompt';
}

String _extractUserAuthoredText(String text) {
  final codexRequestIndex = _findCaseInsensitive(
    text,
    '## My request for Codex:',
  );
  if (codexRequestIndex >= 0) {
    return _stripGeneratedContextBlocks(
      text.substring(codexRequestIndex + '## My request for Codex:'.length),
    );
  }
  final plainRequestIndex = _findCaseInsensitive(text, 'My request for Codex:');
  if (plainRequestIndex >= 0) {
    return _stripGeneratedContextBlocks(
      text.substring(plainRequestIndex + 'My request for Codex:'.length),
    );
  }
  return _stripGeneratedContextBlocks(text);
}

String _stripGeneratedContextBlocks(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final visible = <String>[];
  String? closeMarker;
  for (final line in lines) {
    final lower = line.trimLeft().toLowerCase();
    final close = closeMarker;
    if (close != null) {
      if (_lineContainsContextClose(lower, close)) {
        closeMarker = null;
        final after = _trailingTextAfterContextClose(line, close);
        if (after != null && after.trim().isNotEmpty) {
          visible.add(after);
        }
      }
      continue;
    }
    if (lower.startsWith('# files mentioned by the user:')) {
      continue;
    }
    final nextClose = _generatedContextBlockCloseMarker(lower);
    if (nextClose != null) {
      if (_lineContainsContextClose(lower, nextClose)) {
        final after = _trailingTextAfterContextClose(line, nextClose);
        if (after != null && after.trim().isNotEmpty) {
          visible.add(after);
        }
      } else {
        closeMarker = nextClose;
      }
      continue;
    }
    visible.add(line);
  }
  return visible.join('\n');
}

String? _trailingTextAfterContextClose(String line, String closeMarker) {
  final lower = line.toLowerCase();
  final close = closeMarker.toLowerCase();
  final index = lower.indexOf(close);
  if (index < 0) {
    return null;
  }
  return line.substring(index + closeMarker.length);
}

String? _generatedContextBlockCloseMarker(String lowerLine) {
  for (final entry in _generatedContextBlockCloseMarkers.entries) {
    if (lowerLine.startsWith(entry.key)) {
      return entry.value;
    }
  }
  return null;
}

const _generatedContextBlockCloseMarkers = <String, String>{
  '<command-name': '</command-name>',
  '<command': '</command>',
  '<image': '</image>',
  '<system_message': '</system_message>',
  '<system-message': '</system-message>',
  '<environment_context': '</environment_context>',
  '<app-context': '</app-context>',
  '<apps_instructions': '</apps_instructions>',
  '<apps-instructions': '</apps-instructions>',
  '<skills_instructions': '</skills_instructions>',
  '<plugins_instructions': '</plugins_instructions>',
  '<recommended_plugins': '</recommended_plugins>',
  '<additional_metadata': '</additional_metadata>',
  '<collaboration_mode': '</collaboration_mode>',
  '<permissions instructions': '</permissions instructions>',
  '<system': '</system>',
  '<developer': '</developer>',
  '<instructions': '</instructions>',
  '<local-command-caveat': '</local-command-caveat>',
  '<local-command-output': '</local-command-output>',
  '<local-command-stdout': '</local-command-stdout>',
  '<local-command-stderr': '</local-command-stderr>',
};

bool _lineContainsContextClose(String lowerLine, String closeMarker) {
  return lowerLine.contains(closeMarker) ||
      _compactContextMarker(
        lowerLine,
      ).contains(_compactContextMarker(closeMarker));
}

String _compactContextMarker(String value) {
  return value.replaceAll(RegExp(r'[_\-\s]'), '');
}

bool _generatedControlText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return lower.startsWith('<local-command-caveat>') ||
      lower.startsWith('<command-name') ||
      lower.startsWith('<command') ||
      lower.startsWith('<local-command-output>') ||
      lower.startsWith('<local-command-stdout>') ||
      lower.startsWith('<local-command-stderr>') ||
      lower.startsWith('<local-command-exit-code>') ||
      lower.startsWith('<local-command-timeout>') ||
      lower.startsWith('<environment_context>') ||
      lower.startsWith('<apps_instructions>') ||
      lower.startsWith('<apps-instructions>') ||
      lower.startsWith('<recommended_plugins') ||
      lower.startsWith('<additional_metadata') ||
      lower.startsWith('<plugins_instructions') ||
      _generatedOperationalNoticeText(text) ||
      _generatedStructuredResultText(text) ||
      _generatedAutomationChecklistText(text) ||
      _backgroundContextPromptText(text) ||
      (lower.contains('<local-command-caveat>') &&
          lower.contains('do not respond'));
}

bool _generatedOperationalNoticeText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return _antigravitySystemBoilerplateText(text) ||
      lower.contains('auto mode cannot determine the safety of') ||
      lower.contains('wait briefly and then try this action again') ||
      lower.contains('do not require the classifier and can still be used') ||
      lower.startsWith('the classifier is blocking ') ||
      (lower.contains('temporarily unavailable') &&
          lower.contains('classifier')) ||
      (lower.contains('temporarily unavailable') &&
          lower.contains('auto mode cannot determine'));
}

bool _antigravitySystemBoilerplateText(String text) {
  final lower = text.trim().toLowerCase();
  if (lower.isEmpty) {
    return false;
  }
  return (lower.contains('<system_message>') &&
          lower.contains('not actually sent by the user')) ||
      (lower.contains('not actually sent by the user') &&
          lower.contains('important information to pay attention')) ||
      lower.startsWith('the following is a <system_message>') ||
      lower.startsWith('the following is a <system-message>');
}

bool _generatedStructuredResultText(String text) {
  final normalized = text.trimLeft();
  final lower = normalized.toLowerCase();
  final firstLine = normalized
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '')
      .toLowerCase();
  final startsLikeStructuredResult =
      firstLine.startsWith('"ok":') ||
      firstLine.startsWith("'ok':") ||
      firstLine.startsWith('ok:') ||
      (firstLine.startsWith('{') &&
          (lower.contains('"ok"') || lower.contains("'ok'")));
  if (!startsLikeStructuredResult) {
    return false;
  }
  return lower.contains('"ok": true') ||
      lower.contains("'ok': true") ||
      lower.contains('ok: true') ||
      lower.contains('"command"') ||
      lower.contains('"args"') ||
      lower.contains('"sideeffects"') ||
      lower.contains('"requiredservices"') ||
      lower.contains('"timeoutclass"') ||
      lower.contains('"flakepolicy"') ||
      lower.contains('"profiles"') ||
      lower.contains('"artifacts"') ||
      lower.contains('node --test') ||
      lower.contains('npm run ');
}

bool _generatedAutomationChecklistText(String text) {
  final lower = text.trimLeft().toLowerCase();
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.trimLeft().toLowerCase())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final checklistLines = lines
      .where(
        (line) =>
            line.startsWith('- [ ]') ||
            line.startsWith('- [x]') ||
            line.startsWith('* [ ]') ||
            line.startsWith('* [x]'),
      )
      .length;
  if (checklistLines < 2) {
    return false;
  }
  return lower.contains('classifier') ||
      lower.contains('sandbox') ||
      lower.contains('approval policy') ||
      lower.contains('tool call') ||
      lower.contains('local command') ||
      lower.contains('execution adapter') ||
      lower.contains('sideeffects') ||
      lower.contains('requiredservices') ||
      lower.contains('timeoutclass');
}

bool _backgroundContextPromptText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return _antigravitySystemBoilerplateText(text) ||
      lower.startsWith('# agents.md instructions') ||
      lower.startsWith('agents.md instructions') ||
      lower.startsWith('<instructions>') ||
      lower.startsWith('you are codex, a coding agent') ||
      lower.startsWith('you are chatgpt') ||
      _looksLikeDelegatedAgentPrompt(text) ||
      lower.startsWith('knowledge cutoff:') ||
      lower.startsWith('current date:') ||
      lower.startsWith('filesystem sandboxing defines') ||
      lower.startsWith('sandbox_mode') ||
      lower.startsWith('<system') ||
      lower.startsWith('<system_message') ||
      lower.startsWith('<system-message') ||
      lower.startsWith('<developer') ||
      lower.startsWith('<app-context') ||
      lower.startsWith('<apps_instructions') ||
      lower.startsWith('<apps-instructions') ||
      lower.startsWith('<environment_context') ||
      lower.startsWith('<skills_instructions') ||
      lower.startsWith('<plugins_instructions') ||
      lower.startsWith('<collaboration_mode');
}

bool _looksLikeDelegatedAgentPrompt(String text) {
  final first = text
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '')
      .toLowerCase();
  if (first.startsWith('you are a')) {
    final rest = first.substring('you are a'.length);
    final digits = RegExp(r'^\d+').stringMatch(rest) ?? '';
    if (digits.isNotEmpty && rest.substring(digits.length).startsWith(':')) {
      return true;
    }
  }
  if (first.startsWith('you are agent a')) {
    final rest = first.substring('you are agent a'.length);
    final digits = RegExp(r'^\d+').stringMatch(rest) ?? '';
    if (digits.isNotEmpty && rest.substring(digits.length).startsWith(':')) {
      return true;
    }
  }
  return first.startsWith('you are ') &&
      first.contains(' worker') &&
      (first.contains(' round-') ||
          first.contains('worker-') ||
          first.contains('codex security') ||
          first.contains('you are not the coordinator') ||
          first.contains('worker-local'));
}

String visibleAgentConversationTitle(
  String rawTitle,
  List<AgentConversationMessage> messages, {
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
}) {
  final decodedTitle =
      _isAntigravityConversation(
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      )
      ? _extractAntigravityUserRequest(rawTitle)
      : rawTitle;
  final cleanTitle = _oneLineConversationTitle(
    _stripGeneratedContextBlocks(decodedTitle),
  );
  if (cleanTitle.isNotEmpty &&
      !_generatedControlText(cleanTitle) &&
      !_backgroundContextPromptText(cleanTitle) &&
      !_generatedStatusTitle(cleanTitle)) {
    return cleanTitle;
  }
  for (final message in messages) {
    final role = message.role.toLowerCase().trim();
    if (role == 'user' || role == 'human') {
      final title = _oneLineConversationTitle(
        _stripGeneratedContextBlocks(message.text),
      );
      if (title.isNotEmpty &&
          !_generatedControlText(title) &&
          !_backgroundContextPromptText(title) &&
          !_generatedStatusTitle(title)) {
        return title;
      }
    }
  }
  return 'Native agent history';
}

String _oneLineConversationTitle(String value) {
  final line = value
      .trim()
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (line.length <= 120) {
    return line;
  }
  return '${line.substring(0, 117)}...';
}

bool _generatedStatusTitle(String value) {
  final lower = value.trimLeft().toLowerCase();
  return lower.startsWith('updated ') ||
      lower.startsWith('created ') ||
      lower.startsWith('deleted ') ||
      lower.startsWith('renamed ') ||
      lower.startsWith('moved ') ||
      lower.startsWith('indexed ') ||
      lower.startsWith('the conversation has been cleared') ||
      lower.startsWith('conversation has been cleared');
}

int _findCaseInsensitive(String text, String pattern) {
  return text.toLowerCase().indexOf(pattern.toLowerCase());
}
