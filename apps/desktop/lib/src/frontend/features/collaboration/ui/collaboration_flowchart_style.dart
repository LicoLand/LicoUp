import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Inks whose role differs between the light and dark presets.
///
/// The light preset's brand is a saturated violet that reads as ink; the dark
/// preset's brand is gold, which reads as ink only in its strong step and
/// leaves the violet accent to carry labels.
final class CollaborationInk {
  const CollaborationInk(this.colors);

  final LicoThemeColors colors;

  /// Running work, active edges, links and the minimap's active node.
  Color get brand => colors.isDark ? colors.primaryStrong : colors.primary;

  /// Role labels above a card title.
  Color get role => colors.isDark ? colors.accentStrong : colors.primary;

  /// Accent text: receipts, change tags, revision chip.
  Color get accent => colors.isDark ? colors.accentStrong : colors.accent;

  /// A decision waiting on the user.
  Color get gate => colors.isDark ? colors.warning : colors.accent;

  Color dot(CollaborationNodeStatus status) => switch (status) {
    CollaborationNodeStatus.running ||
    CollaborationNodeStatus.retrying => brand,
    CollaborationNodeStatus.waitingUser => gate,
    CollaborationNodeStatus.waitingAssistant => colors.warning,
    CollaborationNodeStatus.succeeded => colors.success,
    CollaborationNodeStatus.failed => colors.error,
    CollaborationNodeStatus.pending ||
    CollaborationNodeStatus.cancelled ||
    CollaborationNodeStatus.heldForPlan => colors.textDisabled,
  };

  Color statusText(CollaborationNodeStatus status) => switch (status) {
    CollaborationNodeStatus.waitingUser => gate,
    CollaborationNodeStatus.succeeded => colors.textMuted,
    CollaborationNodeStatus.failed => colors.error,
    CollaborationNodeStatus.pending ||
    CollaborationNodeStatus.cancelled => colors.textDisabled,
    CollaborationNodeStatus.heldForPlan => accent,
    _ => colors.textSecondary,
  };

  Color note(CollaborationNoteTone tone) => switch (tone) {
    CollaborationNoteTone.muted => colors.textMuted,
    CollaborationNoteTone.warning => colors.warning,
    CollaborationNoteTone.receipt => accent,
  };
}

/// Card geometry and text roles shared by measurement and rendering.
///
/// Every card row renders inside a box of the height measured here, so the
/// layout's card sizes and the rendered cards agree by construction.
final class CollaborationCardMetrics {
  CollaborationCardMetrics({
    required TextTheme textTheme,
    required this.textScaler,
  }) : title = textTheme.titleSmall!,
       status = textTheme.labelMedium!,
       small = textTheme.labelSmall!,
       role = LicoTypography.eyebrow(color: const Color(0x00000000));

  factory CollaborationCardMetrics.of(BuildContext context) =>
      CollaborationCardMetrics(
        textTheme: Theme.of(context).textTheme,
        textScaler: MediaQuery.textScalerOf(context),
      );

  final TextScaler textScaler;

  /// Task title.
  final TextStyle title;

  /// Status row, stack head and step title.
  final TextStyle status;

  /// Chips, tags, notes, actions and step subtitles.
  final TextStyle small;

  /// Uppercase role label; callers supply the color.
  final TextStyle role;

  static const double taskWidth = 216;
  static const double stackWidth = 228;
  static const Size connectorSize = Size(76, 34);
  static const Size terminalSize = Size(52, 52);
  static const double border = 1.5;
  static const double radius = LicoRadius.card;
  static const double padX = 12;
  static const double padY = 10;
  static const double avatar = 30;
  static const double taskMinHeight = 104;
  static const double rowGap = 6;

  /// Space above a note's dashed rule, and between the rule and its text.
  static const double noteGap = 7;
  static const double noteInset = 6;
  static const double stackHeadPadY = 9;
  static const double stackHeadIcon = 14;
  static const double stepPadY = 8;
  static const double stepIcon = 18;
  static const double pillPadX = 8;
  static const double pillPadY = 2;
  static const double lockGap = 3;

  final Map<TextStyle, double> _lines = {};

  /// Width available to a note's text inside a task card.
  static double get noteWidth => taskWidth - border * 2 - padX * 2;

  double lineHeight(TextStyle style) => _lines.putIfAbsent(style, () {
    final painter = TextPainter(
      text: TextSpan(text: 'Hg国', style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  });

  /// Height of a one-line pill with a hairline rim.
  double pillHeight(TextStyle style) => lineHeight(style) + pillPadY * 2 + 2;

  double noteHeight(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: small),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: noteWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  double get topRowHeight =>
      math.max(avatar, math.max(lineHeight(role), pillHeight(small)));

  double get statusRowHeight =>
      math.max(lineHeight(status), lineHeight(small) + pillPadY * 2);

  double get stackHeadHeight =>
      stackHeadPadY * 2 + math.max(lineHeight(status), stackHeadIcon);

  Size sizeOf(CollaborationCardModel model) => switch (model) {
    CollaborationTaskCardModel() => Size(taskWidth, taskHeight(model)),
    CollaborationStackCardModel() => Size(stackWidth, stackHeight(model)),
    CollaborationConnectorModel() => connectorSize,
    CollaborationTerminalModel() => terminalSize,
  };

  bool hasStatusRow(CollaborationTaskCardModel model) =>
      model.statusLabel.isNotEmpty || model.actionLabel != null;

  double taskHeight(CollaborationTaskCardModel model) {
    var height = border + padY + topRowHeight + rowGap + lineHeight(title);
    if (hasStatusRow(model)) height += rowGap + statusRowHeight;
    if (model.approvedReason != null) height += rowGap + pillHeight(small);
    for (final note in model.notes) {
      height += noteGap + 1 + noteInset + noteHeight(note.text);
    }
    height += padY + border;
    return math.max(height, taskMinHeight);
  }

  double stepContentHeight(CollaborationStepModel step) {
    var height = lineHeight(status) + lineHeight(small);
    if (step.tag != null) height += 4 + pillHeight(small);
    if (step.locked) height += lockGap + lineHeight(small);
    return math.max(height, stepIcon);
  }

  double stepHeight(CollaborationStepModel step) =>
      stepPadY * 2 + stepContentHeight(step);

  double stackHeight(CollaborationStackCardModel model) {
    var height = border + stackHeadHeight + 1;
    for (var i = 0; i < model.steps.length; i++) {
      height += stepHeight(model.steps[i]);
      if (i < model.steps.length - 1) height += 1;
    }
    return height + border;
  }
}
