import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

@immutable
class DistillationPackage {
  const DistillationPackage({
    required this.objective,
    required this.currentState,
    required this.decisions,
    required this.constraints,
    required this.openItems,
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.createdAt,
  });

  final String objective;
  final String currentState;
  final List<String> decisions;
  final List<String> constraints;
  final List<String> openItems;
  final String sourceSessionId;
  final String sourceAgentId;
  final String createdAt;

  bool get hasObjective => objective.trim().isNotEmpty;
  bool get hasCurrentState => currentState.trim().isNotEmpty;
  bool get hasDecisions => decisions.any((d) => d.trim().isNotEmpty);
  bool get hasConstraints => constraints.any((c) => c.trim().isNotEmpty);
  bool get hasOpenItems => openItems.any((i) => i.trim().isNotEmpty);

  int get estimatedLength {
    final buffer = StringBuffer()
      ..write(objective)
      ..write(currentState)
      ..writeAll(decisions)
      ..writeAll(constraints)
      ..writeAll(openItems);
    return buffer.length;
  }

  Map<String, dynamic> toJson() {
    return {
      'objective': objective,
      'currentState': currentState,
      'decisions': decisions,
      'constraints': constraints,
      'openItems': openItems,
      'sourceSessionId': sourceSessionId,
      'sourceAgentId': sourceAgentId,
      'createdAt': createdAt,
    };
  }

  factory DistillationPackage.fromJson(Map<String, dynamic> json) {
    return DistillationPackage(
      objective: _string(json['objective']),
      currentState: _string(json['currentState']),
      decisions: _stringList(json['decisions']),
      constraints: _stringList(json['constraints']),
      openItems: _stringList(json['openItems']),
      sourceSessionId: _string(json['sourceSessionId']),
      sourceAgentId: _string(json['sourceAgentId']),
      createdAt: _string(json['createdAt']),
    );
  }
}

@immutable
class FidelityCheckResult {
  const FidelityCheckResult({
    required this.passed,
    required this.checkedSections,
    required this.missingSections,
    this.groundedSections = const [],
    this.uncoveredSections = const [],
    this.message = '',
  });

  final bool passed;
  final List<String> checkedSections;
  final List<String> missingSections;
  final List<String> groundedSections;
  final List<String> uncoveredSections;
  final String message;

  Map<String, dynamic> toJson() {
    return {
      'passed': passed,
      'checkedSections': checkedSections,
      'missingSections': missingSections,
      'groundedSections': groundedSections,
      'uncoveredSections': uncoveredSections,
      'message': message,
    };
  }
}

sealed class DistillationResult {
  const DistillationResult();
}

class DistillationSuccess extends DistillationResult {
  const DistillationSuccess({
    required this.package,
    required this.fidelity,
    this.usage = const DistillationUsage(),
    this.distillerAgentId = '',
    this.audit = const DistillationAuditRecord.empty(),
  });

  final DistillationPackage package;
  final FidelityCheckResult fidelity;
  final DistillationUsage usage;
  final String distillerAgentId;
  final DistillationAuditRecord audit;
}

class DistillationFailure extends DistillationResult {
  const DistillationFailure({
    required this.reason,
    this.retriesExhausted = false,
    this.distillerUnavailable = false,
    this.usage = const DistillationUsage(),
    this.audit = const DistillationAuditRecord.empty(),
  });

  final String reason;
  final bool retriesExhausted;
  final bool distillerUnavailable;
  final DistillationUsage usage;
  final DistillationAuditRecord audit;
}

