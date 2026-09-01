import 'package:licoup/src/contracts/problem_codes/problem_code_domain.dart';

/// Stable LicoUp problem code. Same failure class always uses the same code.
///
/// Distinct from a per-incident occurrence id such as `#L-A3F2`.
final class ProblemCode {
  const ProblemCode(this.domain, this.number);

  final ProblemDomain domain;
  final int number;

  /// Wire form, for example `LU-CV-1402`.
  String get wire {
    final digits = number.toString().padLeft(4, '0');
    return 'LU-${domain.prefix}-$digits';
  }

  bool get isUnmapped => domain == ProblemDomain.unmapped;

  static ProblemCode? tryParse(String value) {
    final match = _wirePattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final prefix = match.group(1)!;
    final number = int.parse(match.group(2)!);
    for (final domain in ProblemDomain.values) {
      if (domain.prefix == prefix && domain.contains(number)) {
        return ProblemCode(domain, number);
      }
    }
    return null;
  }

  static final _wirePattern = RegExp(r'^LU-([A-Z]{2})-([0-9]{4})$');

  @override
  bool operator ==(Object other) =>
      other is ProblemCode && other.domain == domain && other.number == number;

  @override
  int get hashCode => Object.hash(domain, number);

  @override
  String toString() => wire;
}
