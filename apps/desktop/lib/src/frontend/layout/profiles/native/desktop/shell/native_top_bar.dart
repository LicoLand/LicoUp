import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_glass.dart';

/// The shell's top band: a transparent strip resting on the same lowest
/// layer as the icon rail and the window background. A browser-style search
/// capsule sits dead center and opens the global search palette — no
/// divider, no title-bar chrome.
final class NativeTopBar extends StatelessWidget {
  const NativeTopBar({super.key, required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return SizedBox(
      height: NativeDesktopChromeMetrics.topBarHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final capsuleWidth = (constraints.maxWidth * 0.42).clamp(
            280.0,
            460.0,
          );
          return Center(
            child: SizedBox(
              key: const Key('native-topbar-search'),
              width: capsuleWidth.toDouble(),
              height: NativeDesktopChromeMetrics.searchFieldHeight,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(
                    NativeDesktopChromeMetrics.searchFieldCornerRadius,
                  ),
                  onTap: () => chrome.openGlobalSearch(context),
                  child: DecoratedBox(
                    decoration: NativeGlass.capsule(colors),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_rounded,
                          size: 13,
                          color: colors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          strings.sidebarSearchHint,
                          style: TextStyle(
                            color: colors.textMuted.withAlpha(190),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w400,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
