import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';

final class AdaptiveFlywheelController extends ApplicationStateOwner {
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
    await _inspectSelectedOrClear();
  });

  Future<void> refresh() => _guard(() async {
    await _refreshCatalog();
    await _inspectSelectedOrClear();
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
    Map<String, List<AdaptiveFlywheelBinding>> bindings,
  ) => _guard(() async {
    final inspection = _inspection;
    if (inspection == null) return;
    for (final slot in inspection.slots.where((slot) => slot.kind == 'actor')) {
      final current = inspection.bindings[slot.id] ?? const [];
      final next = bindings[slot.id] ?? const [];
      if (next.isEmpty) {
        if (current.isNotEmpty) {
          await _gateway.execute({
            'action': 'strategy.binding.remove',
            'revisionDigest': _selectedRevision,
            'slotId': slot.id,
            if (current.first.revision > 0)
              'expectedRevision': current.first.revision,
          });
        }
        continue;
      }
      if (_sameBindingChain(current, next)) continue;
      await _gateway.execute({
        'action': 'strategy.binding.replace',
        'revisionDigest': _selectedRevision,
        'slotId': slot.id,
        'candidates': [
          for (final binding in next)
            {
              'valueId': binding.valueId,
              'model': binding.model,
              'reasoningEffort': binding.reasoningEffort,
            },
        ],
        if (current.isNotEmpty && current.first.revision > 0)
          'expectedRevision': current.first.revision,
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
    if (_definitions.every(
      (definition) => definition.revisionDigest != _selectedRevision,
    )) {
      _selectedRevision = _definitions.isEmpty
          ? ''
          : _definitions.first.revisionDigest;
    }
  }

  Future<void> _inspectSelectedOrClear() async {
    if (_selectedRevision.isEmpty) {
      _inspection = null;
      return;
    }
    try {
      await _inspect();
    } catch (_) {
      _inspection = null;
      if (_definitions.isEmpty) {
        _selectedRevision = '';
        return;
      }
      rethrow;
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
    publishChange();
    try {
      await operation();
    } on AdaptiveFlywheelFailure catch (failure) {
      _error = failure.toString();
    } catch (_) {
      _error = 'Adaptive Flywheel operation failed.';
    } finally {
      _busy = false;
      publishChange();
    }
  }
}

bool _sameBindingChain(
  List<AdaptiveFlywheelBinding> current,
  List<AdaptiveFlywheelBinding> next,
) {
  if (current.length != next.length) return false;
  for (var index = 0; index < current.length; index += 1) {
    if (current[index].valueId != next[index].valueId ||
        current[index].model != next[index].model ||
        current[index].reasoningEffort != next[index].reasoningEffort) {
      return false;
    }
  }
  return true;
}
