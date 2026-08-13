import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// The client's single icon-button recipe.
///
/// Before this existed the client carried five near-identical implementations
/// (header circle, conversation action, contact action, glass action, chrome
/// action), each with its own diameter, hover color, and border. They read as
/// unrelated controls. Every icon-only control now instantiates this with a
/// size, a shape, and a tone.
///
/// Shape is not a free choice. A control nested inside a rounded container
/// must use [LicoIconButtonShape.concentric] so its corner shares a center
/// with the container's corner — see [LicoRadius].
enum LicoIconButtonSize {
  /// Inline with dense text: table rows, chips, inline disclosures.
  small(28, 15),

  /// The default. Toolbars, headers, composer controls.
  medium(32, 17),

  /// Prominent single actions and touch targets.
  large(36, 19);

  const LicoIconButtonSize(this.extent, this.iconSize);

  /// Width and height of the control.
  final double extent;

  /// Glyph size. Fixed per button size so different glyphs carry equal weight.
  final double iconSize;
}

enum LicoIconButtonShape {
  /// A full circle. Only valid when the button is not nested inside another
  /// rounded container, or when the container is a capsule of matching height.
  circle,

  /// A rounded square whose radius is supplied by the caller from
  /// [LicoRadius.nested] so the nesting stays concentric.
  concentric,
}

enum LicoIconButtonTone {
  /// No fill, no rim. Reveals a wash on hover. The quietest option and the
  /// correct default inside a toolbar.
  ghost,

  /// A hairline rim with no fill. For standalone controls that need to read
  /// as a control before hover.
  outlined,

  /// A neutral raised fill. For controls on a busy or image background.
  filled,

  /// A brand fill with brand ink. Reserved for the single most important
  /// action in a view — sending a message, confirming a destructive dialog.
  /// Never use two brand-tone buttons in one row.
  brand,
}

/// A single icon-only control.
final class LicoIconButton extends StatefulWidget {
  const LicoIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = LicoIconButtonSize.medium,
    this.shape = LicoIconButtonShape.circle,
    this.tone = LicoIconButtonTone.ghost,
    this.radius,
    this.selected = false,
    this.badge = false,
    this.busy = false,
  }) : assert(
         shape != LicoIconButtonShape.concentric || radius != null,
         'lico_icon_button_concentric_requires_radius',
       );

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final LicoIconButtonSize size;
  final LicoIconButtonShape shape;
  final LicoIconButtonTone tone;

  /// Corner radius for [LicoIconButtonShape.concentric]. Compute it with
  /// [LicoRadius.nested] from the parent's radius and the gap between them.
  final double? radius;

  /// Persistent active state, distinct from a transient hover.
  final bool selected;

  /// Draws an accent dot at the trailing top corner.
  final bool badge;

  /// Replaces the glyph with a progress indicator and blocks presses while
  /// the action is in flight.
  final bool busy;

  @override
  State<LicoIconButton> createState() => _LicoIconButtonState();
}

final class _LicoIconButtonState extends State<LicoIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = widget.onPressed != null && !widget.busy;
    final active = enabled && (_hovered || _pressed);

    final borderRadius = switch (widget.shape) {
      LicoIconButtonShape.circle => BorderRadius.circular(
        widget.size.extent / 2,
      ),
      LicoIconButtonShape.concentric => BorderRadius.circular(widget.radius!),
    };

    return Tooltip(
      message: widget.tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: widget.selected,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled
                ? (_) {
                    setState(() => _pressed = false);
                    widget.onPressed!();
                  }
                : null,
            onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedContainer(
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              width: widget.size.extent,
              height: widget.size.extent,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                color: _fill(colors, enabled: enabled, active: active),
                border: _border(colors, enabled: enabled, active: active),
                // A brand-tone control emits light. This is what makes the
                // single most important action in a view read as energetic
                // rather than merely coloured.
                boxShadow: widget.tone == LicoIconButtonTone.brand && enabled
                    ? [
                        BoxShadow(
                          color: colors.brandGlow,
                          blurRadius: active ? 18 : 12,
                          spreadRadius: active ? 1 : 0,
                        ),
                      ]
                    : widget.selected
                    ? [BoxShadow(color: colors.accentGlow, blurRadius: 10)]
                    : null,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (widget.busy)
                    SizedBox(
                      width: widget.size.iconSize,
                      height: widget.size.iconSize,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.textMuted,
                      ),
                    )
                  else
                    IconTheme.merge(
                      data: IconThemeData(
                        size: widget.size.iconSize,
                        color: _iconColor(
                          colors,
                          enabled: enabled,
                          active: active,
                        ),
                      ),
                      child: widget.icon,
                    ),
                  if (widget.badge)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.accent,
                        ),
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

  Color _fill(
    LicoThemeColors colors, {
    required bool enabled,
    required bool active,
  }) {
    if (widget.tone == LicoIconButtonTone.brand) {
      if (!enabled) {
        return colors.surfaceLow;
      }
      return active ? colors.primaryStrong : colors.primary;
    }
    if (widget.selected) {
      return colors.selectedSurface;
    }
    if (_pressed && enabled) {
      return colors.pressedOverlay;
    }
    if (active) {
      return colors.hoverOverlay;
    }
    return switch (widget.tone) {
      LicoIconButtonTone.filled => colors.surfaceLow,
      LicoIconButtonTone.ghost ||
      LicoIconButtonTone.outlined ||
      LicoIconButtonTone.brand => Colors.transparent,
    };
  }

  Border? _border(
    LicoThemeColors colors, {
    required bool enabled,
    required bool active,
  }) {
    return switch (widget.tone) {
      // A brand fill can fall below 3:1 against a light surface, so its rim
      // is mandatory rather than decorative.
      LicoIconButtonTone.brand =>
        enabled
            ? Border.all(color: colors.brandBorder, width: 1)
            : Border.all(color: colors.line, width: 1),
      LicoIconButtonTone.outlined => Border.all(
        color: active ? colors.lineStrong : colors.line,
        width: 1,
      ),
      LicoIconButtonTone.filled => Border.all(color: colors.line, width: 1),
      LicoIconButtonTone.ghost => null,
    };
  }

  Color _iconColor(
    LicoThemeColors colors, {
    required bool enabled,
    required bool active,
  }) {
    if (!enabled) {
      return colors.textDisabled;
    }
    if (widget.tone == LicoIconButtonTone.brand) {
      return colors.textOnPrimary;
    }
    if (widget.selected) {
      return colors.text;
    }
    return active ? colors.text : colors.textMuted;
  }
}
