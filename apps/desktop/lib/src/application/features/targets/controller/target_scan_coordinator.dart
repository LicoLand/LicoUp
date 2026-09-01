import 'package:licoup/src/contracts/target_management.dart';

/// Immutable identity for one native target scan.
///
/// Target order is retained for the first execution, while identity uses the
/// normalized target set because native batch results are reduced by target
/// id rather than by response position.
final class TargetScanRequest {
  factory TargetScanRequest({
    required Iterable<String> targetIds,
    bool enableAgentCliModelLookup = false,
  }) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final targetId in targetIds) {
      final id = targetId.trim();
      if (id.isNotEmpty && seen.add(id)) normalized.add(id);
    }
    final identity = List<String>.from(normalized)..sort();
    return TargetScanRequest._(
      targetIds: List.unmodifiable(normalized),
      identityTargetIds: List.unmodifiable(identity),
      enableAgentCliModelLookup: enableAgentCliModelLookup,
    );
  }

  const TargetScanRequest._({
    required this.targetIds,
    required List<String> identityTargetIds,
    required this.enableAgentCliModelLookup,
  }) : _identityTargetIds = identityTargetIds;

  final List<String> targetIds;
  final List<String> _identityTargetIds;
  final bool enableAgentCliModelLookup;

  bool get isEmpty => targetIds.isEmpty;

  @override
  bool operator ==(Object other) {
    return other is TargetScanRequest &&
        enableAgentCliModelLookup == other.enableAgentCliModelLookup &&
        _sameIds(_identityTargetIds, other._identityTargetIds);
  }

  @override
  int get hashCode => Object.hash(
    enableAgentCliModelLookup,
    Object.hashAll(_identityTargetIds),
  );
}

/// SingleFlight coordinator for native target discovery.
///
/// Only equivalent requests coalesce. Completed results are never cached, and
/// distinct target sets or scan options remain independently concurrent.
final class TargetScanCoordinator {
  TargetScanCoordinator(this._gateway);

  final TargetManagementGateway _gateway;
  final Map<TargetScanRequest, Future<TargetScanBatch>> _inFlight = {};

  Future<TargetScanBatch> scan(TargetScanRequest request) {
    if (request.isEmpty) return Future.value(const TargetScanBatch([]));
    final active = _inFlight[request];
    if (active != null) return active;

    late final Future<TargetScanBatch> flight;
    flight =
        Future.sync(
          () => _gateway.scanTargetsBatch(
            request.targetIds,
            enableAgentCliModelLookup: request.enableAgentCliModelLookup,
          ),
        ).whenComplete(() {
          if (identical(_inFlight[request], flight)) {
            _inFlight.remove(request);
          }
        });
    _inFlight[request] = flight;
    return flight;
  }
}

bool _sameIds(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
