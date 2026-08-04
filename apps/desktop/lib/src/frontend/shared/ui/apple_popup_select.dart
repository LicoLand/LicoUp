import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// macOS system accent blue used for menu item hover / selection.
const Color kAppleMenuSelectionBlue = Color(0xFF0A84FF);

/// One selectable row in an [ApplePopupSelect] menu.
@immutable
class ApplePopupSelectOption<T> {
  const ApplePopupSelectOption({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  final T value;
  final String label;
  final bool enabled;
}

/// High-fidelity Flutter stand-in for AppKit `NSPopUpButton` + `NSMenu`.
///
/// Closed control: glass surface, dual chevron, brand-yellow focus ring.
/// Open menu: frosted panel, checkmark gutter, inset blue selection highlight.
///
/// True AppKit hosting is not wired; this matches native visuals in Flutter.
class ApplePopupSelect<T> extends StatefulWidget {
  const ApplePopupSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.isExpanded = false,
    this.dense = false,
    this.emphasized = false,
    this.warningBorder = false,
    this.hint,
    this.menuMaxHeight = 320,
  });

  final T? value;
  final List<ApplePopupSelectOption<T>> options;
  final ValueChanged<T>? onChanged;
  final bool enabled;
  final bool isExpanded;
  final bool dense;
  final bool emphasized;
  final bool warningBorder;
  final String? hint;
  final double menuMaxHeight;

  @override
  State<ApplePopupSelect<T>> createState() => _ApplePopupSelectState<T>();
}

class _ApplePopupSelectState<T> extends State<ApplePopupSelect<T>> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'ApplePopupSelect');
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _dismissMenu(notify: false);
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  ApplePopupSelectOption<T>? get _selectedOption {
    final value = widget.value;
    if (value == null) {
      return null;
    }
    for (final option in widget.options) {
      if (option.value == value) {
        return option;
      }
    }
    return null;
  }

  String get _displayLabel {
    final selected = _selectedOption;
    if (selected != null) {
      return selected.label;
    }
    return widget.hint ?? '';
  }

  void _toggleMenu() {
    if (!widget.enabled || widget.onChanged == null) {
      return;
    }
    if (_menuOpen) {
      _dismissMenu();
      return;
    }
    _openMenu();
  }

  void _openMenu() {
    _focusNode.requestFocus();
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return;
    }
    final buttonSize = renderBox.size;
    final buttonOffset = renderBox.localToGlobal(Offset.zero);
    final media = MediaQuery.of(context);
    final colors = context.licoColors;

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return _ApplePopupMenuOverlay<T>(
          link: _layerLink,
          buttonSize: buttonSize,
          buttonOffset: buttonOffset,
          viewport: media.size,
          padding: media.padding,
          maxHeight: widget.menuMaxHeight,
          colors: colors,
          options: widget.options,
          selected: widget.value,
          onSelect: (value) {
            _dismissMenu();
            widget.onChanged?.call(value);
          },
          onDismiss: _dismissMenu,
        );
      },
    );
    overlay.insert(_overlayEntry!);
    setState(() => _menuOpen = true);
  }

  void _dismissMenu({bool notify = true}) {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (_menuOpen && notify && mounted) {
      setState(() => _menuOpen = false);
    } else {
      _menuOpen = false;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || widget.onChanged == null) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _toggleMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _menuOpen) {
      _dismissMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = widget.enabled && widget.onChanged != null;
    final focused = _focusNode.hasFocus || _menuOpen;
    final vertical = widget.dense ? 5.0 : (widget.emphasized ? 9.0 : 7.0);
    final fontSize = widget.emphasized ? 15.0 : (widget.dense ? 12.0 : 13.0);
    final fontWeight = widget.emphasized ? FontWeight.w700 : FontWeight.w500;
    final borderRadius = BorderRadius.circular(
      AppleControlMetrics.controlCornerRadius,
    );

    Widget control = CompositedTransformTarget(
      link: _layerLink,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: enabled ? _toggleMenu : null,
            behavior: HitTestBehavior.opaque,
            child: AppleGlassSurface(
              borderRadius: borderRadius,
              focused: focused && enabled,
              focusColor: colors.primaryStrong,
              focusedBorderWidth: AppleControlMetrics.searchFocusRingWidth,
              idleBorderColor: widget.warningBorder
                  ? colors.warning.withAlpha(180)
                  : null,
              fillAlpha: colors.isDark
                  ? (focused ? 34 : 22)
                  : (focused ? 22 : 12),
              child: Padding(
                padding: EdgeInsets.fromLTRB(10, vertical, 8, vertical),
                child: Row(
                  mainAxisSize: widget.isExpanded
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  children: [
                    Expanded(
                      child: Text(
                        _displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: enabled
                              ? colors.text.withAlpha(235)
                              : colors.textMuted.withAlpha(140),
                          fontSize: fontSize,
                          fontWeight: fontWeight,
                          letterSpacing: -0.08,
                          height: 1.15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _ApplePopupChevrons(
                      color: enabled
                          ? colors.textMuted.withAlpha(200)
                          : colors.textMuted.withAlpha(100),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return control;
  }
}

/// Labeled popup select used in policy / settings form rows.
class ApplePopupSelectField<T> extends StatelessWidget {
  const ApplePopupSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.hint,
  });

  final String label;
  final T? value;
  final List<ApplePopupSelectOption<T>> options;
  final ValueChanged<T>? onChanged;
  final bool enabled;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.04,
          ),
        ),
        const SizedBox(height: 6),
        ApplePopupSelect<T>(
          value: value,
          options: options,
          onChanged: enabled ? onChanged : null,
          enabled: enabled,
          isExpanded: true,
          dense: true,
          hint: hint,
        ),
      ],
    );
  }
}

