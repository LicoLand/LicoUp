import 'dart:convert';

import 'distillation_package_models.dart';

DistillationPackage? parseDistillationPackageResponse(
  String response, {
  required String sourceSessionId,
  required String sourceAgentId,
  required String createdAt,
}) {
  final trimmed = response.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final fence = RegExp(
    r'```(?:json)?\s*(\{[\s\S]*?\})\s*```',
    multiLine: true,
  ).firstMatch(trimmed);
  final candidate = fence?.group(1) ?? _extractJsonObject(trimmed);
  if (candidate == null) {
    return null;
  }

  try {
    final decoded = jsonDecode(candidate);
    if (decoded is! Map) {
      return null;
    }
    final parsed = DistillationPackage.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    return DistillationPackage(
      objective: parsed.objective,
      currentState: parsed.currentState,
      decisions: parsed.decisions,
      constraints: parsed.constraints,
      openItems: parsed.openItems,
      sourceSessionId: parsed.sourceSessionId.isEmpty
          ? sourceSessionId
          : parsed.sourceSessionId,
      sourceAgentId: parsed.sourceAgentId.isEmpty
          ? sourceAgentId
          : parsed.sourceAgentId,
      createdAt: parsed.createdAt.isEmpty ? createdAt : parsed.createdAt,
    );
  } on FormatException {
    return null;
  }
}

String? _extractJsonObject(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  return text.substring(start, end + 1);
}
