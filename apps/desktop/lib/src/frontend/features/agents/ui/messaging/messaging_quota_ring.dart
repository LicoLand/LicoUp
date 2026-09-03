import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Provider-quota progress ring painted around one roster avatar, inside the
/// existing [MessagingDesktopMetrics.groupRosterMemberExtent]. The arc sweep
/// is the snapshot's most constrained window clamped to 0–100; stale
/// snapshots paint the same arc dimmed. Callers omit this widget entirely
/// when the agent has no quota snapshot — there is no track and no
/// placeholder.
class MessagingQuotaRing extends StatelessWidget {
  const MessagingQuotaRing({
    super.key,
    required this.snapshot,
    required this.child,
  });

  final ProviderQuotaSnapshot snapshot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    const band =
        MessagingDesktopMetrics.groupRosterQuotaRingThickness +
        MessagingDesktopMetrics.groupRosterQuotaRingInset;
    final color = snapshot.isStale
        ? colors.accent.withAlpha(
            MessagingDesktopMetrics.groupRosterQuotaRingStaleAlpha,
          )
        : colors.accent;
    return CustomPaint(
      painter: MessagingQuotaRingPainter(
        progress: snapshot.ringUsedPercent / 100,
        color: color,
        thickness: MessagingDesktopMetrics.groupRosterQuotaRingThickness,
        inset: MessagingDesktopMetrics.groupRosterQuotaRingInset,
      ),
      child: Padding(padding: const EdgeInsets.all(band), child: child),
    );
  }
}

/// Paints the quota arc from twelve o'clock, clockwise. No track circle: the
/// ring is the only added chrome inside the member extent.
final class MessagingQuotaRingPainter extends CustomPainter {
  const MessagingQuotaRingPainter({
    required this.progress,
    required this.color,
    required this.thickness,
    required this.inset,
  });

  /// Arc fill fraction, clamped to 0..1 by the painter.
  final double progress;
  final Color color;
  final double thickness;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final sweep = progress.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    final arcRect = (Offset.zero & size).deflate(inset + thickness / 2);
    canvas.drawArc(
      arcRect,
      -math.pi / 2,
      sweep * 2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant MessagingQuotaRingPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        color != oldDelegate.color ||
        thickness != oldDelegate.thickness ||
        inset != oldDelegate.inset;
  }
}
