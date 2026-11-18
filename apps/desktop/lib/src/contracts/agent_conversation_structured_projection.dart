import 'dart:convert';

import 'agent_conversation_message.dart';

bool structuredConversationMessageKind(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall ||
    AgentConversationMessageKind.toolResult ||
    AgentConversationMessageKind.reasoning ||
    AgentConversationMessageKind.metadata ||
    AgentConversationMessageKind.error ||
    AgentConversationMessageKind.event => true,
    _ => false,
  };
}

String visibleStructuredConversationText(
  AgentConversationMessageKind kind,
  String text, {
  bool providerSummary = false,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return _redactStructuredConversationText(trimmed);
}

bool _looksLikeRawStructuredPayload(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('```json') &&
      !trimmed.startsWith('```JSON') &&
      !(trimmed.startsWith('{') && trimmed.endsWith('}')) &&
      !(trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    return false;
  }
  final candidate = trimmed.startsWith('```')
      ? trimmed
            .replaceFirst(RegExp(r'^```json\s*', caseSensitive: false), '')
            .replaceFirst(RegExp(r'\s*```$'), '')
      : trimmed;
  try {
    final decoded = jsonDecode(candidate);
    return decoded is Map || decoded is List;
  } catch (_) {
    return candidate.startsWith('{') || candidate.startsWith('[');
  }
}

String _redactStructuredConversationText(String text) {
  const operationalIdPlaceholder = 'LICOSAFEOPERATIONINDEX';
  final operationalIds = <String>[];
  final protected = text.replaceAllMapped(
    RegExp(r'\bround-[0-9]+/worker-[0-9]+\b', caseSensitive: false),
    (match) {
      operationalIds.add(match.group(0)!);
      return '$operationalIdPlaceholder${operationalIds.length - 1}';
    },
  );
  final redacted = protected
      .replaceAllMapped(
        RegExp(r'''"([a-zA-Z][a-zA-Z0-9_.-]{1,80})"\s*:\s*"[^"]*"'''),
        (match) => _structuredKeyIsSensitive(match.group(1)!)
            ? '"${match.group(1)}":"[redacted]"'
            : match.group(0)!,
      )
      .replaceAll(
        RegExp(r'\bbearer\s+[a-z0-9._~+/-]+=*', caseSensitive: false),
        'Bearer [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])((?:(?:[a-z][a-z0-9]*)[_-])*(?:api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?id|thread[_-]?id|conversation[_-]?id|native[_-]?(?:session|thread)[_-]?id|authorization|password|passwd|token|secret|key|cookie|credential))\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])([a-z][a-z0-9_.-]{1,80})(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => _structuredKeyIsSensitive(match.group(1)!)
            ? '${match.group(1)}: [redacted]'
            : match.group(0)!,
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])([a-z][a-z0-9]{1,48}(?:apikey|secretaccesskey|accesskey|clientsecret|accesstoken|refreshtoken|idtoken|sessionid|threadid|conversationid|password|passwd|token|secret|cookie|credential))\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:resume|load|open|restore|continue|delete|close|for)\s+(?:the\s+)?(?:session|thread|conversation)(?:\s+(?:id|identifier))?\s+)([a-z0-9._:-]{3,})''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:session|thread|conversation)(?:\s+(?:id|identifier))?\s*)["'][a-z0-9._:-]{3,}["']''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:session|thread|conversation)(?:\s+(?:id|identifier))?\s*(?::|=|\bis\b)\s*)([a-z0-9][a-z0-9._:-]{2,})''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:session|thread|conversation)(?:\s+(?:id|identifier))?\s+)(?=[a-z0-9._:-]{4,}\b)(?=[^\s,;]*[-_:0-9])([a-z0-9._:-]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[credentials hidden]@',
      )
      .replaceAll(
        RegExp(
          r'''file:///(?:[^\s"'<>/]+/)*[^\s"'<>]+|(?<![:/\w])/(?:[^\s"'<>/]+/)*[^\s"'<>]+|[a-z]:\\[^\s"'<>]*|\\\\[^\s"'<>\\]+\\[^\s"'<>]*|~[/\\][^\s"'<>]*|(?:^|(?<=\s))\.\.?[/\\][^\s"'<>]+|(?<![:/\w])(?:[a-z0-9_.-]+[/\\])+[a-z0-9_.-]+(?=[\s"'<>),.;:]|$)''',
          caseSensitive: false,
        ),
        '[local path hidden]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:cwd|path|directory|dir|project|workspace|folder|file)(?:\s*(?:[:=]|is|at|under|in))?\s+)([a-z0-9_.-]+[/\\][a-z0-9_./\\-]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[local path hidden]',
      )
      .replaceAll(RegExp(r'\b[a-zA-Z0-9_-]{40,}\b'), '[opaque value hidden]');
  return redacted.replaceAllMapped(
    RegExp('$operationalIdPlaceholder([0-9]+)'),
    (match) {
      final index = int.tryParse(match.group(1) ?? '');
      return index != null && index < operationalIds.length
          ? operationalIds[index]
          : '[operation id hidden]';
    },
  );
}

