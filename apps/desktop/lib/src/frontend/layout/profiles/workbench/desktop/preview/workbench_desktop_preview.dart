import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

Widget buildWorkbenchDesktopPreview(BuildContext context) =>
    const WorkbenchDesktopPreview();

/// A deterministic, non-interactive thumbnail of the workbench composition.
final class WorkbenchDesktopPreview extends StatelessWidget {
  const WorkbenchDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = LicoStrings.of(context);
    final label = strings.isChinese ? '工作台桌面布局预览' : 'Workbench desktop preview';

    return Semantics(
      key: const ValueKey<String>('workbench-desktop-preview'),
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
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  _PreviewCommandBar(colors: colors),
                  const SizedBox(height: 8),
                  _PreviewNavigation(colors: colors),
                  const SizedBox(height: 8),
                  Expanded(child: _PreviewWorkspace(colors: colors)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _PreviewCommandBar extends StatelessWidget {
  const _PreviewCommandBar({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: colors.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(7),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(7),
            ),
            child: SizedBox.square(
              dimension: 17,
              child: Icon(
                Icons.space_dashboard_rounded,
                size: 11,
                color: colors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Container(
              height: 15,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(7),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Container(
            width: 34,
            height: 15,
            decoration: BoxDecoration(
              color: colors.secondaryContainer,
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ],
      ),
    ),
  );
}

final class _PreviewNavigation extends StatelessWidget {
  const _PreviewNavigation({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 16,
    child: Row(
      children: [
        for (var index = 0; index < 5; index++) ...[
          if (index > 0) const SizedBox(width: 5),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: index == 0
                    ? colors.primaryContainer
                    : colors.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: index == 0
                      ? colors.primary.withValues(alpha: 0.34)
                      : colors.outlineVariant,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

final class _PreviewWorkspace extends StatelessWidget {
  const _PreviewWorkspace({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: colors.outlineVariant),
      boxShadow: [
        BoxShadow(
          color: colors.shadow.withValues(alpha: 0.1),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.all(9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: _PreviewCard(color: colors.surfaceContainerHighest),
          ),
          const SizedBox(width: 7),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(child: _PreviewCard(color: colors.tertiaryContainer)),
                const SizedBox(height: 7),
                Expanded(child: _PreviewCard(color: colors.secondaryContainer)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

final class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(9),
    ),
  );
}
