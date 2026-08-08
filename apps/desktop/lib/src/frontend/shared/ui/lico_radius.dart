/// Corner-radius rules for nested rounded rectangles.
///
/// When a rounded shape sits inside another rounded shape with a uniform gap
/// between them, their corners only look like one continuous band if they
/// share a center:
///
/// ```text
/// outer radius = inner radius + gap
/// ```
///
/// Equal gaps with unrelated radii make the corner band visibly thicken or
/// thin around the curve. The client previously violated this in the message
/// composer, where a radius-15 circle sat inside a radius-8 field with a 4px
/// gap — the nested radius should have been 4.
///
/// These helpers make the rule computable so it can be asserted in tests
/// instead of restated in review.
abstract final class LicoRadius {
  /// Radius of a control nested inside a container.
  ///
  /// Never returns a negative radius: when the gap is larger than the
  /// container's own radius the correct inner shape is a square corner.
  static double nested(double outerRadius, double gap) {
    final inner = outerRadius - gap;
    return inner < 0 ? 0 : inner;
  }

  /// Radius of a container that must enclose a control concentrically.
  static double enclosing(double innerRadius, double gap) {
    return innerRadius + gap;
  }

  /// Whether [inner] and [outer] are concentric across [gap].
  ///
  /// Uses a small tolerance so values that came from independent arithmetic
  /// still compare equal.
  static bool isConcentric(
    double inner,
    double outer,
    double gap, {
    double tolerance = 0.01,
  }) {
    return (outer - gap - inner).abs() <= tolerance;
  }

  /// Radius for the message composer field.
  ///
  /// Large enough to read as a soft capsule at one line, but not a true
  /// capsule — the field grows to four lines and a stadium shape at that
  /// height looks like a pill, not an input.
  static const double composerField = 14;

  /// Uniform gap between the composer field's edge and its inline controls.
  static const double composerInset = 4;

  /// Radius of the composer's inline controls. Concentric with
  /// [composerField] across [composerInset].
  static double get composerControl => nested(composerField, composerInset);

  /// Radius for a standard content card.
  static const double card = 12;

  /// Radius for a floating layer: menu, popover, dropdown.
  static const double floating = 10;

  /// Radius for an inline chip, badge, or pill.
  static const double chip = 8;

  /// Radius for an inset well: code block, terminal, recessed field.
  static const double well = 6;
}
