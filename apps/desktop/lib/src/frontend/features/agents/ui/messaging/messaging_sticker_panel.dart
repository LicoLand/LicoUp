import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_expression_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// A recently used picker entry: a Lico expression sticker or a plain emoji
/// inserted into the composer draft.
typedef StickerRecentEntry = ({String expressionId, String emoji});

/// Picker presentation order — the same order the demo panel lists the
/// bundled expressions in.
const List<String> stickerExpressionOrder = [
  'happy',
  'celebrate',
  'love',
  'hi',
  'laugh',
  'starstruck',
  'wink',
  'surprised',
  'thinking',
  'confused',
  'focused',
  'speaking',
  'listening',
  'approve',
  'shy',
  'sweat',
  'sorry',
  'sad',
  'pout',
  'sleepy',
  'neutral',
];

/// The plain emoji set the demo panel offers for text insertion.
const List<String> stickerEmojiList = [
  '😀',
  '😄',
  '😂',
  '🤣',
  '😊',
  '😍',
  '🥰',
  '😘',
  '😜',
  '🤔',
  '😅',
  '😭',
  '😴',
  '🙃',
  '😎',
  '🤗',
  '🫡',
  '😤',
  '😢',
  '😡',
  '👍',
  '👎',
  '👏',
  '🙏',
  '💪',
  '🤝',
  '👋',
  '✌️',
  '🫶',
  '❤️',
  '🧡',
  '✨',
  '🎉',
  '🔥',
  '⭐',
  '💯',
  '🍀',
  '🌙',
  '☀️',
  '🧇',
];

/// Wire code written into the outgoing message for one sticker pick.
String stickerWireCode(String expressionId) => '[sticker:lico-$expressionId]';

/// Resolves a wire code back to a bundled expression id, accepting both the
/// namespaced `lico-<id>` form and the bare `<id>` form.
String? stickerExpressionIdFromCode(String code) {
  final match = RegExp(r'^\[sticker:([a-z0-9-]+)\]$').firstMatch(code.trim());
  final raw = match?.group(1);
  if (raw == null) return null;
  final id = raw.startsWith('lico-') ? raw.substring(5) : raw;
  return MascotCatalog.expressions.containsKey(id) ? id : null;
}

/// The composer sticker picker: a glass card listing the Lico expression
/// pack, plain emoji, and recently used entries. Mirrors the demo panel —
/// 372pt wide, five cells per row, tabs along the bottom edge.
class MessagingStickerPanel extends StatefulWidget {
  const MessagingStickerPanel({
    super.key,
    required this.onSendSticker,
    required this.onInsertEmoji,
    this.recent = const [],
  });

  final ValueChanged<String> onSendSticker;
  final ValueChanged<String> onInsertEmoji;
  final List<StickerRecentEntry> recent;

  static const double extent = 372;
  static const double panelHeight = 320;

  @override
  State<MessagingStickerPanel> createState() => _MessagingStickerPanelState();
}

