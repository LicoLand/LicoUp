import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/presentation/studio_chrome_allowance_presentation.dart';

final class StudioStatusBar extends StatelessWidget {
  const StudioStatusBar({
    super.key,
    required this.chrome,
    this.backgroundColor,
    this.showTopBorder = true,
  });

  final LayoutChromePort chrome;
  final Color? backgroundColor;
  final bool showTopBorder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LayoutChromeSnapshot>(
      valueListenable: chrome,
      builder: (context, snapshot, _) {
        final statusText = snapshot.status.displayText;
        if (statusText.isEmpty && snapshot.allowance == null) {
          return const SizedBox.shrink();
        }
        final colors = context.layoutPalette;
        final allowance = presentLayoutChromeAllowance(
          snapshot.allowance,
          LicoStrings.of(context),
        );
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: backgroundColor ?? colors.background,
            border: showTopBorder
                ? Border(top: BorderSide(color: colors.line.withAlpha(50)))
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.success.withAlpha(180),
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
                    key: ValueKey('shell-status-text:$statusText'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (allowance != null) ...[
                const SizedBox(width: 12),
                Tooltip(
                  message: allowance.tooltip,
                  child: _StudioAllowanceMeterGroup(
                    allowance: allowance,
                    colors: colors,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

final class _StudioAllowanceMeterGroup extends StatelessWidget {
  const _StudioAllowanceMeterGroup({
    required this.allowance,
    required this.colors,
  });

  final LayoutChromeAllowancePresentation allowance;
  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < allowance.meters.length; index++) ...[
          if (index > 0) const SizedBox(width: 10),
          _StudioAllowanceMeter(
            key: Key(
              'agent-allowance-meter-${allowance.meters[index].semanticId}',
            ),
            meter: allowance.meters[index],
            colors: colors,
          ),
        ],
      ],
    );
  }
}

final class _StudioAllowanceMeter extends StatelessWidget {
  const _StudioAllowanceMeter({
    super.key,
    required this.meter,
    required this.colors,
  });

  final LayoutChromeAllowanceMeterPresentation meter;
  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) {
    final normalizedProgress = meter.progress?.clamp(0.0, 1.0);
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            meter.label,
            maxLines: 1,
            style: TextStyle(
              color: colors.textMuted,
              fontWeight: FontWeight.w800,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 6),
          if (meter.showProgress) ...[
            SizedBox(
              width: 54,
              child: _StudioAllowanceProgressTrack(
                key: Key('agent-allowance-progress-track-${meter.label}'),
                progress: normalizedProgress,
                fillColor: _toneColor(
                  meter.progressTone,
                  colors,
                  mutedPrimary: true,
                ),
                colors: colors,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            meter.valueText,
            key: Key('agent-allowance-meter-value-${meter.label}'),
            maxLines: 1,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: _valueColor(meter, colors),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

final class _StudioAllowanceProgressTrack extends StatelessWidget {
  const _StudioAllowanceProgressTrack({
    super.key,
    required this.progress,
    required this.fillColor,
    required this.colors,
  });

  final double? progress;
  final Color fillColor;
  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) {
    final normalizedProgress = progress?.clamp(0.0, 1.0) ?? 0;
    return SizedBox(
      height: 7,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceHigh,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          if (normalizedProgress > 0)
            FractionallySizedBox(
              widthFactor: normalizedProgress,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Color _valueColor(
  LayoutChromeAllowanceMeterPresentation meter,
  LayoutPalette colors,
) => switch (meter.status.trim().toLowerCase()) {
  'exhausted' => colors.error,
  'not-configured' => colors.warning,
  'unavailable' => colors.textMuted,
  _ => _toneColor(meter.valueTone, colors),
};

Color _toneColor(
  LayoutChromeStatusTone tone,
  LayoutPalette colors, {
  bool mutedPrimary = false,
}) => switch (tone) {
  LayoutChromeStatusTone.neutral => colors.text,
  LayoutChromeStatusTone.primaryMuted =>
    mutedPrimary ? colors.primary.withAlpha(120) : colors.primary,
  LayoutChromeStatusTone.info => colors.info,
  LayoutChromeStatusTone.success => colors.success,
  LayoutChromeStatusTone.warning => colors.warning,
  LayoutChromeStatusTone.error => colors.error,
};
