import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/features/agents/data/agent_render_adapter_asset_source.dart';
import 'package:licoup/src/contracts/agent_render_adapter_source.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';

export 'package:licoup/src/frontend/features/agents/data/agent_render_adapter_asset_source.dart'
    show AssetAgentRenderAdapterJsonSource;

enum AgentAssistantLayout { document, bubble }

class AgentRenderAdapter {
  const AgentRenderAdapter({
    required this.id,
    required this.displayName,
    required this.match,
    required this.assistantLayout,
    required this.assistantMaxWidth,
    required this.assistantHorizontalInset,
    required this.assistantVerticalPadding,
    required this.showAssistantRoleLabel,
    required this.showUserRoleLabel,
    required this.userBubble,
    required this.markdownStyle,
    required this.codeTone,
    required this.quoteTone,
  });

  final String id;
  final String displayName;
  final AgentRenderAdapterMatch match;
  final AgentAssistantLayout assistantLayout;
  final double assistantMaxWidth;
  final double assistantHorizontalInset;
  final double assistantVerticalPadding;
  final bool showAssistantRoleLabel;
  final bool showUserRoleLabel;
  final AgentUserBubbleStyle userBubble;
  final MessageMarkdownStyle markdownStyle;
  final String codeTone;
  final String quoteTone;

  static AgentRenderAdapter fallback() {
    return AgentRenderAdapter.fromJson(const {
      'id': 'generic',
      'displayName': 'Generic Agent',
      'match': {
        'agentIds': ['*'],
      },
      'layout': {
        'assistant': 'document',
        'assistantMaxWidth': 760,
        'assistantHorizontalInset': 24,
        'assistantVerticalPadding': 14,
        'showAssistantRoleLabel': false,
        'showUserRoleLabel': false,
      },
      'userBubble': {
        'maxWidth': 620,
        'radius': 24,
        'paddingX': 18,
        'paddingY': 12,
        'tone': 'neutral',
      },
      'markdown': {
        'bodyFontSize': 15,
        'bodyLineHeight': 1.52,
        'blockSpacing': 14,
        'heading1FontSize': 20,
        'heading2FontSize': 18,
        'heading3FontSize': 16,
        'headingWeight': 800,
        'codeRadius': 14,
        'codePadding': 16,
        'showCodeLanguage': true,
        'unorderedMarker': '\u2022',
      },
      'tones': {'code': 'raised', 'quote': 'subtle'},
    });
  }

  factory AgentRenderAdapter.fromJson(Map<String, dynamic> json) {
    final layout = _map(json['layout']);
    final tones = _map(json['tones']);
    return AgentRenderAdapter(
      id: _string(json['id'], fallback: 'generic'),
      displayName: _string(json['displayName'], fallback: 'Generic Agent'),
      match: AgentRenderAdapterMatch.fromJson(_map(json['match'])),
      assistantLayout:
          _string(layout['assistant'], fallback: 'document') == 'bubble'
          ? AgentAssistantLayout.bubble
          : AgentAssistantLayout.document,
      assistantMaxWidth: _double(layout['assistantMaxWidth'], fallback: 760),
      assistantHorizontalInset: _double(
        layout['assistantHorizontalInset'],
        fallback: 24,
      ),
      assistantVerticalPadding: _double(
        layout['assistantVerticalPadding'],
        fallback: 14,
      ),
      showAssistantRoleLabel: _bool(
        layout['showAssistantRoleLabel'],
        fallback: false,
      ),
      showUserRoleLabel: _bool(layout['showUserRoleLabel'], fallback: false),
      userBubble: AgentUserBubbleStyle.fromJson(_map(json['userBubble'])),
      markdownStyle: _markdownStyleFromJson(_map(json['markdown'])),
      codeTone: _string(tones['code'], fallback: 'raised'),
      quoteTone: _string(tones['quote'], fallback: 'subtle'),
    );
  }

  int matchScore({
    required String agentId,
    String sourceClient = '',
    String sourceTool = '',
    String adapterId = '',
  }) {
    final normalizedAgentId = _normalizeId(agentId);
    final normalizedSourceClient = _normalizeId(sourceClient);
    final normalizedSourceTool = _normalizeId(sourceTool);
    final normalizedAdapterId = _normalizeId(adapterId);
    if (match.agentIds.contains('*')) {
      return 1;
    }
    var score = 0;
    if (normalizedSourceClient.isNotEmpty &&
        match.sourceClients.contains(normalizedSourceClient)) {
      score = score < 110 ? 110 : score;
    }
    if (normalizedSourceTool.isNotEmpty &&
        match.sourceClients.contains(normalizedSourceTool)) {
      score = score < 100 ? 100 : score;
    }
    if (normalizedAgentId.isNotEmpty &&
        match.agentIds.contains(normalizedAgentId)) {
      score = score < 90 ? 90 : score;
    }
    if (normalizedAdapterId.isNotEmpty &&
        match.adapterIds.contains(normalizedAdapterId)) {
      score = score < 80 ? 80 : score;
    }
    return score;
  }
}

class AgentRenderAdapterMatch {
  const AgentRenderAdapterMatch({
    required this.agentIds,
    required this.sourceClients,
    required this.adapterIds,
  });

  final Set<String> agentIds;
  final Set<String> sourceClients;
  final Set<String> adapterIds;

  factory AgentRenderAdapterMatch.fromJson(Map<String, dynamic> json) {
    return AgentRenderAdapterMatch(
      agentIds: _stringSet(json['agentIds']),
      sourceClients: _stringSet(json['sourceClients']),
      adapterIds: _stringSet(json['adapterIds']),
    );
  }
}

