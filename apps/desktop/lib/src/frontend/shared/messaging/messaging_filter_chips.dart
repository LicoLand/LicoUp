import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_list_typography.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';

/// One choice in a [MessagingFilterChips] row.
final class MessagingFilterChipOption<T> {
  const MessagingFilterChipOption({
    required this.value,
    required this.label,
    required this.key,
  });

  final T value;
  final String label;
  final Key key;
}

/// A row of stadium chips that narrows the list below it. Exactly one chip
/// is selected; the selection belongs to the caller.
final class MessagingFilterChips<T> extends StatelessWidget {
  const MessagingFilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.semanticLabel,
  });

  final List<MessagingFilterChipOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final option in options)
            _MessagingFilterChip(
              key: option.key,
              label: option.label,
              selected: option.value == selected,
              onTap: () => onSelected(option.value),
            ),
        ],
      ),
    );
  }
}

final class _MessagingFilterChip extends StatefulWidget {
  const _MessagingFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MessagingFilterChip> createState() => _MessagingFilterChipState();
}

final class _MessagingFilterChipState extends State<_MessagingFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    // Starlight: the chip stays bare glass — no gray rest or gold rim —
    // and selection is a light rising from the stadium's bottom edge.
    final starlight = LicoSelectionLight.isStarlight(context);
    final Color fill;
    final Gradient? glow;
    if (starlight) {
      fill = !selected && _hovered
          ? LicoSelectionLight.hoverFill(context)
          : Colors.transparent;
      glow = selected
          ? RadialGradient(
              center: const Alignment(0, 1.1),
              radius: 1.4,
              colors: [
                colors.selectionInk.withValues(alpha: 0.22),
                colors.selectionInk.withValues(alpha: 0),
              ],
            )
          : null;
    } else {
      fill = selected
          ? colors.selectedSurface
          : _hovered
          ? colors.hoverOverlay
          : colors.surfaceLow;
      glow = null;
    }
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _hovered = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(LicoMotion.micro),
            curve: LicoMotion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: continuousHairlineDecoration(
              color: glow == null ? fill : null,
              gradient: glow,
              borderRadius: BorderRadius.circular(999),
              stroke: selected
                  ? starlight
                        ? colors.selectionInk.withValues(alpha: 0.30)
                        : colors.brandBorder
                  : colors.line,
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              style: selected
                  ? LicoListTypeRamp.of(context).chipLabelSelected
                  : LicoListTypeRamp.of(context).chipLabel,
            ),
          ),
        ),
      ),
    );
  }
}
