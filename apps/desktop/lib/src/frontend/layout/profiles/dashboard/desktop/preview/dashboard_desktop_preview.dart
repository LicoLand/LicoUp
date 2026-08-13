import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

Widget buildDashboardDesktopPreview(BuildContext context) =>
    const DashboardDesktopPreview();

/// A deterministic, non-interactive thumbnail of the Dashboard composition:
/// the macOS-Notes flush three panes — folder sidebar, list, and editor —
/// with the selected folder in solid brand yellow.
final class DashboardDesktopPreview extends StatelessWidget {
  const DashboardDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = LicoStrings.of(context);
    final label = strings.isChinese
        ? 'Dashboard 桌面布局预览'
        : 'Dashboard desktop preview';

    return Semantics(
      key: const ValueKey<String>('dashboard-desktop-preview'),
      image: true,
      label: label,
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: 16 / 10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PreviewFolderSidebar(colors: colors),
                  _PreviewHairline(colors: colors),
                  Expanded(flex: 3, child: _PreviewListPane(colors: colors)),
                  _PreviewHairline(colors: colors),
                  Expanded(flex: 5, child: _PreviewEditorPane(colors: colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _PreviewHairline extends StatelessWidget {
  const _PreviewHairline({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: colors.outlineVariant);
}

final class _PreviewFolderSidebar extends StatelessWidget {
  const _PreviewFolderSidebar({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Expanded(
    flex: 2,
    child: ColoredBox(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 9,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            for (var index = 0; index < 5; index++) ...[
              if (index > 0) const SizedBox(height: 5),
              Container(
                height: 15,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: index == 0 ? colors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: index == 0
                            ? colors.onPrimary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: index == 0
                              ? colors.onPrimary
                              : colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

final class _PreviewListPane extends StatelessWidget {
  const _PreviewListPane({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: colors.surfaceContainerLowest,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < 6; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            Container(
              height: 7,
              margin: EdgeInsets.only(right: index.isEven ? 22 : 6),
              decoration: BoxDecoration(
                color: index == 0
                    ? colors.surfaceContainerHighest
                    : colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

final class _PreviewEditorPane extends StatelessWidget {
  const _PreviewEditorPane({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: colors.surfaceContainerLowest,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 11,
            margin: const EdgeInsets.only(right: 90),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < 5; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            Container(
              height: 7,
              margin: EdgeInsets.only(
                right: [40.0, 12.0, 64.0, 24.0, 96.0][index],
              ),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
