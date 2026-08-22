import 'package:licoup/src/contracts/problem_codes/problem_code.dart';
import 'package:licoup/src/contracts/problem_codes/problem_code_domain.dart';
import 'package:licoup/src/contracts/problem_codes/problem_code_entries.dart';

/// Resolves legacy wire codes to the single LicoUp problem-code catalog.
abstract final class ProblemCodeCatalog {
  static const ProblemCode unmapped = ProblemCode(ProblemDomain.unmapped, 9900);

  static const String nativeAgentPrefix = 'native_agent_';

  static ProblemCode resolve(String? legacyCode) {
    final code = (legacyCode ?? '').trim();
    if (code.isEmpty) return unmapped;
    final direct = problemCodeEntries[code];
    if (direct != null) return direct;
    if (code.startsWith(nativeAgentPrefix) &&
        code.length > nativeAgentPrefix.length) {
      final stripped = code.substring(nativeAgentPrefix.length);
      final nested = problemCodeEntries[stripped];
      if (nested != null) return nested;
    }
    return unmapped;
  }

  static String wire(String? legacyCode) => resolve(legacyCode).wire;

  static ProblemDomain domainFor(String? legacyCode) =>
      resolve(legacyCode).domain;

  static bool isMapped(String? legacyCode) {
    final code = (legacyCode ?? '').trim();
    if (code.isEmpty) return false;
    return resolve(code) != unmapped;
  }
}
