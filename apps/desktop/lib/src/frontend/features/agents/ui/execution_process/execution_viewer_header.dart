import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ExecutionViewerHeader extends StatelessWidget {
  const ExecutionViewerHeader({
    super.key,
    required this.agentIcon,
    required this.agentName,
    required this.conversationTitle,
    required this.onClose,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onNextMatch,
    required this.onPreviousMatch,
    required this.hasSubmittedQuery,
    required this.matchCount,
    required this.matchIndex,
  });

  final Widget agentIcon;
  final String agentName;
  final String conversationTitle;
  final VoidCallback onClose;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onNextMatch;
  final VoidCallback onPreviousMatch;
  final bool hasSubmittedQuery;
  final int matchCount;
  final int matchIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SizedBox(width: 36, height: 36, child: agentIcon),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                agentName,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                conversationTitle,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
    final close = IconButton(
      key: const Key('execution-process-close'),
      tooltip: strings.close,
      onPressed: onClose,
      icon: const Icon(Icons.close_rounded, size: 20),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          if (constraints.maxWidth >= 800 * scale) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: identity),
                const SizedBox(width: 22),
                Expanded(flex: 2, child: _buildSearch(context)),
                const SizedBox(width: 22),
                Expanded(
                  child: Align(alignment: Alignment.topRight, child: close),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 8),
                  close,
                ],
              ),
              const SizedBox(height: 14),
              _buildSearch(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearch(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                onPreviousMatch,
          },
          child: TextField(
            key: const Key('execution-process-search'),
            controller: searchController,
            focusNode: searchFocus,
            onChanged: onSearchChanged,
            onEditingComplete: () {},
            onSubmitted: (_) => onNextMatch(),
            textInputAction: TextInputAction.search,
            style: TextStyle(color: colors.text, fontSize: 13),
            decoration: InputDecoration(
              hintText: strings.executionProcessSearch,
              hintMaxLines: 2,
              prefixIcon: Icon(
                Icons.search_rounded,
                color: colors.textMuted,
                size: 19,
              ),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: strings.clearSearch,
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
              isDense: true,
              filled: true,
              fillColor: colors.surfaceLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LicoRadius.chip),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (hasSubmittedQuery)
          Row(
            children: [
              Expanded(
                child: Text(
                  matchCount == 0
                      ? strings.executionProcessNoMatches
                      : strings.executionProcessMatches(
                          matchIndex + 1,
                          matchCount,
                        ),
                  key: const Key('execution-process-match-count'),
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ),
              IconButton(
                key: const Key('execution-process-previous-match'),
                tooltip: strings.executionProcessPreviousMatch,
                onPressed: matchCount == 0 ? null : onPreviousMatch,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
              ),
              IconButton(
                key: const Key('execution-process-next-match'),
                tooltip: strings.executionProcessNextMatch,
                onPressed: matchCount == 0 ? null : onNextMatch,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              ),
            ],
          ),
      ],
    );
  }
}