/// Token / call cost reported for distillation sends (V-003-G).
@immutable
class DistillationUsage {
  const DistillationUsage({
    this.dispatchCallCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  final int dispatchCallCount;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  DistillationUsage operator +(DistillationUsage other) {
    return DistillationUsage(
      dispatchCallCount: dispatchCallCount + other.dispatchCallCount,
      promptTokens: promptTokens + other.promptTokens,
      completionTokens: completionTokens + other.completionTokens,
      totalTokens: totalTokens + other.totalTokens,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dispatchCallCount': dispatchCallCount,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
    };
  }
}

/// Audit record: package + fidelity + source refs only — never raw source text.
@immutable
class DistillationAuditRecord {
  const DistillationAuditRecord({
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.distillerAgentId,
    required this.package,
    required this.fidelity,
    required this.usage,
    required this.createdAt,
  });

  const DistillationAuditRecord.empty()
    : sourceSessionId = '',
      sourceAgentId = '',
      distillerAgentId = '',
      package = null,
      fidelity = null,
      usage = const DistillationUsage(),
      createdAt = '';

  final String sourceSessionId;
  final String sourceAgentId;
  final String distillerAgentId;
  final DistillationPackage? package;
  final FidelityCheckResult? fidelity;
  final DistillationUsage usage;
  final String createdAt;

  bool get isEmpty => sourceSessionId.isEmpty && package == null;

  Map<String, dynamic> toJson() {
    return {
      'sourceSessionId': sourceSessionId,
      'sourceAgentId': sourceAgentId,
      'distillerAgentId': distillerAgentId,
      if (package != null) 'package': package!.toJson(),
      if (fidelity != null) 'fidelity': fidelity!.toJson(),
      'usage': usage.toJson(),
      'createdAt': createdAt,
    };
  }
}

/// One message (or summary line) supplied as distillation input.
@immutable
class DistillationConversationTurn {
  const DistillationConversationTurn({required this.role, required this.text});

  final String role;
  final String text;
}

/// Hard input limits for one distillation dispatch. Token usage is a
/// conservative local approximation: one non-ASCII rune or four ASCII bytes.
const int distillationInputMaxTurns = 48;
const int distillationInputMaxBytes = 64 * 1024;
const int distillationInputMaxApproxTokens = 12 * 1024;
const int distillationInputMaxTurnBytes = 8 * 1024;

@immutable
class DistillationInputWindow {
  const DistillationInputWindow({
    required this.turns,
    required this.byteCount,
    required this.approxTokenCount,
    required this.sourceTurnCount,
  });

  final List<DistillationConversationTurn> turns;
  final int byteCount;
  final int approxTokenCount;
  final int sourceTurnCount;

  bool get truncated => turns.length < sourceTurnCount;
}

/// Selects a bounded, chronological window by pinning the newest source turn
/// for every preservation class, then filling remaining capacity newest-first.
/// This is O(n) in source turns and retains no unbounded intermediate text.
DistillationInputWindow buildDistillationInputWindow(
  List<DistillationConversationTurn> source, {
  Set<String> preserveFields = const {'objective', 'decisions', 'constraints'},
  int maxTurns = distillationInputMaxTurns,
  int maxBytes = distillationInputMaxBytes,
  int maxApproxTokens = distillationInputMaxApproxTokens,
}) {
  final turnLimit = maxTurns.clamp(1, distillationInputMaxTurns);
  final byteLimit = maxBytes.clamp(1, distillationInputMaxBytes);
  final tokenLimit = maxApproxTokens.clamp(1, distillationInputMaxApproxTokens);
  final compact = <DistillationConversationTurn>[];
  for (final turn in source) {
    final text = _truncateUtf8(turn.text.trim(), distillationInputMaxTurnBytes);
    if (text.isNotEmpty) {
      compact.add(
        DistillationConversationTurn(role: turn.role.trim(), text: text),
      );
    }
  }

  final pinnedByField = <String, int>{};
  for (final field in preserveFields) {
    for (var index = compact.length - 1; index >= 0; index--) {
      if (_semanticSections(compact[index].text).contains(field)) {
        pinnedByField[field] = index;
        break;
      }
    }
  }

  final selected = <int>{};
  var bytes = 0;
  var tokens = 0;
  bool addIndex(int index) {
    if (selected.contains(index) || selected.length >= turnLimit) {
      return false;
    }
    final turn = compact[index];
    final turnBytes = utf8.encode('${turn.role}:${turn.text}\n').length;
    final turnTokens = approximateDistillationTokens(turn.text);
    if (bytes + turnBytes > byteLimit || tokens + turnTokens > tokenLimit) {
      return false;
    }
    selected.add(index);
    bytes += turnBytes;
    tokens += turnTokens;
    return true;
  }

  for (final field in const ['objective', 'decisions', 'constraints']) {
    final index = pinnedByField[field];
    if (index != null) {
      addIndex(index);
    }
  }
  final remainingPins =
      pinnedByField.entries
          .where(
            (entry) =>
                entry.key != 'objective' &&
                entry.key != 'decisions' &&
                entry.key != 'constraints',
          )
          .map((entry) => entry.value)
          .toSet()
          .toList()
        ..sort((a, b) => b.compareTo(a));
  for (final index in remainingPins) {
    addIndex(index);
  }
  for (var index = compact.length - 1; index >= 0; index--) {
    addIndex(index);
  }

  final ordered = selected.toList()..sort();
  return DistillationInputWindow(
    turns: List.unmodifiable([for (final index in ordered) compact[index]]),
    byteCount: bytes,
    approxTokenCount: tokens,
    sourceTurnCount: source.length,
  );
}

int approximateDistillationTokens(String text) {
  var asciiBytes = 0;
  var nonAsciiRunes = 0;
  for (final rune in text.runes) {
    if (rune <= 0x7f) {
      asciiBytes += 1;
    } else {
      nonAsciiRunes += 1;
    }
  }
  return ((asciiBytes + 3) ~/ 4) + nonAsciiRunes;
}

/// Content classes detected in the source conversation for fidelity gating.
@immutable
class DistillationSourceContentClasses {
  const DistillationSourceContentClasses({
    this.hasObjective = false,
    this.hasCurrentState = false,
    this.hasDecisions = false,
    this.hasConstraints = false,
    this.hasOpenItems = false,
    this.semanticAnchors = const {},
  });

  final bool hasObjective;
  final bool hasCurrentState;
  final bool hasDecisions;
  final bool hasConstraints;
  final bool hasOpenItems;
  final Map<String, Set<String>> semanticAnchors;

  factory DistillationSourceContentClasses.detect(
    List<DistillationConversationTurn> turns,
  ) {
    final bySection = <String, Set<String>>{};
    for (final turn in turns) {
      for (final section in _semanticSections(turn.text)) {
        bySection
            .putIfAbsent(section, () => <String>{})
            .addAll(_semanticAnchors(turn.text));
      }
    }
    if (!(bySection['objective']?.isNotEmpty ?? false)) {
      for (final turn in turns) {
        if (turn.role.toLowerCase() == 'user' && turn.text.trim().isNotEmpty) {
          bySection['objective'] = _semanticAnchors(turn.text);
          break;
        }
      }
    }
    if (!(bySection['currentState']?.isNotEmpty ?? false)) {
      for (final turn in turns.reversed) {
        if (turn.role.toLowerCase() == 'assistant' &&
            turn.text.trim().isNotEmpty) {
          bySection['currentState'] = _semanticAnchors(turn.text);
          break;
        }
      }
    }
    return DistillationSourceContentClasses(
      hasObjective: bySection['objective']?.isNotEmpty ?? false,
      hasCurrentState: bySection['currentState']?.isNotEmpty ?? false,
      hasDecisions: bySection['decisions']?.isNotEmpty ?? false,
      hasConstraints: bySection['constraints']?.isNotEmpty ?? false,
      hasOpenItems: bySection['openItems']?.isNotEmpty ?? false,
      semanticAnchors: Map.unmodifiable({
        for (final entry in bySection.entries)
          entry.key: Set.unmodifiable(entry.value),
      }),
    );
  }
}

@immutable
class DistillationRequest {
  const DistillationRequest({
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.turns,
    this.targetAgentId = '',
    this.distillerSessionId = '',
    this.isDistillerReady,
    this.now,
  });

  final String sourceSessionId;
  final String sourceAgentId;
  final List<DistillationConversationTurn> turns;
  final String targetAgentId;
  final String distillerSessionId;

  /// Readiness probe for a candidate distiller agent id.
  final bool Function(String agentId)? isDistillerReady;

  /// Clock injection for deterministic tests.
  final DateTime Function()? now;

  DistillationSourceContentClasses get contentClasses =>
      DistillationSourceContentClasses.detect(turns);

  DistillationRequest withTurns(List<DistillationConversationTurn> value) {
    return DistillationRequest(
      sourceSessionId: sourceSessionId,
      sourceAgentId: sourceAgentId,
      turns: value,
      targetAgentId: targetAgentId,
      distillerSessionId: distillerSessionId,
      isDistillerReady: isDistillerReady,
      now: now,
    );
  }
}

/// Request issued through the injected dispatch-lane callback.
@immutable
class DistillationLaneRequest {
  const DistillationLaneRequest({
    required this.agentId,
    required this.text,
    required this.sessionId,
    this.corrective = false,
  });

  final String agentId;
  final String text;
  final String sessionId;
  final bool corrective;
}

/// Response from the injected dispatch-lane callback.
@immutable
class DistillationLaneResponse {
  const DistillationLaneResponse({
    required this.ok,
    this.text = '',
    this.errorMessage = '',
    this.sessionId = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final bool ok;
  final String text;
  final String errorMessage;
  final String sessionId;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  DistillationUsage get usage => DistillationUsage(
    dispatchCallCount: 1,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
  );
}

/// Callback matching the parent dispatch lane send path (Architecture.md).
typedef DispatchLaneSend =
    Future<DistillationLaneResponse> Function(DistillationLaneRequest request);

/// Distillation handoff orchestrator.
abstract class DistillationBroker {
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  });
}

/// Structural fidelity check against the policy contract and source classes.
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
      final packageAnchors = _semanticAnchors(_sectionText(package, section));
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

Set<String> _semanticSections(String source) {
  final text = source.toLowerCase();
  final result = <String>{};
  bool hasAny(List<String> cues) => cues.any(text.contains);
  if (hasAny(const [
    'goal',
    'objective',
    'need to',
    'aim to',
    'deliver',
    'ship',
    '目标',
    '目的',
    '需要',
    '要做',
    '交付',
    '实现',
  ])) {
    result.add('objective');
  }
  if (hasAny(const [
    'current state',
    'status',
    'progress',
    'in progress',
    'landed',
    'completed',
    '当前',
    '现状',
    '状态',
    '进度',
    '已经',
    '已完成',
    '正在',
  ])) {
    result.add('currentState');
  }
  if (hasAny(const [
    'decision',
    'decided',
    'we chose',
    'we will use',
    'adopt',
    '决定',
    '选择',
    '采用',
    '确定',
    '选用',
  ])) {
    result.add('decisions');
  }
  if (hasAny(const [
    'constraint',
    'must not',
    'must ',
    'only ',
    'cannot',
    'never ',
    'forbid',
    '约束',
    '必须',
    '禁止',
    '不得',
    '不能',
    '仅能',
    '严禁',
  ])) {
    result.add('constraints');
  }
  if (hasAny(const [
    'open item',
    'open:',
    'todo',
    'remaining',
    'next step',
    'not yet',
    '待办',
    '剩余',
    '下一步',
    '未完成',
    '尚未',
    '仍需',
  ])) {
    result.add('openItems');
  }
  return result;
}

Set<String> _semanticAnchors(String source) {
  final lower = source.toLowerCase();
  final anchors = <String>{};
  final ignored = <String>{
    'goal',
    'goals',
    'objective',
    'current',
    'state',
    'status',
    'progress',
    'decision',
    'decided',
    'constraint',
    'open',
    'item',
    'items',
    'todo',
    'must',
    'should',
    'with',
    'that',
    'this',
    'from',
    'into',
    'only',
    '目标',
    '目的',
    '当前',
    '状态',
    '进度',
    '决定',
    '选择',
    '约束',
    '必须',
    '禁止',
    '不得',
    '不能',
    '待办',
    '剩余',
    '下一步',
    '未完成',
  };
  for (final match in RegExp(
    r'[a-z0-9][a-z0-9_-]{2,}',
    unicode: true,
  ).allMatches(lower)) {
    final token = match.group(0)!;
    if (!ignored.contains(token)) {
      anchors.add(token);
    }
  }
  for (final match in RegExp(
    r'[\u3400-\u9fff]{2,}',
    unicode: true,
  ).allMatches(lower)) {
    final runes = match.group(0)!.runes.toList();
    for (var index = 0; index + 1 < runes.length; index++) {
      final token = String.fromCharCodes(runes.sublist(index, index + 2));
      if (!ignored.contains(token)) {
        anchors.add(token);
      }
    }
  }
  return anchors;
}

String _truncateUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) {
    return value;
  }
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final fragment = String.fromCharCode(rune);
    final size = utf8.encode(fragment).length;
    if (used + size > maxBytes) {
      break;
    }
    buffer.write(fragment);
    used += size;
  }
  return buffer.toString();
}

