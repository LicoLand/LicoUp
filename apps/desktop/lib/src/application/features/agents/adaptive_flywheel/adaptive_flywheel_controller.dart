import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';

final class AdaptiveFlywheelController extends ChangeNotifier {
  AdaptiveFlywheelController({required AdaptiveFlywheelGateway gateway})
    : _gateway = gateway;

  final AdaptiveFlywheelGateway _gateway;

  bool _busy = false;
  String _error = '';
  String _selectedRevision = '';
  List<AdaptiveFlywheelDefinition> _definitions = const [];
  AdaptiveFlywheelInspection? _inspection;

  bool get busy => _busy;
  String get error => _error;
  String get selectedRevision => _selectedRevision;
  List<AdaptiveFlywheelDefinition> get definitions => _definitions;
  AdaptiveFlywheelInspection? get inspection => _inspection;

  Future<void> initialize() => _guard(() async {
    await _refreshCatalog();
    if (_selectedRevision.isNotEmpty) {
      await _inspect();
    }
  });

  Future<void> refresh() => _guard(() async {
    await _refreshCatalog();
    if (_selectedRevision.isNotEmpty) {
      await _inspect();
    }
  });

  Future<void> importPackage(String path) => _guard(() async {
    final prepared = adaptiveFlywheelStringMap(
      await _gateway.execute({
        'action': 'strategy.package.prepare-import',
        'sourcePath': path,
        'selectionToken': 'selection-${DateTime.now().microsecondsSinceEpoch}',
      }),
    );
    final committed = adaptiveFlywheelStringMap(
      await _gateway.execute({
        'action': 'strategy.package.commit-import',
        'preparationId': prepared['preparationId'],
        'expectedRevisionDigest': prepared['revisionDigest'],
      }),
    );
    _selectedRevision = (committed['revisionDigest'] ?? '').toString();
    await _refreshCatalog();
    await _inspect();
  });

  Future<void> selectDefinition(String revision) => _guard(() async {
    _selectedRevision = revision;
    await _inspect();
  });

  Future<void> saveActorBindings(
    Map<String, AdaptiveFlywheelBinding> bindings,
  ) => _guard(() async {
    final inspection = _inspection;
    if (inspection == null) return;
    for (final slot in inspection.slots.where((slot) => slot.kind == 'actor')) {
      final current = inspection.bindings[slot.id];
      final next = bindings[slot.id];
      if (next == null || next.valueId.trim().isEmpty) {
        if (current != null) {
          await _gateway.execute({
            'action': 'strategy.binding.remove',
            'revisionDigest': _selectedRevision,
            'slotId': slot.id,
            'expectedRevision': current.revision,
          });
        }
        continue;
      }
      if (current?.valueId == next.valueId &&
          current?.model == next.model &&
          current?.reasoningEffort == next.reasoningEffort) {
        continue;
      }
      await _gateway.execute({
        'action': 'strategy.binding.update',
        'revisionDigest': _selectedRevision,
        'slotId': slot.id,
        'valueId': next.valueId,
        'model': next.model,
        'reasoningEffort': next.reasoningEffort,
        if (current != null) 'expectedRevision': current.revision,
      });
    }
    await _inspect();
    if (!_inspection!.allowedOperations.contains(
      'strategy.authorization.grant',
    )) {
      return;
    }
    final preview = adaptiveFlywheelStringMap(
      await _gateway.execute({
        'action': 'strategy.authorization.preview',
        'revisionDigest': _selectedRevision,
      }),
    );
    await _gateway.execute({
      'action': 'strategy.authorization.grant',
      'revisionDigest': _selectedRevision,
      'authorizationDigest': preview['authorizationDigest'],
      'confirmed': true,
    });
    await _inspect();
  });

  Future<void> _refreshCatalog() async {
    final definitions = adaptiveFlywheelMaps(
      await _gateway.execute({'action': 'strategy.definition.list'}),
    );
    _definitions = definitions
        .map(AdaptiveFlywheelDefinition.fromJson)
        .toList(growable: false);
    if (_selectedRevision.isEmpty && _definitions.isNotEmpty) {
      _selectedRevision = _definitions.first.revisionDigest;
    }
  }

  Future<void> _inspect() async {
    if (_selectedRevision.isEmpty) {
      _inspection = null;
      return;
    }
    final value = adaptiveFlywheelStringMap(
      await _gateway.execute({
        'action': 'strategy.definition.inspect',
        'revisionDigest': _selectedRevision,
      }),
    );
    _inspection = AdaptiveFlywheelInspection.fromJson(value);
  }

  Future<void> _guard(Future<void> Function() operation) async {
    if (_busy) return;
    _busy = true;
    _error = '';
    notifyListeners();
    try {
      await operation();
    } on AdaptiveFlywheelFailure catch (failure) {
      _error = failure.toString();
    } catch (_) {
      _error = 'Adaptive Flywheel operation failed.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
