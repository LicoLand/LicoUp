import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

/// Classic-owned status chrome driven only by the neutral shell port.
final class ClassicDesktopStatusBar extends StatelessWidget {
  const ClassicDesktopStatusBar({super.key, required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LayoutChromeSnapshot>(
      valueListenable: chrome,
      builder: (context, snapshot, _) {
        final statusText = snapshot.status.displayText;
        if (statusText.isEmpty) {
          return const SizedBox.shrink();
        }
        final palette = context.layoutPalette;
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: palette.background,
            border: Border(top: BorderSide(color: palette.line.withAlpha(50))),
          ),
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.success.withAlpha(180),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutQuart,
                  switchOutCurve: Curves.easeInQuart,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.centerLeft,
                    children: <Widget>[...previousChildren, ?currentChild],
                  ),
                  transitionBuilder: (child, animation) {
                    final offset = Tween<Offset>(
                      begin: const Offset(0, 0.6),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: offset, child: child),
                    );
                  },
                  child: Text(
                    statusText,
                    key: ValueKey<String>('shell-status-text:$statusText'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
