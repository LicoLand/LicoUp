import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';

const String classicMobilePreviewSemanticLabel = 'layout.profile.classic.label';

/// Metadata-only preview: the shapes describe the Classic composition but
/// never consume live feature state, user content, or backend data.
Widget buildClassicMobilePreview(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return Semantics(
    key: const ValueKey<String>('classic-mobile-preview'),
    container: true,
    image: true,
    label: classicMobilePreviewSemanticLabel,
    child: ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 10 / 13,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            classicMobileTokens.cardRadius * 0.72,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(classicMobileTokens.spacingUnit * 1.25),
              child: Column(
                children: [
                  _PreviewNavigation(colors: colors),
                  SizedBox(height: classicMobileTokens.spacingUnit * 1.25),
                  Expanded(child: _PreviewCardStack(colors: colors)),
                  SizedBox(height: classicMobileTokens.spacingUnit),
                  _PreviewComposer(colors: colors),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _PreviewNavigation extends StatelessWidget {
  const _PreviewNavigation({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey<String>('classic-mobile-preview-navigation'),
    decoration: BoxDecoration(
      color: colors.primaryContainer,
      borderRadius: BorderRadius.circular(classicMobileTokens.cardRadius),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: classicMobileTokens.spacingUnit * 1.25,
        vertical: classicMobileTokens.spacingUnit,
      ),
      child: Row(
        children: [
          _PreviewDot(color: colors.primary),
          SizedBox(width: classicMobileTokens.spacingUnit),
          Expanded(
            child: _PreviewLine(
              color: colors.onPrimaryContainer.withValues(alpha: 0.62),
              height: 7,
            ),
          ),
          SizedBox(width: classicMobileTokens.spacingUnit * 1.5),
          Icon(
            Icons.expand_more_rounded,
            size: 16,
            color: colors.onPrimaryContainer,
          ),
        ],
      ),
    ),
  );
}

final class _PreviewCardStack extends StatelessWidget {
  const _PreviewCardStack({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey<String>('classic-mobile-preview-card-stack'),
    fit: StackFit.expand,
    children: [
      Positioned(
        left: classicMobileTokens.spacingUnit * 2,
        right: 0,
        top: classicMobileTokens.spacingUnit * 1.5,
        bottom: 0,
        child: _PreviewCard(
          color: colors.secondaryContainer.withValues(alpha: 0.58),
          outline: colors.secondary.withValues(alpha: 0.2),
        ),
      ),
      Positioned(
        left: classicMobileTokens.spacingUnit,
        right: classicMobileTokens.spacingUnit,
        top: classicMobileTokens.spacingUnit * 0.75,
        bottom: classicMobileTokens.spacingUnit * 0.75,
        child: _PreviewCard(
          color: colors.surfaceContainer,
          outline: colors.outlineVariant.withValues(alpha: 0.64),
        ),
      ),
      Positioned.fill(
        right: classicMobileTokens.spacingUnit * 2,
        bottom: classicMobileTokens.spacingUnit * 1.5,
        child: _PreviewCard(
          color: colors.surfaceContainerLowest,
          outline: colors.primary.withValues(alpha: 0.2),
          foreground: colors.onSurfaceVariant,
        ),
      ),
    ],
  );
}

final class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.color,
    required this.outline,
    this.foreground,
  });

  final Color color;
  final Color outline;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final lineColor = foreground?.withValues(alpha: 0.42) ?? outline;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(classicMobileTokens.cardRadius),
        border: Border.all(color: outline),
      ),
      child: Padding(
        padding: EdgeInsets.all(classicMobileTokens.spacingUnit * 1.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PreviewLine(color: lineColor, height: 8, widthFactor: 0.48),
            SizedBox(height: classicMobileTokens.spacingUnit * 1.25),
            _PreviewLine(color: lineColor, height: 6),
            SizedBox(height: classicMobileTokens.spacingUnit * 0.75),
            _PreviewLine(color: lineColor, height: 6, widthFactor: 0.72),
          ],
        ),
      ),
    );
  }
}

final class _PreviewComposer extends StatelessWidget {
  const _PreviewComposer({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey<String>('classic-mobile-preview-composer'),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(classicMobileTokens.cardRadius),
      border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.64)),
    ),
    child: Padding(
      padding: EdgeInsets.all(classicMobileTokens.spacingUnit),
      child: Row(
        children: [
          Expanded(
            child: _PreviewLine(
              color: colors.onSurfaceVariant.withValues(alpha: 0.32),
              height: 7,
            ),
          ),
          SizedBox(width: classicMobileTokens.spacingUnit),
          _PreviewDot(color: colors.primary),
        ],
      ),
    ),
  );
}

final class _PreviewLine extends StatelessWidget {
  const _PreviewLine({
    required this.color,
    required this.height,
    this.widthFactor = 1,
  });

  final Color color;
  final double height;
  final double widthFactor;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: widthFactor,
    alignment: Alignment.centerLeft,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height),
      ),
      child: SizedBox(height: height),
    ),
  );
}

final class _PreviewDot extends StatelessWidget {
  const _PreviewDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: const SizedBox.square(dimension: 12),
  );
}
