import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_message.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_image_attachments.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentConversationMessageContent extends StatelessWidget {
  const AgentConversationMessageContent({
    super.key,
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
    this.images = const [],
    this.isStreaming = false,
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  /// Whether the body is a partially written streamed reply. Streamed bodies
  /// render complete Markdown blocks with final styling and the still-growing
  /// tail in a quiet in-progress presentation; the default keeps the exact
  /// finalized rendering. Callers that cannot know the live state leave this
  /// false.
  final bool isStreaming;

  /// Typed image attachments rendered below the message body (local-only).
  final List<AgentConversationImageAttachment> images;

  @override
  Widget build(BuildContext context) {
    final display = splitMessageDisplayBlocks(data);
    final hasBody = display.body.trim().isNotEmpty;
    final hasDetails = display.metadataBlocks.isNotEmpty;
    final hasRecommendedPlugins = display.recommendedPluginsBlocks.isNotEmpty;
    final hasImages = images.isNotEmpty;
    if (!hasBody && !hasDetails && !hasRecommendedPlugins && !hasImages) {
      return MessageMarkdown(
        data: '',
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasBody)
          MessageMarkdown(
            data: display.body,
            foreground: foreground,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
            isStreaming: isStreaming,
          ),
        if (hasRecommendedPlugins) ...[
          if (hasBody) SizedBox(height: renderStyle.blockSpacing),
          _RecommendedPluginsDisclosure(
            blocks: display.recommendedPluginsBlocks,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            renderStyle: renderStyle,
          ),
        ],
        if (hasDetails) ...[
          if (hasBody || hasRecommendedPlugins)
            SizedBox(height: renderStyle.blockSpacing),
          _MessageDetailsDisclosure(
            details: display.metadataBlocks.join('\n\n'),
            detailsCount: display.metadataBlocks.length,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            renderStyle: renderStyle,
          ),
        ],
        if (hasImages) ...[
          if (hasBody || hasRecommendedPlugins || hasDetails)
            SizedBox(height: renderStyle.blockSpacing),
          AgentConversationImageAttachmentList(images: images),
        ],
      ],
    );
  }
}

Widget buildAgentConversationEventDetails({
  required String data,
  required Color foreground,
  required Color accent,
  required Color codeBackground,
  required Color blockBackground,
  required Color borderColor,
  required MessageMarkdownStyle renderStyle,
}) {
  return AgentConversationMessageContent(
    data: data,
    foreground: foreground,
    accent: accent,
    codeBackground: codeBackground,
    blockBackground: blockBackground,
    borderColor: borderColor,
    renderStyle: renderStyle,
  );
}

Color agentConversationMessageForeground(LicoThemeColors colors, String role) {
  final normalized = role.toLowerCase();
  if (normalized == 'metadata' || normalized == 'system') {
    return colors.textMuted;
  }
  return colors.text;
}

Color agentConversationToneColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'raised' => colors.surfaceRaised,
    'surface' => colors.surface,
    'muted' => colors.surfaceLow,
    _ => colors.surfaceLow,
  };
}

class _MessageDetailsDisclosure extends StatefulWidget {
  const _MessageDetailsDisclosure({
    required this.details,
    required this.detailsCount,
    required this.codeBackground,
    required this.blockBackground,
    required this.renderStyle,
  });

  final String details;
  final int detailsCount;
  final Color codeBackground;
  final Color blockBackground;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_MessageDetailsDisclosure> createState() =>
      _MessageDetailsDisclosureState();
}

class _MessageDetailsDisclosureState extends State<_MessageDetailsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final title = LicoStrings.of(context).details;
    final countSuffix = widget.detailsCount > 1
        ? ' · ${widget.detailsCount}'
        : '';
    return _DisclosureSurface(
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      title: '$title$countSuffix',
      child: MessageMarkdown(
        data: widget.details,
        foreground: colors.textMuted,
        accent: colors.accent,
        codeBackground: widget.codeBackground,
        blockBackground: widget.blockBackground,
        borderColor: Colors.white.withAlpha(colors.isDark ? 36 : 56),
        renderStyle: widget.renderStyle,
      ),
    );
  }
}

class _RecommendedPluginsDisclosure extends StatefulWidget {
  const _RecommendedPluginsDisclosure({
    required this.blocks,
    required this.codeBackground,
    required this.blockBackground,
    required this.renderStyle,
  });

  final List<String> blocks;
  final Color codeBackground;
  final Color blockBackground;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_RecommendedPluginsDisclosure> createState() =>
      _RecommendedPluginsDisclosureState();
}

class _RecommendedPluginsDisclosureState
    extends State<_RecommendedPluginsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final title = LicoStrings.of(context).recommendedPlugins;
    final pluginCount = recommendedPluginsCount(widget.blocks);
    final countSuffix = pluginCount > 0 ? ' · $pluginCount' : '';
    return _DisclosureSurface(
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      title: '$title$countSuffix',
      leading: Icon(
        Icons.extension_outlined,
        size: 13,
        color: colors.textMuted,
      ),
      child: MessageMarkdown(
        data: widget.blocks.join('\n\n'),
        foreground: colors.text,
        accent: colors.accent,
        codeBackground: widget.codeBackground,
        blockBackground: widget.blockBackground,
        borderColor: Colors.white.withAlpha(colors.isDark ? 36 : 56),
        renderStyle: widget.renderStyle,
      ),
    );
  }
}

class _DisclosureSurface extends StatelessWidget {
  const _DisclosureSurface({
    required this.expanded,
    required this.onToggle,
    required this.title,
    required this.child,
    this.leading,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final String title;
  final Widget child;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(colors.isDark ? 12 : 16),
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        border: Border.all(
          color: Colors.white.withAlpha(colors.isDark ? 36 : 56),
          width: AppleControlMetrics.hairline,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.controlCornerRadius,
            ),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  if (leading != null) ...[leading!, const SizedBox(width: 6)],
                  Flexible(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.04,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(
              height: 1,
              color: Colors.white.withAlpha(colors.isDark ? 28 : 48),
            ),
            Padding(padding: const EdgeInsets.all(10), child: child),
          ],
        ],
      ),
    );
  }
}
