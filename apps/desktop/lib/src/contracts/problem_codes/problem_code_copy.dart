import 'package:licoup/src/contracts/problem_codes/problem_code_catalog.dart';
import 'package:licoup/src/contracts/problem_codes/problem_code_domain.dart';

/// Copy payload for a failure. No message body, tokens, paths, or PII.
abstract final class ProblemCodeCopy {
  /// Capsule-facing problem code for a legacy wire code.
  static String problemCode(String? legacyCode) =>
      ProblemCodeCatalog.wire(legacyCode);

  /// Detailed copy blob. Include both [legacyCode] and [occurrenceId].
  static String copyableDetail({
    String legacyCode = '',
    String stage = '',
    String occurrenceId = '',
    String occurredAt = '',
    String strategyCode = '',
    String component = '',
    bool? retryable,
    String recovery = '',
    ProblemDomain? domain,
  }) {
    final code = legacyCode.trim();
    final resolved = ProblemCodeCatalog.resolve(code);
    final safeComponent = _safeToken(component);
    final safeRecovery = _safeToken(recovery);
    final lines = <String>[
      'LicoUp problem',
      if (occurrenceId.trim().isNotEmpty) 'ref: ${occurrenceId.trim()}',
      if (code.isNotEmpty) 'problemCode: ${resolved.wire}',
      if (code.isNotEmpty) 'code: $code',
      if (code.isNotEmpty) 'domain: ${(domain ?? resolved.domain).id}',
      if (stage.trim().isNotEmpty) 'stage: ${stage.trim()}',
      if (safeComponent.isNotEmpty) 'component: $safeComponent',
      if (retryable != null) 'retryable: $retryable',
      if (safeRecovery.isNotEmpty) 'recovery: $safeRecovery',
      if (occurredAt.trim().isNotEmpty) 'at: ${occurredAt.trim()}',
      if (strategyCode.trim().isNotEmpty)
        'strategyCode: ${strategyCode.trim()}',
    ];
    return lines.join('\n');
  }

  static String _safeToken(String value) {
    final token = value.trim();
    return RegExp(r'^[a-z][a-z0-9_/-]{0,95}$').hasMatch(token) ? token : '';
  }
}
