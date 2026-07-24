import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/tokens/native_desktop_tokens.dart';

final class NativeDesktopPreviewMetadata {
  const NativeDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const NativeDesktopPreviewMetadata nativeDesktopPreviewMetadata =
    NativeDesktopPreviewMetadata(
      styleIdentity: 'glassy-rail-native',
      structuralLandmarks: <String>[
        'nav-rail',
        'content-card',
        'list-layer',
        'detail-layer',
      ],
    );

Widget buildNativeDesktopPreview(BuildContext context) =>
    const NativeDesktopPreview();

/// A deterministic, non-interactive thumbnail of Native's three-layer
/// system: the icon rail and top band resting on the window background,
/// the flush list layer one step above, and the detail layer lightest with
/// its rounded top-leading corner.
final class NativeDesktopPreview extends StatelessWidget {
  const NativeDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final dark = colors.isDark;
    return Semantics(
      container: true,
      image: true,
      label: nativeDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('native-desktop-preview'),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(nativeDesktopTokens.cardRadius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(nativeDesktopTokens.cardRadius),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: constraints.maxWidth * 0.11,
                    child: _PreviewRail(colors: colors),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: constraints.maxHeight * 0.12,
                          child: ColoredBox(
                            key: const ValueKey<String>(
                              'native-preview-content-card',
                            ),
                            color: colors.background,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: constraints.maxWidth * 0.03,
                                ),
                                child: Container(
                                  width: constraints.maxWidth * 0.14,
                                  height: constraints.maxHeight * 0.028,
                                  decoration: BoxDecoration(
                                    color: colors.text.withAlpha(200),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: constraints.maxWidth * 0.27,
                                child: _PreviewListLayer(colors: colors),
                              ),
                              Expanded(
                                child: _PreviewDetailLayer(
                                  colors: colors,
                                  dark: dark,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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

final class _PreviewRail extends StatelessWidget {
  const _PreviewRail({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('native-preview-nav-rail'),
    color: colors.background,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 24;
        return Padding(
          padding: EdgeInsets.only(top: unit * 3.2),
          child: Column(
            children: [
              for (var index = 0; index < 4; index++) ...[
                _PreviewRailTile(
                  colors: colors,
                  unit: unit,
                  selected: index == 0,
                ),
                SizedBox(height: unit * 0.8),
              ],
              const Spacer(),
              _PreviewRailTile(colors: colors, unit: unit, selected: false),
              SizedBox(height: unit * 1.4),
            ],
          ),
        );
      },
    ),
  );
}

final class _PreviewRailTile extends StatelessWidget {
  const _PreviewRailTile({
    required this.colors,
    required this.unit,
    required this.selected,
  });

  final LayoutPalette colors;
  final double unit;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
    width: unit * 2.6,
    height: unit * 2.6,
    decoration: BoxDecoration(
      color: selected
          ? colors.surfaceHigh.withAlpha(colors.isDark ? 200 : 255)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(unit * 0.8),
    ),
    child: Center(
      child: Container(
        width: unit * 1.1,
        height: unit * 1.1,
        decoration: BoxDecoration(
          color: selected ? colors.primary : colors.textMuted,
          borderRadius: BorderRadius.circular(unit * 0.3),
        ),
      ),
    ),
  );
}

final class _PreviewListLayer extends StatelessWidget {
  const _PreviewListLayer({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('native-preview-list-layer'),
    color: colors.isDark ? colors.surface : colors.surfaceLow,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 0.9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < 6; index++) ...[
                Container(
                  height: unit * 0.85,
                  decoration: BoxDecoration(
                    color: index == 1 ? colors.primaryFixed : colors.line,
                    borderRadius: BorderRadius.circular(unit * 0.35),
                  ),
                ),
                SizedBox(height: unit * 0.7),
              ],
            ],
          ),
        );
      },
    ),
  );
}

final class _PreviewDetailLayer extends StatelessWidget {
  const _PreviewDetailLayer({required this.colors, required this.dark});

  final LayoutPalette colors;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey<String>('native-preview-detail-layer'),
    decoration: BoxDecoration(
      color: dark ? colors.surfaceLow : colors.surface,
      borderRadius: const BorderRadius.only(topLeft: Radius.circular(14)),
      border: Border(
        left: BorderSide(color: colors.line.withAlpha(80), width: 0.5),
        top: BorderSide(color: colors.line.withAlpha(80), width: 0.5),
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 1.1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: unit * 6,
                height: unit * 1.1,
                color: colors.text,
              ),
              SizedBox(height: unit * 1.3),
              for (var index = 0; index < 4; index++) ...[
                Align(
                  alignment: index.isEven
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: Container(
                    width: index.isEven ? unit * 10 : unit * 8,
                    height: unit * 1.9,
                    decoration: BoxDecoration(
                      color: index.isEven
                          ? colors.line.withAlpha(160)
                          : colors.primaryFixed,
                      borderRadius: BorderRadius.circular(unit * 0.7),
                    ),
                  ),
                ),
                SizedBox(height: unit * 0.75),
              ],
            ],
          ),
        );
      },
    ),
  );
}