bool _structuredKeyIsSensitive(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return const {
        'authorization',
        'password',
        'passwd',
        'cookie',
        'credential',
        'apikey',
        'clientsecret',
        'secretaccesskey',
        'accesskeyid',
        'privatekey',
        'accesstoken',
        'refreshtoken',
        'idtoken',
        'sessionid',
        'threadid',
        'conversationid',
        'nativesessionid',
        'nativethreadid',
      }.contains(normalized) ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized.contains('credential') ||
      normalized.contains('accesskey') ||
      normalized.endsWith('key') ||
      normalized.endsWith('sessionid') ||
      normalized.endsWith('threadid') ||
      normalized.endsWith('conversationid');
}

bool _structuredProjectionIsSafe(String value) {
  var candidate = value
      .replaceAll(
        RegExp(
          r'''(?<![a-z0-9])[a-z][a-z0-9_.-]{0,80}\s*:\s*\[redacted\]''',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'\[(?:local path hidden|credentials hidden|opaque value hidden|redacted)\]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(r'\bround-[0-9]+/worker-[0-9]+\b', caseSensitive: false),
        '',
      );
  candidate = candidate.trim();
  if (candidate.isEmpty) {
    return true;
  }
  if (RegExp(r'''[/\\=@{}\[\]"'`]''').hasMatch(candidate)) {
    return false;
  }
  if (RegExp(
    r'''\b(?:session|thread|conversation|cwd|path|directory|workspace|project|folder|file|authorization|credential|password|passwd|cookie|token|secret|api.?key|access.?key|private.?key|signing.?key)\b''',
    caseSensitive: false,
  ).hasMatch(candidate)) {
    return false;
  }
  if (RegExp(
    r'\b[a-z0-9]+(?:[-_:][a-z0-9]+){3,}\b',
    caseSensitive: false,
  ).hasMatch(candidate)) {
    return false;
  }
  return true;
}

String stableConversationIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

String sanitizeStructuredLabel(String value, {String fallback = ''}) {
  final singleLine = _redactStructuredConversationText(
    value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
  );
  if (singleLine.isEmpty ||
      _looksLikeRawStructuredPayload(singleLine) ||
      !_structuredProjectionIsSafe(singleLine)) {
    return fallback;
  }
  final runes = singleLine.runes.toList(growable: false);
  return runes.length <= 96
      ? singleLine
      : '${String.fromCharCodes(runes.take(93))}…';
}

String defaultConversationCardType(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => 'tool-call',
    AgentConversationMessageKind.toolResult => 'tool-result',
    AgentConversationMessageKind.reasoning => 'reasoning',
    AgentConversationMessageKind.metadata => 'metadata',
    AgentConversationMessageKind.error => 'error',
    AgentConversationMessageKind.event => 'event',
    AgentConversationMessageKind.subagent => 'subagent',
    _ => '',
  };
}

String defaultConversationCardTitle(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => 'Tool call',
    AgentConversationMessageKind.toolResult => 'Tool result',
    AgentConversationMessageKind.reasoning => 'Reasoning',
    AgentConversationMessageKind.metadata => 'Metadata',
    AgentConversationMessageKind.error => 'Error',
    AgentConversationMessageKind.event => 'Native event',
    _ => '',
  };
}

String defaultConversationCardSubtitle(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => 'Native agent activity',
    AgentConversationMessageKind.toolResult => 'Native agent result',
    AgentConversationMessageKind.error => 'Native agent error',
    AgentConversationMessageKind.event => 'Native agent event',
    _ => '',
  };
}

bool conversationCardCollapsedByDefault(AgentConversationMessageKind kind) {
  return kind != AgentConversationMessageKind.error;
}