/// Parse a distiller agent response into a [DistillationPackage].
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

  // Prefer a fenced JSON block when present.
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
    final map = Map<String, dynamic>.from(decoded);
    return DistillationPackage(
      objective: _string(map['objective']),
      currentState: _string(map['currentState']),
      decisions: _stringList(map['decisions']),
      constraints: _stringList(map['constraints']),
      openItems: _stringList(map['openItems']),
      sourceSessionId: _string(
        map['sourceSessionId'],
        fallback: sourceSessionId,
      ),
      sourceAgentId: _string(map['sourceAgentId'], fallback: sourceAgentId),
      createdAt: _string(map['createdAt'], fallback: createdAt),
    );
  } on FormatException {
    return null;
  }
}

bool _sectionNonEmpty(DistillationPackage package, String section) {
  final json = package.toJson()[section];
  if (json is String) {
    return json.trim().isNotEmpty;
  }
  if (json is List) {
    return json.any((e) => e.toString().trim().isNotEmpty);
  }
  return false;
}

String? _extractJsonObject(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  return text.substring(start, end + 1);
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = value.toString().trim();
  return text.isEmpty ? fallback : text;
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    if (value is String && value.trim().isNotEmpty) {
      return [value.trim()];
    }
    return const [];
  }
  return [
    for (final item in value)
      if (item.toString().trim().isNotEmpty) item.toString().trim(),
  ];
}
