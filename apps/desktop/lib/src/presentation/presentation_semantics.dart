/// Stable renderer-facing phase shared by feature projections.
enum PresentationPhase { idle, loading, ready, applying, failed }

/// Stable renderer-facing notice severity.
enum PresentationNoticeSeverity { information, success, warning, error }

/// One immutable labeled choice exposed by a presentation contract.
final class PresentationChoice {
  const PresentationChoice({
    required this.id,
    required this.label,
    this.description = '',
    this.selected = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final String description;
  final bool selected;
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationChoice &&
          other.id == id &&
          other.label == label &&
          other.description == description &&
          other.selected == selected &&
          other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, label, description, selected, enabled);
}

/// One immutable user-visible status notice.
final class PresentationNotice {
  const PresentationNotice({
    required this.id,
    required this.title,
    required this.message,
    required this.severity,
    this.reasonCode = '',
    this.reference = '',
    this.recovery = '',
    this.copyText = '',
  });

  final String id;
  final String title;
  final String message;
  final PresentationNoticeSeverity severity;
  final String reasonCode;
  final String reference;
  final String recovery;
  final String copyText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationNotice &&
          other.id == id &&
          other.title == title &&
          other.message == message &&
          other.severity == severity &&
          other.reasonCode == reasonCode &&
          other.reference == reference &&
          other.recovery == recovery &&
          other.copyText == copyText;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    message,
    severity,
    reasonCode,
    reference,
    recovery,
    copyText,
  );
}

/// One immutable renderer-ready metric.
final class PresentationMetric {
  const PresentationMetric({
    required this.id,
    required this.label,
    required this.value,
    required this.unit,
  });

  final String id;
  final String label;
  final num value;
  final String unit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationMetric &&
          other.id == id &&
          other.label == label &&
          other.value == value &&
          other.unit == unit;

  @override
  int get hashCode => Object.hash(id, label, value, unit);
}

List<T> immutablePresentationList<T>(Iterable<T> values) =>
    List<T>.unmodifiable(values);

bool samePresentationList<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
