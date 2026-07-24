import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Neutral 32×32 conversation-surface action used by independent pane leaves
/// and adjacent policy controls without creating leaf-to-leaf dependencies.
class ConversationIconButton extends StatefulWidget {
  const ConversationIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.child,
    this.color,
    this.busy = false,
  }) : assert(
         icon != null || child != null,
         'conversation_icon_button_content_missing',
       );

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? child;
  final Color? color;
  final bool busy;

  @override
  State<ConversationIconButton> createState() => _ConversationIconButtonState();
}

class _ConversationIconButtonState extends State<ConversationIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = widget.onPressed != null && !widget.busy;
    final iconColor = !enabled
        ? colors.textMuted.withAlpha(120)
        : widget.color ??
              (_hovered ? colors.text : colors.textMuted.withAlpha(230));
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered && enabled
                  ? (colors.isDark
                        ? Colors.white.withAlpha(12)
                        : Colors.black.withAlpha(12))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.busy
                ? SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textMuted,
                    ),
                  )
                : widget.child ??
                      IconTheme(
                        data: IconThemeData(color: iconColor, size: 17),
                        child: Icon(widget.icon),
                      ),
          ),
        ),
      ),
    );
  }
}

class MobileComposerSurface extends StatelessWidget {
  const MobileComposerSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: child,
    );
  }
}
