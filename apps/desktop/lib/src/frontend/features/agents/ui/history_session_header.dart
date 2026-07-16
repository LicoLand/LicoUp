import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class HistorySessionHeader extends StatelessWidget {
  const HistorySessionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.showHeaderText,
    required this.searchable,
    required this.searchController,
    required this.searchHint,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.leading,
    required this.trailing,
    required this.collapsible,
    required this.collapsed,
    required this.collapseTooltip,
    required this.expandTooltip,
    required this.onToggleCollapsed,
  });

  final String title;
  final String subtitle;
  final bool showHeaderText;
  final bool searchable;
  final TextEditingController searchController;
  final String searchHint;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final Widget? leading;
  final Widget? trailing;
  final bool collapsible;
  final bool collapsed;
  final String collapseTooltip;
  final String expandTooltip;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final iconOnlyCollapsedHeader = collapsed && !showHeaderText && !searchable;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: iconOnlyCollapsedHeader ? 0 : 8,
      ),
      child: Row(
        children: [
          if (!collapsed && leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ],
          Expanded(
            child: searchable
                ? TextField(
                    controller: searchController,
                    onChanged: onSearchChanged,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: colors.text, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: searchHint,
                      hintStyle: TextStyle(color: colors.textMuted),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: colors.textMuted,
                      ),
                      suffixIcon: searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: strings.clearSearch,
                              onPressed: onClearSearch,
                              icon: const Icon(Icons.close, size: 16),
                            ),
                      filled: true,
                      fillColor: colors.surfaceHigh,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: _border(colors.line),
                      enabledBorder: _border(colors.line),
                      focusedBorder: _border(colors.primary),
                    ),
                  )
                : showHeaderText
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (searchable) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 82),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
          ],
          if (!collapsed && trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
          if (collapsible) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: collapsed ? expandTooltip : collapseTooltip,
              onPressed: onToggleCollapsed,
              color: colors.primary,
              hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
              style: IconButton.styleFrom(
                fixedSize: const Size(32, 32),
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: Icon(
                collapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 18,
              ),
            ),
          ],
        ],
      ),
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: color),
  );
}