class _MessagingStickerPanelState extends State<MessagingStickerPanel> {
  _StickerTab _tab = _StickerTab.lico;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final chinese = strings.isChinese;
    return MessagingConversationOverlayGlass(
      borderRadius: BorderRadius.circular(LicoRadius.floating),
      readabilityVeil: true,
      veilFill: (colors.isDark
          ? LicoPaneGlass.contentInnerCardFill
          : colors.surfaceLow),
      child: SizedBox(
        width: MessagingStickerPanel.extent,
        height: MessagingStickerPanel.panelHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: switch (_tab) {
                _StickerTab.lico => _StickerGrid(
                  children: [
                    for (final id in stickerExpressionOrder)
                      _ExpressionCell(
                        key: Key('sticker-cell-$id'),
                        expressionId: id,
                        onTap: () => widget.onSendSticker(id),
                      ),
                  ],
                ),
                _StickerTab.emoji => _StickerGrid(
                  children: [
                    for (final emoji in stickerEmojiList)
                      _EmojiCell(
                        key: Key('sticker-emoji-$emoji'),
                        emoji: emoji,
                        onTap: () => widget.onInsertEmoji(emoji),
                      ),
                  ],
                ),
                _StickerTab.recent => _StickerGrid(
                  children: [
                    if (widget.recent.isEmpty)
                      Padding(
                        key: const Key('sticker-recent-empty'),
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: Text(
                            strings.stickerRecentEmpty,
                            style: TextStyle(
                              color: colors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                    else
                      for (final entry in widget.recent)
                        if (entry.expressionId.isNotEmpty)
                          _ExpressionCell(
                            expressionId: entry.expressionId,
                            onTap: () =>
                                widget.onSendSticker(entry.expressionId),
                          )
                        else
                          _EmojiCell(
                            emoji: entry.emoji,
                            onTap: () => widget.onInsertEmoji(entry.emoji),
                          ),
                  ],
                ),
              },
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.line, width: 1)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    _StickerTabButton(
                      active: _tab == _StickerTab.lico,
                      label: 'Lico',
                      leading: MascotImage.expression(
                        'happy',
                        size: 18,
                        semanticLabel: chinese ? '开心' : 'Happy',
                      ),
                      onTap: () => setState(() => _tab = _StickerTab.lico),
                    ),
                    const SizedBox(width: 4),
                    _StickerTabButton(
                      active: _tab == _StickerTab.emoji,
                      label: 'Emoji',
                      leading: Icon(
                        Icons.emoji_emotions_outlined,
                        size: 15,
                        color: _tab == _StickerTab.emoji
                            ? colors.primaryStrong
                            : colors.textMuted,
                      ),
                      onTap: () => setState(() => _tab = _StickerTab.emoji),
                    ),
                    const SizedBox(width: 4),
                    _StickerTabButton(
                      active: _tab == _StickerTab.recent,
                      label: strings.stickerRecent,
                      leading: Icon(
                        Icons.schedule_rounded,
                        size: 15,
                        color: _tab == _StickerTab.recent
                            ? colors.primaryStrong
                            : colors.textMuted,
                      ),
                      onTap: () => setState(() => _tab = _StickerTab.recent),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The composer toolbar button that opens [MessagingStickerPanel] above the
/// input — the ☺ affordance from the demo composer bar.
class MessagingStickerButton extends StatefulWidget {
  const MessagingStickerButton({
    super.key,
    required this.enabled,
    required this.onSendSticker,
    required this.onInsertEmoji,
    this.recent = const [],
  });

  final bool enabled;
  final ValueChanged<String> onSendSticker;
  final ValueChanged<String> onInsertEmoji;
  final List<StickerRecentEntry> recent;

  @override
  State<MessagingStickerButton> createState() => _MessagingStickerButtonState();
}

final class _MessagingStickerButtonState extends State<MessagingStickerButton> {
  final MenuController _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return MenuAnchor(
      controller: _controller,
      style: const MenuStyle(
        alignment: Alignment.topLeft,
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
      alignmentOffset: const Offset(0, -8),
      menuChildren: [
        MessagingStickerPanel(
          key: const Key('messaging-sticker-panel'),
          onSendSticker: (id) {
            widget.onSendSticker(id);
            _controller.close();
          },
          onInsertEmoji: (emoji) {
            widget.onInsertEmoji(emoji);
            _controller.close();
          },
          recent: widget.recent,
        ),
      ],
      child: LicoIconButton(
        size: LicoIconButtonSize.compact,
        key: const Key('agent-conversation-composer-sticker'),
        icon: const Icon(Icons.emoji_emotions_outlined),
        tooltip: strings.stickers,
        onPressed: widget.enabled
            ? () =>
                  _controller.isOpen ? _controller.close() : _controller.open()
            : null,
      ),
    );
  }
}

enum _StickerTab { lico, emoji, recent }

final class _StickerGrid extends StatelessWidget {
  const _StickerGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GridView(
      primary: false,
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      children: children,
    );
  }
}

final class _ExpressionCell extends StatefulWidget {
  const _ExpressionCell({
    super.key,
    required this.expressionId,
    required this.onTap,
  });

  final String expressionId;
  final VoidCallback onTap;

  @override
  State<_ExpressionCell> createState() => _ExpressionCellState();
}

final class _ExpressionCellState extends State<_ExpressionCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final name = MascotCatalog.expressionName(
      widget.expressionId,
      chinese: strings.isChinese,
    );
    return Tooltip(
      message: name,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        label: strings.sendSticker(name),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _hovered ? 1.08 : 1,
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              child: AnimatedContainer(
                duration: context.motion(LicoMotion.micro),
                curve: LicoMotion.standard,
                decoration: BoxDecoration(
                  color: _hovered ? colors.hoverOverlay : Colors.transparent,
                  borderRadius: BorderRadius.circular(LicoRadius.card),
                ),
                child: Center(
                  child: MascotExpressionMotion(
                    expressionId: widget.expressionId,
                    child: MascotImage.expression(
                      widget.expressionId,
                      size: 56,
                      semanticLabel: name,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _EmojiCell extends StatefulWidget {
  const _EmojiCell({super.key, required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiCell> createState() => _EmojiCellState();
}

final class _EmojiCellState extends State<_EmojiCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: widget.emoji,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        label: widget.emoji,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _hovered ? 1.08 : 1,
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              child: AnimatedContainer(
                duration: context.motion(LicoMotion.micro),
                curve: LicoMotion.standard,
                decoration: BoxDecoration(
                  color: _hovered ? colors.hoverOverlay : Colors.transparent,
                  borderRadius: BorderRadius.circular(LicoRadius.card),
                ),
                child: Center(
                  child: Text(
                    widget.emoji,
                    style: const TextStyle(fontSize: 30, height: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _StickerTabButton extends StatelessWidget {
  const _StickerTabButton({
    required this.active,
    required this.label,
    required this.leading,
    required this.onTap,
  });

  final bool active;
  final String label;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: context.motion(LicoMotion.micro),
        curve: LicoMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? colors.selectedSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active
                    ? (colors.isDark ? colors.primaryStrong : colors.text)
                    : colors.textMuted,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
