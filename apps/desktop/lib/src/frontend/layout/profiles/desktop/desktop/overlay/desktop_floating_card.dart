import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// The generic floating card chrome for Desktop feature apps: a pure black
/// panel with a draggable header (icon, label, close button). Cards float
/// one Z-level above the main area; tapping anywhere raises the card.
/// Feature panels mount unchanged as the card body — this chrome never
/// touches feature code.
final class DesktopFloatingCard extends StatelessWidget {
  const DesktopFloatingCard({
    super.key,
    required this.app,
    required this.rect,
    required this.onClose,
    required this.onRaise,
    required this.onMove,
    required this.child,
  });

  final DesktopAppId app;
  final Rect rect;
  final VoidCallback onClose;
  final VoidCallback onRaise;
  final ValueChanged<Offset> onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = desktopAppLabel(strings, app);
    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        container: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRaise,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              DesktopDesktopMetrics.floatingCardRadius,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: desktopDesktopSurfaceBlack,
                borderRadius: BorderRadius.circular(
                  DesktopDesktopMetrics.floatingCardRadius,
                ),
                border: Border.all(
                  color: DesktopDesktopOnBlack.line,
                  width: 0.5,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x73000000),
                    blurRadius: 30,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) => onMove(details.delta),
                    child: SizedBox(
                      key: Key('desktop-floating-card-header-${app.name}'),
                      height: DesktopDesktopMetrics.floatingCardHeaderExtent,
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          Icon(
                            desktopAppIcon(app),
                            size: 16,
                            color: DesktopDesktopOnBlack.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: DesktopDesktopOnBlack.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          _DesktopFloatingCardCloseButton(
                            key: Key('desktop-floating-card-close-${app.name}'),
                            tooltip: DesktopDesktopCopy.closeAppTooltip(
                              strings,
                            ),
                            onPressed: onClose,
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(
                          DesktopDesktopMetrics.floatingCardRadius,
                        ),
                        bottomRight: Radius.circular(
                          DesktopDesktopMetrics.floatingCardRadius,
                        ),
                      ),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DesktopFloatingCardCloseButton extends StatefulWidget {
  const _DesktopFloatingCardCloseButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_DesktopFloatingCardCloseButton> createState() =>
      _DesktopFloatingCardCloseButtonState();
}

final class _DesktopFloatingCardCloseButtonState
    extends State<_DesktopFloatingCardCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: context.motion(LicoMotion.micro),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hovered
                  ? DesktopDesktopOnBlack.hoverOverlay
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 15,
              color: _hovered
                  ? DesktopDesktopOnBlack.text
                  : DesktopDesktopOnBlack.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