class AgentUserBubbleStyle {
  const AgentUserBubbleStyle({
    required this.maxWidth,
    required this.radius,
    required this.paddingX,
    required this.paddingY,
    required this.tone,
  });

  final double maxWidth;
  final double radius;
  final double paddingX;
  final double paddingY;
  final String tone;

  factory AgentUserBubbleStyle.fromJson(Map<String, dynamic> json) {
    return AgentUserBubbleStyle(
      maxWidth: _double(json['maxWidth'], fallback: 620),
      radius: _double(json['radius'], fallback: 24),
      paddingX: _double(json['paddingX'], fallback: 18),
      paddingY: _double(json['paddingY'], fallback: 12),
      tone: _string(json['tone'], fallback: 'neutral'),
    );
  }
}

class AgentRenderAdapterRegistry {
  AgentRenderAdapterRegistry({
    AssetBundle? assetBundle,
    AgentRenderAdapterJsonSource? jsonSource,
  }) : _jsonSource =
           jsonSource ?? AssetAgentRenderAdapterJsonSource(assetBundle);

  static AgentRenderAdapterRegistry instance = AgentRenderAdapterRegistry();

  final AgentRenderAdapterJsonSource _jsonSource;
  Future<List<AgentRenderAdapter>>? _cachedAdapters;

  Future<AgentRenderAdapter> resolve({
    required String agentId,
    String sourceClient = '',
    String sourceTool = '',
    String adapterId = '',
  }) async {
    final adapters = await loadAdapters();
    AgentRenderAdapter? best;
    var bestScore = 0;
    for (final adapter in adapters) {
      final score = adapter.matchScore(
        agentId: agentId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        adapterId: adapterId,
      );
      if (score > bestScore) {
        best = adapter;
        bestScore = score;
      }
    }
    return best ?? AgentRenderAdapter.fallback();
  }

  Future<List<AgentRenderAdapter>> loadAdapters() {
    return _cachedAdapters ??= _loadAdapters();
  }

  Future<List<AgentRenderAdapter>> _loadAdapters() async {
    final adapters = <AgentRenderAdapter>[];
    for (final json in await _jsonSource.loadAdapterJson()) {
      try {
        adapters.add(AgentRenderAdapter.fromJson(json));
      } catch (_) {
        // A malformed adapter should not block the conversation surface.
      }
    }
    final byId = <String, AgentRenderAdapter>{};
    for (final adapter in adapters) {
      byId[adapter.id] = adapter;
    }
    final loaded = byId.values.toList(growable: false);
    return loaded.isEmpty ? [AgentRenderAdapter.fallback()] : loaded;
  }
}

MessageMarkdownStyle _markdownStyleFromJson(Map<String, dynamic> json) {
  return MessageMarkdownStyle(
    bodyFontSize: _double(json['bodyFontSize'], fallback: 15),
    bodyLineHeight: _double(json['bodyLineHeight'], fallback: 1.52),
    blockSpacing: _double(json['blockSpacing'], fallback: 14),
    heading1FontSize: _double(json['heading1FontSize'], fallback: 20),
    heading2FontSize: _double(json['heading2FontSize'], fallback: 18),
    heading3FontSize: _double(json['heading3FontSize'], fallback: 16),
    headingLineHeight: _double(json['headingLineHeight'], fallback: 1.25),
    headingWeight: _fontWeight(
      json['headingWeight'],
      fallback: FontWeight.w800,
    ),
    codeFontSize: _double(json['codeFontSize'], fallback: 13),
    codeLineHeight: _double(json['codeLineHeight'], fallback: 1.45),
    codeRadius: _double(json['codeRadius'], fallback: 14),
    codePadding: _double(json['codePadding'], fallback: 16),
    showCodeLanguage: _bool(json['showCodeLanguage'], fallback: true),
    quoteRadius: _double(json['quoteRadius'], fallback: 12),
    quotePaddingX: _double(json['quotePaddingX'], fallback: 14),
    quotePaddingY: _double(json['quotePaddingY'], fallback: 12),
    listMarkerWidth: _double(json['listMarkerWidth'], fallback: 24),
    orderedListMarkerWidth: _double(
      json['orderedListMarkerWidth'],
      fallback: 34,
    ),
    listItemSpacing: _double(json['listItemSpacing'], fallback: 7),
    unorderedMarker: _string(json['unorderedMarker'], fallback: '•'),
  );
}

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : const {};
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<String>()
      .map(_normalizeId)
      .where((item) => item.isNotEmpty || item == '*')
      .toList(growable: false);
}

Set<String> _stringSet(Object? value) {
  return _stringList(value).toSet();
}

String _string(Object? value, {required String fallback}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

double _double(Object? value, {required double fallback}) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value.trim()) ?? fallback;
  }
  return fallback;
}

bool _bool(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => fallback,
    };
  }
  return fallback;
}

FontWeight _fontWeight(Object? value, {required FontWeight fallback}) {
  final weight = value is num
      ? value.toInt()
      : value is String
      ? int.tryParse(value.trim())
      : null;
  return switch (weight) {
    100 => FontWeight.w100,
    200 => FontWeight.w200,
    300 => FontWeight.w300,
    400 => FontWeight.w400,
    500 => FontWeight.w500,
    600 => FontWeight.w600,
    700 => FontWeight.w700,
    800 => FontWeight.w800,
    900 => FontWeight.w900,
    _ => fallback,
  };
}

String _normalizeId(String value) {
  return value.trim().toLowerCase();
}
