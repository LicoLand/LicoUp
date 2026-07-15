import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Builds distillation prompts from policy config and conversation references.
class DistillationPromptBuilder {
  const DistillationPromptBuilder();

  /// Primary distillation prompt. Includes conversation turns and the
  /// required JSON schema. Does not embed secrets.
  String build({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    RoutingFidelityContract? contract,
    Set<String> preserveFields = const {},
    DistillationInputWindow? inputWindow,
    bool corrective = false,
    List<String> missingSections = const [],
  }) {
    final effectiveContract = contract ?? policy.distillation.fidelityContract;
    final sections = effectiveContract.requiredSections.join(', ');
    final buffer = StringBuffer();

    if (corrective) {
      buffer.writeln(
        'CORRECTIVE: Your previous handoff package failed the fidelity check.',
      );
      if (missingSections.isNotEmpty) {
        buffer.writeln(
          'Missing or empty required sections: ${missingSections.join(', ')}.',
        );
      }
      buffer.writeln(
        'Return a complete JSON handoff package that fills every required section.',
      );
      buffer.writeln();
    } else {
      buffer.writeln(
        'Distill the following conversation into a handoff package for the next agent.',
      );
      buffer.writeln(
        'Preserve goals, decisions, and constraints. Do not invent facts.',
      );
      buffer.writeln();
    }

    buffer.writeln('Required JSON fields: $sections.');
    buffer.writeln(
      'Also include sourceSessionId and sourceAgentId when known.',
    );
    buffer.writeln(
      'Max package length: ${effectiveContract.maxPackageLength} characters.',
    );
    if (preserveFields.isNotEmpty) {
      buffer.writeln(
        'Policy-preserved fields: ${(preserveFields.toList()..sort()).join(', ')}.',
      );
    }
    if (inputWindow != null) {
      buffer.writeln(
        'Bounded source window: ${inputWindow.turns.length}/${inputWindow.sourceTurnCount} turns, '
        '${inputWindow.byteCount}/$distillationInputMaxBytes UTF-8 bytes, '
        '${inputWindow.approxTokenCount}/$distillationInputMaxApproxTokens approximate tokens.',
      );
    }
    buffer.writeln();
    buffer.writeln('Source session: ${request.sourceSessionId}');
    buffer.writeln('Source agent: ${request.sourceAgentId}');
    if (request.targetAgentId.trim().isNotEmpty) {
      buffer.writeln('Target agent: ${request.targetAgentId}');
    }
    buffer.writeln();
    buffer.writeln('Conversation:');
    for (final turn in request.turns) {
      buffer.writeln('- ${turn.role}: ${turn.text}');
    }
    buffer.writeln();
    buffer.writeln('Respond with a single JSON object only.');
    return buffer.toString();
  }
}
