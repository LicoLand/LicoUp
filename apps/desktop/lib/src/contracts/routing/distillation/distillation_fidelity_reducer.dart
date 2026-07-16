import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

import 'distillation_package_models.dart';
import 'distillation_semantics.dart';
import 'distillation_source_content_classes.dart';

FidelityCheckResult checkDistillationFidelity({
  required DistillationPackage package,
  required RoutingFidelityContract contract,
  required DistillationSourceContentClasses sourceClasses,
}) {
  final checked = <String>[];
  final missing = <String>[];
  final grounded = <String>[];
  final uncovered = <String>[];

  for (final section in contract.requiredSections) {
    checked.add(section);
    final requiredBySource = switch (section) {
      'objective' => sourceClasses.hasObjective,
      'currentState' => sourceClasses.hasCurrentState,
      'decisions' => sourceClasses.hasDecisions,
      'constraints' => sourceClasses.hasConstraints,
      'openItems' => sourceClasses.hasOpenItems,
      _ => true,
    };
    if (!requiredBySource) {
      continue;
    }
    final present = switch (section) {
      'objective' => package.hasObjective,
      'currentState' => package.hasCurrentState,
      'decisions' => package.hasDecisions,
      'constraints' => package.hasConstraints,
      'openItems' => package.hasOpenItems,
      _ => _sectionNonEmpty(package, section),
    };
    if (!present) {
      missing.add(section);
      continue;
    }
    final sourceAnchors = sourceClasses.semanticAnchors[section] ?? const {};
    if (sourceAnchors.isNotEmpty) {
      final packageAnchors = distillationSemanticAnchors(
        _sectionText(package, section),
      );
      if (packageAnchors.intersection(sourceAnchors).isEmpty) {
        uncovered.add(section);
      } else {
        grounded.add(section);
      }
    }
  }

  if (package.estimatedLength > contract.maxPackageLength) {
    return FidelityCheckResult(
      passed: false,
      checkedSections: List.unmodifiable(checked),
      missingSections: List.unmodifiable(missing),
      groundedSections: List.unmodifiable(grounded),
      uncoveredSections: List.unmodifiable(uncovered),
      message:
          'Package length ${package.estimatedLength} exceeds maxPackageLength ${contract.maxPackageLength}.',
    );
  }

  if (missing.isNotEmpty || uncovered.isNotEmpty) {
    return FidelityCheckResult(
      passed: false,
      checkedSections: List.unmodifiable(checked),
      missingSections: List.unmodifiable(missing),
      groundedSections: List.unmodifiable(grounded),
      uncoveredSections: List.unmodifiable(uncovered),
      message: [
        if (missing.isNotEmpty)
          'Missing required sections: ${missing.join(', ')}.',
        if (uncovered.isNotEmpty)
          'Sections lack source-grounded semantic anchors: ${uncovered.join(', ')}.',
      ].join(' '),
    );
  }

  return FidelityCheckResult(
    passed: true,
    checkedSections: List.unmodifiable(checked),
    missingSections: const [],
    groundedSections: List.unmodifiable(grounded),
    uncoveredSections: const [],
    message: 'Fidelity check passed.',
  );
}

String _sectionText(DistillationPackage package, String section) {
  final value = package.toJson()[section];
  return value is List ? value.join('\n') : value?.toString() ?? '';
}

bool _sectionNonEmpty(DistillationPackage package, String section) {
  final value = package.toJson()[section];
  if (value is String) {
    return value.trim().isNotEmpty;
  }
  if (value is List) {
    return value.any((item) => item.toString().trim().isNotEmpty);
  }
  return false;
}
