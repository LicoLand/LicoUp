import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/agent_conversation_search_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Opens the command-palette style conversation search. The palette indexes
/// every loaded session (title plus materialized message text) with an
/// inverted index and ranks hits with a BM25-inspired scorer; sessions are
/// grouped under their agent in score order.
void showAgentConversationSearchPalette(
  BuildContext context,
  ClientController controller, {
  List<GlobalSearchFeatureEntry> features = const [],
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) {
    return;
  }
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => AgentConversationSearchPalette(
      controller: controller,
      features: features,
      onClose: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class AgentConversationSearchPalette extends StatefulWidget {
  const AgentConversationSearchPalette({
    super.key,
    required this.controller,
    required this.onClose,
    this.features = const [],
  });

  final ClientController controller;
  final VoidCallback onClose;
  final List<GlobalSearchFeatureEntry> features;

  @override
  State<AgentConversationSearchPalette> createState() =>
      _AgentConversationSearchPaletteState();
}

class _AgentConversationSearchPaletteState
    extends State<AgentConversationSearchPalette> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final AgentConversationSearchIndex _index = AgentConversationSearchIndex();
  Map<String, List<AgentConversationSession>>? _indexedSessions;
  List<Map<String, dynamic>>? _indexedSkills;
  List<GlobalSearchFeatureEntry> _featureHits = const [];
  List<Map<String, dynamic>> _skillHits = const [];
  List<AgentConversationSearchHit> _hits = const [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _reindexIfNeeded();
    _queryController.addListener(_applyQuery);
    // Pull a first page for agents without any loaded sessions so the search
    // genuinely covers every conversation.
    for (final target in widget.controller.scannedTargets) {
      if (!target.isConversationAgent) {
        continue;
      }
      final loaded = widget.controller.conversationSessionsByAgent[target.id];
      if (loaded == null || loaded.isEmpty) {
        unawaited(widget.controller.refreshConversationSessions(target.id));
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _queryFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  bool _reindexIfNeeded() {
    final sessions = widget.controller.conversationSessionsByAgent;
    final skills = widget.controller.skillHubSkills;
    var changed = false;
    if (!identical(skills, _indexedSkills)) {
      _indexedSkills = skills;
      changed = true;
    }
    if (!identical(sessions, _indexedSessions)) {
      _indexedSessions = sessions;
      _index.rebuild([
        for (final entry in sessions.entries)
          for (final session in entry.value)
            AgentConversationSearchDocument(
              agentId: entry.key,
              sessionId: session.id,
              title: session.title,
              content: _sessionContent(session),
              updatedAt: DateTime.tryParse(session.updatedAt),
            ),
      ]);
      changed = true;
    }
    return changed;
  }

  static String _sessionContent(AgentConversationSession session) {
    final buffer = StringBuffer(session.title);
    for (final message in session.messages) {
      final text = message.text.trim();
      if (text.isEmpty) {
        continue;
      }
      buffer.write('\n');
      buffer.write(text);
      if (buffer.length > 24000) {
        break;
      }
    }
    return buffer.toString();
  }

  void _applyQuery() {
    final query = _queryController.text;
    final featureHits =
        [
            for (final feature in widget.features)
              if (feature.matchScore(query) > 0) feature,
          ]
          ..sort(
            (a, b) => b.matchScore(query).compareTo(a.matchScore(query)),
          );
    final skillHits =
        [
            for (final skill in widget.controller.skillHubSkills)
              if (scoreSkillSearchEntry(skill, query) > 0) skill,
          ]
          ..sort(
            (a, b) => scoreSkillSearchEntry(
              b,
              query,
            ).compareTo(scoreSkillSearchEntry(a, query)),
          );
    final hits = _index.search(query);
    setState(() {
      _featureHits = featureHits;
      _skillHits = skillHits.take(6).toList(growable: false);
      _hits = hits;
      _selectedIndex = 0;
    });
  }

  int get _resultCount =>
      _featureHits.length + _skillHits.length + _hits.length;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_resultCount > 0) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % _resultCount;
        });
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_resultCount > 0) {
        setState(() {
          _selectedIndex =
              (_selectedIndex - 1 + _resultCount) % _resultCount;
        });
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (_resultCount > 0) {
        _activateAt(_selectedIndex);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activateAt(int index) {
    if (index < _featureHits.length) {
      final feature = _featureHits[index];
      widget.onClose();
      unawaited(feature.run());
      return;
    }
    final skillIndex = index - _featureHits.length;
    if (skillIndex < _skillHits.length) {
      final controller = widget.controller;
      widget.onClose();
      controller.selectSection(ClientSection.skillHub);
      return;
    }
    unawaited(
      _activate(_hits[skillIndex - _skillHits.length]),
    );
  }

  Future<void> _activate(AgentConversationSearchHit hit) async {
    final controller = widget.controller;
    widget.onClose();
    await controller.selectConversationAgent(hit.document.agentId);
    controller.selectConversationSession(hit.document.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (_reindexIfNeeded() && _queryController.text.trim().isNotEmpty) {
          // Fresh session/skill data arrived after the query was typed.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _applyQuery();
            }
          });
        }
        final size = MediaQuery.sizeOf(context);
        final panelWidth = (size.width * 0.62).clamp(420.0, 640.0);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: ColoredBox(color: Colors.black.withAlpha(90)),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 72),
                child: Material(
                  elevation: 18,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  color: colors.surface,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: panelWidth.toDouble(),
                      maxHeight: size.height * 0.68,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                          child: Focus(
                            onKeyEvent: _handleKeyEvent,
                            child: TextField(
                              key: const Key(
                                'conversation-search-palette-input',
                              ),
                              controller: _queryController,
                              focusNode: _queryFocus,
                              autofocus: true,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 14,
                                height: 1.1,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                isCollapsed: true,
                                border: InputBorder.none,
                                hintText: strings.searchConversationsHint,
                                hintStyle: TextStyle(
                                  color: colors.textMuted.withAlpha(190),
                                  fontSize: 14,
                                  height: 1.1,
                                ),
                                icon: Icon(
                                  Icons.search_rounded,
                                  size: 17,
                                  color: colors.textMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Divider(height: 1, color: colors.line.withAlpha(90)),
                        Flexible(
                          child: _queryController.text.trim().isEmpty
                              ? _PaletteHint(
                                  label: strings.searchConversationsHint,
                                )
                              : _resultCount == 0
                              ? _PaletteHint(
                                  label: strings.noConversationSearchResults,
                                )
                              : _GroupedHitList(
                                  featureHits: _featureHits,
                                  featuresGroupLabel:
                                      strings.searchFeaturesGroup,
                                  skillHits: _skillHits,
                                  skillsGroupLabel: strings.skillHub,
                                  hits: _hits,
                                  targets: widget.controller.scannedTargets,
                                  selectedIndex: _selectedIndex,
                                  onActivateAt: _activateAt,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Scores one skill-catalog entry for the global search: the skill id and
/// title dominate, author and description fill in secondary evidence.
double scoreSkillSearchEntry(Map<String, dynamic> skill, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 0;
  }
  final title = (skill['title'] ?? '').toString().toLowerCase();
  final skillId = (skill['skillId'] ?? '').toString().toLowerCase();
  final author = (skill['author'] ?? '').toString().toLowerCase();
  final description = (skill['description'] ?? '').toString().toLowerCase();
  var score = 0.0;
  if (title.contains(normalized)) {
    score += 6;
  }
  if (skillId.contains(normalized)) {
    score += 5;
  }
  if (author.contains(normalized)) {
    score += 2;
  }
  for (final term in normalized
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)) {
    if (title.contains(term)) {
      score += 2;
    } else if (skillId.contains(term)) {
      score += 1.5;
    } else if (description.contains(term)) {
      score += 1;
    }
  }
  return score;
}

class _PaletteHint extends StatelessWidget {
  const _PaletteHint({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        label,
        style: TextStyle(color: colors.textMuted, fontSize: 12.5),
      ),
    );
  }
}

class _GroupedHitList extends StatelessWidget {
  const _GroupedHitList({
    required this.featureHits,
    required this.featuresGroupLabel,
    required this.skillHits,
    required this.skillsGroupLabel,
    required this.hits,
    required this.targets,
    required this.selectedIndex,
    required this.onActivateAt,
  });

  final List<GlobalSearchFeatureEntry> featureHits;
  final String featuresGroupLabel;
  final List<Map<String, dynamic>> skillHits;
  final String skillsGroupLabel;
  final List<AgentConversationSearchHit> hits;
  final List<TargetCandidate> targets;
  final int selectedIndex;
  final void Function(int index) onActivateAt;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = <Widget>[];
    if (featureHits.isNotEmpty) {
      rows.add(
        _GroupHeader(
          icon: Icons.bolt_outlined,
          label: featuresGroupLabel,
          count: featureHits.length,
        ),
      );
      for (var index = 0; index < featureHits.length; index++) {
        final feature = featureHits[index];
        final selected = index == selectedIndex;
        rows.add(
          Material(
            color: selected
                ? colors.surfaceHigh.withAlpha(160)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onActivateAt(index),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 8, 14, 8),
                child: Row(
                  children: [
                    Icon(feature.icon, size: 16, color: colors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        feature.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.north_east_rounded,
                      size: 12,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    if (skillHits.isNotEmpty) {
      rows.add(
        _GroupHeader(
          icon: Icons.library_books_outlined,
          label: skillsGroupLabel,
          count: skillHits.length,
        ),
      );
      for (var index = 0; index < skillHits.length; index++) {
        final skill = skillHits[index];
        final flatIndex = featureHits.length + index;
        final selected = flatIndex == selectedIndex;
        final title = (skill['title'] ?? skill['skillId'] ?? '').toString();
        final description = (skill['description'] ?? '').toString();
        rows.add(
          Material(
            color: selected
                ? colors.surfaceHigh.withAlpha(160)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onActivateAt(flatIndex),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 7, 14, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.trim().isEmpty
                          ? (skill['skillId'] ?? '').toString()
                          : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (description.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    final groups = <String, List<int>>{};
    final groupOrder = <String>[];
    for (var index = 0; index < hits.length; index++) {
      final agentId = hits[index].document.agentId;
      if (groups.putIfAbsent(agentId, () => []).isEmpty) {
        groupOrder.add(agentId);
      }
      groups[agentId]!.add(index);
    }
    for (final agentId in groupOrder) {
      final target = _targetFor(agentId);
      final name = target == null
          ? agentId
          : agentConversationTargetDisplayName(target);
      rows.add(
        _GroupHeader(
          label: name,
          count: groups[agentId]!.length,
          target: target,
        ),
      );
      for (final hitIndex in groups[agentId]!) {
        final hit = hits[hitIndex];
        final flatIndex = featureHits.length + skillHits.length + hitIndex;
        final selected = flatIndex == selectedIndex;
        rows.add(
          Material(
            color: selected
                ? colors.surfaceHigh.withAlpha(160)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onActivateAt(flatIndex),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 7, 14, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.document.title.trim().isEmpty
                          ? hit.document.sessionId
                          : hit.document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: hit.titleMatched
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (hit.snippet.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        hit.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    return ListView(
      key: const Key('conversation-search-palette-results'),
      padding: const EdgeInsets.only(bottom: 12),
      shrinkWrap: true,
      children: rows,
    );
  }

  TargetCandidate? _targetFor(String agentId) {
    for (final target in targets) {
      if (target.id == agentId || target.target == agentId) {
        return target;
      }
    }
    return null;
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    this.icon,
    this.target,
  });

  final String label;
  final int count;
  final IconData? icon;
  final TargetCandidate? target;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          if (target != null) ...[
            AgentBrandIcon(target: target!, size: 18, iconSize: 12),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 15, color: colors.textMuted),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Text(
            '$count',
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
