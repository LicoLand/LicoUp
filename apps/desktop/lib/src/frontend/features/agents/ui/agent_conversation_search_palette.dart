import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/agent_conversation_search_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/destination_search_ranking.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_search.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Opens the command-palette style conversation search. The palette indexes
/// every loaded session (title plus materialized message text) with an
/// inverted index and ranks hits with a BM25-inspired scorer; sessions are
/// grouped under their agent in score order.
void showAgentConversationSearchPalette(
  BuildContext context,
  ClientController controller, {
  List<GlobalSearchFeatureEntry> features = const [],
  List<GlobalSearchFeatureEntry> settingsFeatures = const [],
  List<GlobalSearchFeatureEntry> agentFeatures = const [],
  List<GlobalSearchFeatureEntry> pluginFeatures = const [],
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
      settingsFeatures: settingsFeatures,
      agentFeatures: agentFeatures,
      pluginFeatures: pluginFeatures,
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
    this.settingsFeatures = const [],
    this.agentFeatures = const [],
    this.pluginFeatures = const [],
  });

  final ClientController controller;
  final VoidCallback onClose;
  final List<GlobalSearchFeatureEntry> features;
  final List<GlobalSearchFeatureEntry> settingsFeatures;
  final List<GlobalSearchFeatureEntry> agentFeatures;
  final List<GlobalSearchFeatureEntry> pluginFeatures;

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
  DestinationSearchHits _hits = const DestinationSearchHits();
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
    final destination = widget.controller.currentSection;
    final skillScore = destination == ClientSection.skillHub
        ? (Map<String, dynamic> skill, String needle) =>
              skillHubSearchScore(skill, needle).toDouble()
        : scoreSkillSearchEntry;
    final hits = rankDestinationSearch(
      destination: destination,
      query: query,
      features: widget.features,
      settingsFeatures: widget.settingsFeatures,
      agentFeatures: widget.agentFeatures,
      pluginFeatures: widget.pluginFeatures,
      skills: widget.controller.skillHubSkills,
      skillScore: skillScore,
      conversations: _index.search(query),
    );
    setState(() {
      _hits = hits;
      _selectedIndex = 0;
    });
  }

  int get _resultCount => _hits.resultCount;

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
          _selectedIndex = (_selectedIndex - 1 + _resultCount) % _resultCount;
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
    final skillsFirst =
        widget.controller.currentSection == ClientSection.skillHub;
    var remaining = index;
    if (skillsFirst) {
      if (remaining < _hits.skills.length) {
        widget.onClose();
        widget.controller.selectSection(ClientSection.skillHub);
        return;
      }
      remaining -= _hits.skills.length;
    }
    if (remaining < _hits.primary.length) {
      final feature = _hits.primary[remaining];
      widget.onClose();
      unawaited(feature.run());
      return;
    }
    remaining -= _hits.primary.length;
    if (remaining < _hits.features.length) {
      final feature = _hits.features[remaining];
      widget.onClose();
      unawaited(feature.run());
      return;
    }
    remaining -= _hits.features.length;
    if (!skillsFirst) {
      if (remaining < _hits.skills.length) {
        widget.onClose();
        widget.controller.selectSection(ClientSection.skillHub);
        return;
      }
      remaining -= _hits.skills.length;
    }
    unawaited(_activate(_hits.conversations[remaining]));
  }

  static String _primaryGroupLabel(LicoStrings strings, ClientSection section) {
    return switch (section) {
      ClientSection.settings => strings.settings,
      ClientSection.agentHub => strings.agentHub,
      ClientSection.pluginManagement => strings.pluginManagement,
      _ => strings.searchFeaturesGroup,
    };
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
                                  primaryHits: _hits.primary,
                                  primaryGroupLabel: _primaryGroupLabel(
                                    strings,
                                    widget.controller.currentSection,
                                  ),
                                  featureHits: _hits.features,
                                  featuresGroupLabel:
                                      strings.searchFeaturesGroup,
                                  skillHits: _hits.skills,
                                  skillsGroupLabel: strings.skillHub,
                                  skillsFirst:
                                      widget.controller.currentSection ==
                                      ClientSection.skillHub,
                                  hits: _hits.conversations,
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
  for (final term
      in normalized.split(RegExp(r'\s+')).where((term) => term.isNotEmpty)) {
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
    required this.primaryHits,
    required this.primaryGroupLabel,
    required this.featureHits,
    required this.featuresGroupLabel,
    required this.skillHits,
    required this.skillsGroupLabel,
    required this.skillsFirst,
    required this.hits,
    required this.targets,
    required this.selectedIndex,
    required this.onActivateAt,
  });

  final List<GlobalSearchFeatureEntry> primaryHits;
  final String primaryGroupLabel;
  final List<GlobalSearchFeatureEntry> featureHits;
  final String featuresGroupLabel;
  final List<Map<String, dynamic>> skillHits;
  final String skillsGroupLabel;
  final bool skillsFirst;
  final List<AgentConversationSearchHit> hits;
  final List<TargetCandidate> targets;
  final int selectedIndex;
  final void Function(int index) onActivateAt;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = <Widget>[];
    var cursor = 0;
    void addFeatureGroup(
      List<GlobalSearchFeatureEntry> entries,
      String label,
      IconData icon,
    ) {
      if (entries.isEmpty) {
        return;
      }
      rows.add(
        LicoGroupHeader(
          label: label,
          count: entries.length,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          leading: Icon(icon, size: 15, color: colors.textMuted),
        ),
      );
      for (var index = 0; index < entries.length; index++) {
        final feature = entries[index];
        final flatIndex = cursor + index;
        final selected = flatIndex == selectedIndex;
        rows.add(
          Material(
            color: selected ? colors.selectedSurface : Colors.transparent,
            child: InkWell(
              onTap: () => onActivateAt(flatIndex),
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
      cursor += entries.length;
    }

    void addSkills() {
      if (skillHits.isEmpty) {
        return;
      }
      rows.add(
        LicoGroupHeader(
          label: skillsGroupLabel,
          count: skillHits.length,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          leading: Icon(
            Icons.library_books_outlined,
            size: 15,
            color: colors.textMuted,
          ),
        ),
      );
      for (var index = 0; index < skillHits.length; index++) {
        final skill = skillHits[index];
        final flatIndex = cursor + index;
        final selected = flatIndex == selectedIndex;
        final title = (skill['title'] ?? skill['skillId'] ?? '').toString();
        final description = (skill['description'] ?? '').toString();
        rows.add(
          Material(
            color: selected ? colors.selectedSurface : Colors.transparent,
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
      cursor += skillHits.length;
    }

    if (skillsFirst) {
      addSkills();
    }
    addFeatureGroup(primaryHits, primaryGroupLabel, Icons.bolt_outlined);
    addFeatureGroup(featureHits, featuresGroupLabel, Icons.bolt_outlined);
    if (!skillsFirst) {
      addSkills();
    }
    final conversationBase = cursor;
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
        LicoGroupHeader(
          label: name,
          count: groups[agentId]!.length,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          leading: target != null
              ? AgentBrandIcon(target: target, size: 18, iconSize: 12)
              : null,
        ),
      );
      for (final hitIndex in groups[agentId]!) {
        final hit = hits[hitIndex];
        final flatIndex = conversationBase + hitIndex;
        final selected = flatIndex == selectedIndex;
        rows.add(
          Material(
            color: selected ? colors.selectedSurface : Colors.transparent,
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
