import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/presentation/classic_chrome_allowance_presentation.dart';

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
        if (statusText.isEmpty && snapshot.allowance == null) {
          return const SizedBox.shrink();
        }
        final palette = context.layoutPalette;
        final allowance = presentLayoutChromeAllowance(
          snapshot.allowance,
          LicoStrings.of(context),
        );
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
              if (allowance != null) ...[
                const SizedBox(width: 12),
                Tooltip(
                  message: allowance.tooltip,
                  child: _ClassicAllowanceMeterGroup(
                    presentation: allowance,
                    palette: palette,
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

final class _ClassicAllowanceMeterGroup extends StatelessWidget {
  const _ClassicAllowanceMeterGroup({
    required this.presentation,
    required this.palette,
  });

  final LayoutChromeAllowancePresentation presentation;
  final LayoutPalette palette;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < presentation.meters.length; index++) ...[
        if (index > 0) const SizedBox(width: 10),
        _ClassicAllowanceMeter(
          key: Key(
            'agent-allowance-meter-${presentation.meters[index].semanticId}',
          ),
          meter: presentation.meters[index],
          palette: palette,
        ),
      ],
    ],
  );
}

final class _ClassicAllowanceMeter extends StatelessWidget {
  const _ClassicAllowanceMeter({
    super.key,
    required this.meter,
    required this.palette,
  });

  final LayoutChromeAllowanceMeterPresentation meter;
  final LayoutPalette palette;

  @override
  Widget build(BuildContext context) {
    final progress = meter.progress?.clamp(0.0, 1.0);
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
              color: palette.textMuted,
              fontWeight: FontWeight.w800,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 6),
          if (meter.showProgress) ...[
            SizedBox(
              width: 54,
              child: SizedBox(
                key: Key('agent-allowance-progress-track-${meter.label}'),
                height: 7,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.surfaceHigh,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    if ((progress ?? 0) > 0)
                      FractionallySizedBox(
                        widthFactor: progress,
                        alignment: Alignment.centerLeft,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _toneColor(meter.progressTone, palette),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                  ],
                ),
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
              color: meter.status.trim().toLowerCase() == 'unavailable'
                  ? palette.textMuted
                  : _toneColor(meter.valueTone, palette),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

Color _toneColor(LayoutChromeStatusTone tone, LayoutPalette palette) =>
    switch (tone) {
      LayoutChromeStatusTone.neutral => palette.text,
      LayoutChromeStatusTone.primaryMuted => palette.primary.withAlpha(120),
      LayoutChromeStatusTone.info => palette.info,
      LayoutChromeStatusTone.success => palette.success,
      LayoutChromeStatusTone.warning => palette.warning,
      LayoutChromeStatusTone.error => palette.error,
    };