class _ApplePopupChevrons extends StatelessWidget {
  const _ApplePopupChevrons({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 18,
      child: CustomPaint(painter: _DualChevronPainter(color: color)),
    );
  }
}

class _DualChevronPainter extends CustomPainter {
  const _DualChevronPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final cx = size.width / 2;
    // Up chevron
    canvas.drawPath(
      Path()
        ..moveTo(cx - 3.2, size.height * 0.42)
        ..lineTo(cx, size.height * 0.28)
        ..lineTo(cx + 3.2, size.height * 0.42),
      paint,
    );
    // Down chevron
    canvas.drawPath(
      Path()
        ..moveTo(cx - 3.2, size.height * 0.58)
        ..lineTo(cx, size.height * 0.72)
        ..lineTo(cx + 3.2, size.height * 0.58),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DualChevronPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _ApplePopupMenuOverlay<T> extends StatefulWidget {
  const _ApplePopupMenuOverlay({
    required this.link,
    required this.buttonSize,
    required this.buttonOffset,
    required this.viewport,
    required this.padding,
    required this.maxHeight,
    required this.colors,
    required this.options,
    required this.selected,
    required this.onSelect,
    required this.onDismiss,
  });

  final LayerLink link;
  final Size buttonSize;
  final Offset buttonOffset;
  final Size viewport;
  final EdgeInsets padding;
  final double maxHeight;
  final LicoThemeColors colors;
  final List<ApplePopupSelectOption<T>> options;
  final T? selected;
  final ValueChanged<T> onSelect;
  final VoidCallback onDismiss;

  @override
  State<_ApplePopupMenuOverlay<T>> createState() =>
      _ApplePopupMenuOverlayState<T>();
}

class _ApplePopupMenuOverlayState<T> extends State<_ApplePopupMenuOverlay<T>> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final menuWidth = (widget.buttonSize.width + 24).clamp(168.0, 360.0);
    final estimatedHeight = (widget.options.length * 28.0 + 10).clamp(
      36.0,
      widget.maxHeight,
    );
    final spaceBelow =
        widget.viewport.height -
        widget.padding.bottom -
        widget.buttonOffset.dy -
        widget.buttonSize.height -
        8;
    final openUpward =
        spaceBelow < estimatedHeight &&
        widget.buttonOffset.dy > estimatedHeight + 8;
    final followerOffset = openUpward
        ? Offset(0, -(estimatedHeight + 4))
        : Offset(0, widget.buttonSize.height + 4);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: const ColoredBox(color: Color(0x01000000)),
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          offset: followerOffset,
          child: Material(
            color: Colors.transparent,
            elevation: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: menuWidth,
                maxWidth: menuWidth,
                maxHeight: widget.maxHeight,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    AppleControlMetrics.menuCornerRadius,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(
                        widget.colors.isDark ? 140 : 70,
                      ),
                      blurRadius: 28,
                      spreadRadius: 0,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: Colors.black.withAlpha(
                        widget.colors.isDark ? 60 : 28,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    AppleControlMetrics.menuCornerRadius,
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.colors.isDark
                            ? const Color(0xE6282828)
                            : const Color(0xF2F5F5F5),
                        borderRadius: BorderRadius.circular(
                          AppleControlMetrics.menuCornerRadius,
                        ),
                        border: Border.all(
                          color: Colors.white.withAlpha(
                            widget.colors.isDark ? 42 : 90,
                          ),
                          width: AppleControlMetrics.hairline,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: SingleChildScrollView(
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < widget.options.length; i++)
                                _ApplePopupMenuItem<T>(
                                  option: widget.options[i],
                                  selected:
                                      widget.options[i].value ==
                                      widget.selected,
                                  hovered: _hoveredIndex == i,
                                  dark: widget.colors.isDark,
                                  onHover: (hovering) {
                                    setState(() {
                                      _hoveredIndex = hovering ? i : null;
                                    });
                                  },
                                  onTap: widget.options[i].enabled
                                      ? () => widget.onSelect(
                                          widget.options[i].value,
                                        )
                                      : null,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ApplePopupMenuItem<T> extends StatelessWidget {
  const _ApplePopupMenuItem({
    required this.option,
    required this.selected,
    required this.hovered,
    required this.onHover,
    required this.onTap,
    required this.dark,
  });

  final ApplePopupSelectOption<T> option;
  final bool selected;
  final bool hovered;
  final ValueChanged<bool> onHover;
  final VoidCallback? onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final highlight = hovered && enabled;
    final idle = dark
        ? Colors.white.withAlpha(enabled ? 230 : 90)
        : Colors.black.withAlpha(enabled ? 220 : 90);
    final textColor = highlight ? Colors.white : idle;
    final checkColor = highlight
        ? Colors.white
        : (dark ? Colors.white.withAlpha(220) : Colors.black.withAlpha(200));

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: AnimatedContainer(
            duration: LicoMotion.micro,
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
            decoration: BoxDecoration(
              color: highlight ? kAppleMenuSelectionBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: selected
                      ? Icon(Icons.check, size: 13, color: checkColor)
                      : null,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.08,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
