import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/search/search_intent.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';

Future<void> showAgentConversationSearchPalette(
  BuildContext context,
  SearchBinding binding,
) async {
  binding.intents.send(
    OpenSearch(localeCode: Localizations.localeOf(context).languageCode),
  );
  await showDialog<void>(
    context: context,
    builder: (context) => _AgentConversationSearchPalette(binding: binding),
  );
  binding.intents.send(const DismissSearch());
}

class _AgentConversationSearchPalette extends StatefulWidget {
  const _AgentConversationSearchPalette({required this.binding});

  final SearchBinding binding;

  @override
  State<_AgentConversationSearchPalette> createState() =>
      _AgentConversationSearchPaletteState();
}

class _AgentConversationSearchPaletteState
    extends State<_AgentConversationSearchPalette> {
  late final TextEditingController _query;
  late final FocusNode _queryFocus;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(
      text: widget.binding.projection.current.query,
    );
    _queryFocus = FocusNode();
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Dialog(
      key: const Key('agent-conversation-search-palette'),
      alignment: const Alignment(0, -0.68),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 520),
        child: ProjectionBuilder<SearchProjection, SearchProjection>(
          source: widget.binding.projection,
          select: (projection) => projection,
          builder: (context, projection) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Focus(
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    key: const Key('agent-conversation-search-field'),
                    controller: _query,
                    focusNode: _queryFocus,
                    autofocus: true,
                    onChanged: (query) {
                      _selectedIndex = 0;
                      widget.binding.intents.send(UpdateSearchQuery(query));
                    },
                    decoration: InputDecoration(
                      hintText: strings.searchConversationsHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _query.clear();
                                _selectedIndex = 0;
                                widget.binding.intents.send(
                                  const UpdateSearchQuery(''),
                                );
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: _SearchResults(
                  projection: projection,
                  selectedIndex: _selectedIndex,
                  onSelect: (id) {
                    widget.binding.intents.send(SelectSearchResult(id));
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final results = widget.binding.projection.current.results;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (results.isNotEmpty) {
        setState(() => _selectedIndex = (_selectedIndex + 1) % results.length);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (results.isNotEmpty) {
        setState(
          () => _selectedIndex =
              (_selectedIndex - 1 + results.length) % results.length,
        );
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (results.isNotEmpty) {
        widget.binding.intents.send(
          SelectSearchResult(results[_selectedIndex].id),
        );
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.projection,
    required this.selectedIndex,
    required this.onSelect,
  });

  final SearchProjection projection;
  final int selectedIndex;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    if (projection.phase == PresentationPhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (projection.results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            projection.query.trim().isEmpty
                ? strings.searchConversationsHint
                : strings.noConversationSearchResults,
            style: TextStyle(color: context.licoColors.textMuted),
          ),
        ),
      );
    }
    final rows = <Widget>[];
    String? previousGroup;
    for (var index = 0; index < projection.results.length; index++) {
      final result = projection.results[index];
      if (result.groupId != previousGroup) {
        previousGroup = result.groupId;
        rows.add(
          LicoGroupHeader(
            label: result.groupLabel,
            count: projection.results
                .where((candidate) => candidate.groupId == result.groupId)
                .length,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            leading: Icon(
              _iconFor(result),
              size: 15,
              color: context.licoColors.textMuted,
            ),
          ),
        );
      }
      rows.add(
        Material(
          color: index == selectedIndex
              ? context.licoColors.selectedSurface
              : Colors.transparent,
          child: ListTile(
            key: ValueKey<String>('agent-conversation-search-${result.id}'),
            contentPadding: const EdgeInsets.fromLTRB(30, 0, 14, 0),
            dense: true,
            title: Text(
              result.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: result.emphasized
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
            subtitle: result.subtitle.trim().isEmpty
                ? null
                : Text(
                    result.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: result.resultKind == 'feature'
                ? const Icon(Icons.north_east_rounded, size: 12)
                : null,
            onTap: () => onSelect(result.id),
          ),
        ),
      );
    }
    return ListView(
      key: const Key('agent-conversation-search-results'),
      padding: const EdgeInsets.only(bottom: 12),
      shrinkWrap: true,
      children: rows,
    );
  }

  IconData _iconFor(SearchResultProjection result) =>
      switch (result.resultKind) {
        'skill' => Icons.library_books_outlined,
        'feature' => Icons.bolt_outlined,
        _ => switch (result.destination) {
          ClientSection.agents => Icons.psychology_outlined,
          ClientSection.monitoring => Icons.query_stats_outlined,
          ClientSection.skillHub => Icons.library_books_outlined,
          ClientSection.pluginManagement => Icons.extension_outlined,
          ClientSection.mobileRelay => Icons.phonelink_outlined,
          ClientSection.models => Icons.key_outlined,
          ClientSection.settings => Icons.settings_outlined,
          ClientSection.agentHub => Icons.auto_awesome_outlined,
        },
      };
}
