import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/tokens/bubble_desktop_tokens.dart';

final class BubbleDesktopPreviewMetadata {
  const BubbleDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const BubbleDesktopPreviewMetadata bubbleDesktopPreviewMetadata =
    BubbleDesktopPreviewMetadata(
      styleIdentity: 'dense-docked-bubble',
      structuralLandmarks: <String>[
        'context-rail',
        'workspace-bar',
        'edge-editor',
        'inspector-dock',
      ],
    );

Widget buildBubbleDesktopPreview(BuildContext context) =>
    const BubbleDesktopPreview();

/// A deterministic, non-interactive thumbnail of Bubble's structural system.
final class BubbleDesktopPreview extends StatelessWidget {
  const BubbleDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      container: true,
      image: true,
      label: bubbleDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('bubble-desktop-preview'),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(bubbleDesktopTokens.cardRadius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(bubbleDesktopTokens.cardRadius),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: constraints.maxWidth * 0.24,
                    child: _PreviewRail(colors: colors),
                  ),
                  ColoredBox(
                    color: colors.line,
                    child: const SizedBox(width: 1),
                  ),
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

final class _PreviewRail extends StatelessWidget {
  const _PreviewRail({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('bubble-preview-context-rail'),
    color: colors.surfaceLow,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 30;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: unit * 1.2,
            vertical: unit * 1.4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: unit * 2.2,
                    height: unit * 2.2,
                    color: colors.primary,
                  ),
                  SizedBox(width: unit),
                  Expanded(
                    child: Container(height: unit, color: colors.textMuted),
                  ),
                ],
              ),
              SizedBox(height: unit * 2.3),
              for (var index = 0; index < 5; index++) ...[
                _PreviewRailItem(
                  colors: colors,
                  unit: unit,
                  selected: index == 1,
                ),
                SizedBox(height: unit * 0.9),
              ],
            ],
          ),
        );
      },
    ),
  );
}

final class _PreviewRailItem extends StatelessWidget {
  const _PreviewRailItem({
    required this.colors,
    required this.unit,
    required this.selected,
  });

  final LayoutPalette colors;
  final double unit;
  final bool selected;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: selected ? colors.primaryFixed : Colors.transparent,
      border: Border(
        left: BorderSide(
          color: selected ? colors.primary : Colors.transparent,
          width: selected ? 2 : 0,
        ),
      ),
    ),
    child: Padding(
      padding: EdgeInsets.all(unit * 0.65),
      child: Row(
        children: [
          Container(
            width: unit * 1.6,
            height: unit * 1.6,
            color: selected ? colors.primaryStrong : colors.textMuted,
          ),
          SizedBox(width: unit),
          Expanded(
            child: Container(
              height: unit * 0.75,
              color: selected ? colors.text : colors.line,
            ),
          ),
        ],
      ),
    ),
  );
}

final class _PreviewWorkspace extends StatelessWidget {
  const _PreviewWorkspace({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        flex: 2,
        child: DecoratedBox(
          key: const ValueKey<String>('bubble-preview-workspace-bar'),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final unit = constraints.maxHeight / 5;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: unit),
                child: Row(
                  children: [
                    Container(
                      width: unit * 0.7,
                      height: unit * 2.2,
                      color: colors.primary,
                    ),
                    SizedBox(width: unit),
                    Container(
                      width: constraints.maxWidth * 0.24,
                      height: unit,
                      color: colors.text,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
      Expanded(
        flex: 8,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 7, child: _PreviewEditor(colors: colors)),
            ColoredBox(color: colors.line, child: const SizedBox(width: 1)),
            Expanded(flex: 3, child: _PreviewInspector(colors: colors)),
          ],
        ),
      ),
    ],
  );
}

final class _PreviewEditor extends StatelessWidget {
  const _PreviewEditor({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('bubble-preview-edge-editor'),
    color: colors.background,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 22;
        return Padding(
          padding: EdgeInsets.all(unit * 1.6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: constraints.maxWidth * 0.36,
                height: unit * 1.35,
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: 0.55,
                  child: ColoredBox(color: colors.text),
                ),
              ),
              SizedBox(height: unit * 1.8),
              for (var index = 0; index < 4; index++) ...[
                Container(
                  height: unit * 2.15,
                  decoration: BoxDecoration(
                    color: index.isEven ? colors.surfaceLow : colors.surface,
                    border: Border.all(color: colors.line),
                  ),
                ),
                SizedBox(height: unit * 0.8),
              ],
            ],
          ),
        );
      },
    ),
  );
}

final class _PreviewInspector extends StatelessWidget {
  const _PreviewInspector({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('bubble-preview-inspector-dock'),
    color: colors.surfaceLow,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 1.25),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(height: unit, color: colors.textMuted),
              SizedBox(height: unit * 1.5),
              for (var index = 0; index < 3; index++) ...[
                Container(
                  height: unit * 2.5,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.line),
                  ),
                ),
                SizedBox(height: unit),
              ],
            ],
          ),
        );
      },
    ),
  );
}
