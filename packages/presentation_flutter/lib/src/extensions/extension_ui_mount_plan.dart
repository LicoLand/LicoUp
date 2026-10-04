/// The native resource mount plan, as the host interface reads it.
///
/// The document is produced by the native resource lifecycle from the typed
/// resources an installed package generation carries, and it is the only way a
/// package changes what this client renders. It carries data only: bindings,
/// contribution identities, primitive and action names, and plain token values.
/// There is no field for a widget, a builder, a callback, a script or a core
/// client object, and unknown fields are refused so a producer cannot smuggle a
/// second meaning past the interface contract.
///
/// The parser accepts either the wire encoding ([NativeMountPlan.fromJson],
/// which the native side writes) or an already-decoded map
/// ([NativeMountPlan.fromDecoded]), so a host that reads the document from a
/// binding and a host that reads it from storage agree on one shape.
library;

import 'dart:convert';

import 'package:presentation_contract/presentation_contract.dart';

/// The document generation this interface compiles a reader for.
const String nativeMountPlanFormat = 'licoup.client.mount-plan.v1';

/// The document version this interface compiles a reader for.
const int nativeMountPlanVersion = 1;

/// Identity of one contribution the native host decided to mount.
///
/// The values stay separate: a package version can produce several instances,
/// one instance runs one generation, and the plan revision is the committed
/// epoch these contributions were read from. This is interface lifetime data
/// only; instance lifecycle and authority stay with their native owner.
final class NativeMountContribution {
  NativeMountContribution({
    required this.id,
    required this.primitive,
    Iterable<String> regions = const <String>[],
    this.resourceId,
    this.resourceFormat,
    this.actionRef,
    this.instanceId,
    this.packageId,
    this.generation,
    Map<String, Object?> inputs = const <String, Object?>{},
  }) : regions = List<String>.unmodifiable(regions),
       inputs = Map<String, Object?>.unmodifiable(inputs);

  /// Namespaced contribution identity.
  final String id;

  final DeclarativePrimitive primitive;

  /// Region ids the contribution occupies, in declaration order.
  final List<String> regions;

  /// The resource this contribution reads, when the host bound one.
  final String? resourceId;

  /// The bounded pure-data format a resource view renders.
  final String? resourceFormat;

  /// The host-registered action this contribution may invoke.
  final String? actionRef;

  final String? instanceId;
  final String? packageId;
  final int? generation;

  /// Plain immutable values the primitive renders; never code, never a widget.
  final Map<String, Object?> inputs;

  /// The mount identity this contribution carries within one plan revision.
  ///
  /// A newer generation is a different interface, so a keyed result or a widget
  /// state from the previous generation cannot carry over.
  String identityAt(int planRevision) =>
      '$id@${instanceId ?? '-'}/${generation ?? 0}#$planRevision';

  @override
  String toString() =>
      'NativeMountContribution($id, ${primitive.name}, ${regions.length} regions)';
}

/// One committed native mount plan.
///
/// [revision] advances whenever the native host publishes a new binding set, so
/// re-delivering the same revision is a no-op rather than a teardown.
final class NativeMountPlan {
  NativeMountPlan({
    required this.revision,
    required Iterable<DeclarativePrimitive> hostPrimitives,
    required Iterable<String> hostActions,
    required Iterable<MountedResourceBinding> bindings,
    Iterable<NativeMountContribution> contributions = const [],
    Iterable<ResourceFallback> fallbacks = const [],
    Map<String, String> themeTokens = const <String, String>{},
    Set<String> servedProfiles = const <String>{},
  }) : hostPrimitives = Set<DeclarativePrimitive>.unmodifiable(hostPrimitives),
       hostActions = Set<String>.unmodifiable(hostActions),
       bindings = List<MountedResourceBinding>.unmodifiable(bindings),
       contributions = List<NativeMountContribution>.unmodifiable(
         contributions,
       ),
       fallbacks = List<ResourceFallback>.unmodifiable(fallbacks),
       themeTokens = Map<String, String>.unmodifiable(themeTokens),
       servedProfiles = Set<String>.unmodifiable(servedProfiles);

  /// The plan the host renders before any package generation is published.
  ///
  /// Every kind answers with its declared default, and nothing is contributed.
  /// It is a real published state, not an absence a reader has to interpret.
  static NativeMountPlan empty({Map<String, String> themeTokens = const {}}) =>
      NativeMountPlan(
        revision: 1,
        hostPrimitives: DeclarativePrimitive.values,
        hostActions: const <String>[],
        bindings: MountedResourceKind.values.map(
          (kind) => MountedResourceBinding.defaulted(
            kind: kind,
            system: mountedSystemDefaults[kind]!,
          ),
        ),
        themeTokens: themeTokens,
      );

  /// The native host's published plan revision.
  final int revision;

  /// The primitives this host build compiled a renderer for.
  ///
  /// A contribution naming anything outside this set is refused; the plan's own
  /// vocabulary never widens it.
  final Set<DeclarativePrimitive> hostPrimitives;

  /// The action names this host build registered.
  final Set<String> hostActions;

  /// What each resource kind currently serves, in publication order.
  final List<MountedResourceBinding> bindings;

  /// The contributions this plan would mount, before host registration.
  final List<NativeMountContribution> contributions;

  /// Recorded fallbacks, for kinds no longer serving their selected resource.
  final List<ResourceFallback> fallbacks;

  /// Token roles and values of the theme this plan serves, when it serves one.
  final Map<String, String> themeTokens;

  /// Profile ids this host serves at this revision.
  final Set<String> servedProfiles;

  /// What one kind currently serves, or its declared default when the document
  /// does not publish that kind.
  MountedResourceBinding bindingFor(MountedResourceKind kind) {
    for (final binding in bindings) {
      if (binding.kind == kind) return binding;
    }
    return MountedResourceBinding.defaulted(
      kind: kind,
      system: mountedSystemDefaults[kind]!,
    );
  }

  /// The recorded fallback of one kind, when that kind fell back.
  ResourceFallback? fallbackFor(MountedResourceKind kind) {
    for (final fallback in fallbacks) {
      if (fallback.kind == kind) return fallback;
    }
    return null;
  }

  /// Decodes one JSON document, refusing anything this reader does not own.
  factory NativeMountPlan.fromJson(String source) =>
      NativeMountPlan.fromDecoded(decodeNativeMountPlan(source));

  /// Decodes one already-parsed document, refusing anything this reader does
  /// not own.
  factory NativeMountPlan.fromDecoded(Map<String, Object?> json) {
    final format = json['format'];
    if (format != nativeMountPlanFormat) {
      throw NativeMountPlanFormatException(
        'mount_plan_format_unknown',
        'format',
      );
    }
    final version = json['version'];
    if (version != nativeMountPlanVersion) {
      throw NativeMountPlanFormatException(
        'mount_plan_version_unknown',
        'version',
      );
    }
    for (final key in json.keys) {
      if (!_documentFields.contains(key)) {
        throw NativeMountPlanFormatException('mount_plan_field_unknown', key);
      }
    }
    final revision = json['revision'];
    if (revision is! int || revision < 1) {
      throw const NativeMountPlanFormatException(
        'mount_plan_revision_invalid',
        'revision',
      );
    }
    final primitives = <DeclarativePrimitive>[];
    for (final entry in _stringList(json['hostPrimitives'], 'hostPrimitives')) {
      final primitive = declarativePrimitiveByName(entry);
      if (primitive == null) {
        throw NativeMountPlanFormatException(
          'mount_plan_primitive_unknown',
          'hostPrimitives',
        );
      }
      if (!primitives.contains(primitive)) primitives.add(primitive);
    }
    final actions = <String>[];
    for (final entry in _stringList(json['hostActions'], 'hostActions')) {
      if (!actions.contains(entry)) actions.add(entry);
    }
    final bindings = <MountedResourceBinding>[];
    final rawBindings = json['bindings'];
    if (rawBindings is! List) {
      throw const NativeMountPlanFormatException(
        'mount_plan_bindings_invalid',
        'bindings',
      );
    }
    for (var index = 0; index < rawBindings.length; index++) {
      final raw = rawBindings[index];
      if (raw is! Map) {
        throw const NativeMountPlanFormatException(
          'mount_plan_binding_invalid',
          'bindings',
        );
      }
      final MountedResourceBinding binding;
      try {
        binding = MountedResourceBinding.fromWire(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
      } on FormatException {
        // The binding contract's own refusal is this document's refusal: a kind
        // that cannot say what it serves reaches no renderer.
        throw const NativeMountPlanFormatException(
          'mount_plan_binding_invalid',
          'bindings',
        );
      }
      if (bindings.any((existing) => existing.kind == binding.kind)) {
        throw const NativeMountPlanFormatException(
          'mount_plan_binding_invalid',
          'bindings',
        );
      }
      bindings.add(binding);
    }
    final fallbacks = <ResourceFallback>[];
    for (final raw in _objectList(json['fallbacks'], 'fallbacks')) {
      final kind = mountedResourceKindByName(raw['kind']);
      final reason = resourceFallbackReasonByName(raw['reason']);
      final resourceId = raw['resourceId'];
      final packageId = raw['packageId'];
      if (kind == null ||
          reason == null ||
          resourceId is! String ||
          resourceId.isEmpty ||
          packageId is! String ||
          packageId.isEmpty) {
        throw const NativeMountPlanFormatException(
          'mount_plan_fallback_invalid',
          'fallbacks',
        );
      }
      fallbacks.add(
        ResourceFallback(
          kind: kind,
          resourceId: resourceId,
          packageId: packageId,
          reason: reason,
        ),
      );
    }
    final tokens = <String, String>{};
    final rawTokens = json['themeTokens'];
    if (rawTokens != null) {
      if (rawTokens is! Map) {
        throw const NativeMountPlanFormatException(
          'mount_plan_tokens_invalid',
          'themeTokens',
        );
      }
      for (final entry in rawTokens.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || key.isEmpty || value is! String) {
          throw const NativeMountPlanFormatException(
            'mount_plan_tokens_invalid',
            'themeTokens',
          );
        }
        tokens[key] = value;
      }
    }
    final contributions = <NativeMountContribution>[];
    for (final raw in _objectList(json['contributions'], 'contributions')) {
      contributions.add(_contribution(raw));
    }
    // A kind either serves a resource or has fallen back, never both: the two
    // records would contradict each other, and a reader must not choose one.
    for (final fallback in fallbacks) {
      final binding = bindings
          .where((candidate) => candidate.kind == fallback.kind)
          .firstOrNull;
      if (binding != null && !binding.isDefault) {
        throw const NativeMountPlanFormatException(
          'mount_plan_binding_conflict',
          'fallbacks',
        );
      }
    }
    return NativeMountPlan(
      revision: revision,
      hostPrimitives: primitives,
      hostActions: actions,
      bindings: bindings,
      contributions: contributions,
      fallbacks: fallbacks,
      themeTokens: tokens,
      servedProfiles: _stringList(
        json['servedProfiles'],
        'servedProfiles',
      ).toSet(),
    );
  }

  /// The wire form of this document, as the native host publishes it.
  Map<String, Object?> toDecoded() => <String, Object?>{
    'format': nativeMountPlanFormat,
    'version': nativeMountPlanVersion,
    'revision': revision,
    'servedProfiles': servedProfiles.toList()..sort(),
    'hostPrimitives': hostPrimitives.map((entry) => entry.name).toList()
      ..sort(),
    'hostActions': hostActions.toList()..sort(),
    'bindings': bindings.map((binding) => binding.toWire()).toList(),
    if (fallbacks.isNotEmpty)
      'fallbacks': fallbacks
          .map(
            (fallback) => <String, Object?>{
              'kind': fallback.kind.name,
              'resourceId': fallback.resourceId,
              'packageId': fallback.packageId,
              'reason': fallback.reason.name,
            },
          )
          .toList(),
    if (themeTokens.isNotEmpty) 'themeTokens': themeTokens,
    'contributions': contributions
        .map(
          (entry) => <String, Object?>{
            'id': entry.id,
            'primitive': entry.primitive.name,
            if (entry.regions.isNotEmpty) 'regions': entry.regions,
            if (entry.resourceId != null) 'resourceId': entry.resourceId,
            if (entry.resourceFormat != null)
              'resourceFormat': entry.resourceFormat,
            if (entry.actionRef != null) 'actionRef': entry.actionRef,
            if (entry.instanceId != null) 'instanceId': entry.instanceId,
            if (entry.packageId != null) 'packageId': entry.packageId,
            if (entry.generation != null) 'generation': entry.generation,
            if (entry.inputs.isNotEmpty) 'inputs': entry.inputs,
          },
        )
        .toList(),
  };

  @override
  String toString() =>
      'NativeMountPlan(revision $revision, ${bindings.length} bindings, '
      '${contributions.length} contributions)';
}

const Set<String> _documentFields = {
  'format',
  'version',
  'revision',
  'servedProfiles',
  'hostPrimitives',
  'hostActions',
  'bindings',
  'fallbacks',
  'themeTokens',
  'contributions',
};

NativeMountContribution _contribution(Map<String, Object?> raw) {
  final id = raw['id'];
  if (id is! String || id.isEmpty) {
    throw const NativeMountPlanFormatException(
      'mount_plan_contribution_invalid',
      'contributions.id',
    );
  }
  // A plan document has nowhere to put code or a host object, and the reader
  // refuses an unknown member rather than ignoring it.
  for (final key in raw.keys) {
    if (!_contributionFields.contains(key)) {
      throw NativeMountPlanFormatException(
        'mount_plan_contribution_invalid',
        'contributions.$id.$key',
      );
    }
  }
  final primitive = declarativePrimitiveByName(raw['primitive']);
  if (primitive == null) {
    throw NativeMountPlanFormatException(
      'mount_plan_primitive_unknown',
      'contributions.$id.primitive',
    );
  }
  final resourceId = _optionalString(raw['resourceId']);
  final actionRef = _optionalString(raw['actionRef']);
  final resourceFormat = _optionalString(raw['resourceFormat']);
  final generation = raw['generation'];
  if (generation != null && (generation is! int || generation < 1)) {
    throw NativeMountPlanFormatException(
      'mount_plan_contribution_invalid',
      'contributions.$id.generation',
    );
  }
  return NativeMountContribution(
    id: id,
    primitive: primitive,
    regions: _stringList(raw['regions'], 'contributions.$id.regions'),
    resourceId: resourceId,
    resourceFormat: resourceFormat,
    actionRef: actionRef,
    instanceId: _optionalString(raw['instanceId']),
    packageId: _optionalString(raw['packageId']),
    generation: generation as int?,
    inputs: _inputs(raw['inputs'], 'contributions.$id.inputs'),
  );
}

const Set<String> _contributionFields = {
  'id',
  'primitive',
  'regions',
  'resourceId',
  'resourceFormat',
  'actionRef',
  'instanceId',
  'packageId',
  'generation',
  'inputs',
};

/// The plain values one primitive renders.
///
/// Only bounded JSON values are accepted. A nested document that could carry
/// code, a widget or a host object has no representation here, so an attempt to
/// smuggle one is refused at the document boundary rather than ignored.
Map<String, Object?> _inputs(Object? value, String field) {
  if (value == null) return const <String, Object?>{};
  if (value is! Map) {
    throw NativeMountPlanFormatException('mount_plan_inputs_invalid', field);
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String || key.isEmpty) {
      throw NativeMountPlanFormatException('mount_plan_inputs_invalid', field);
    }
    result[key] = _boundedValue(entry.value, field);
  }
  return result;
}

Object? _boundedValue(Object? value, String field) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return <Object?>[for (final entry in value) _boundedValue(entry, field)];
  }
  if (value is Map) {
    final nested = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.isEmpty) {
        throw NativeMountPlanFormatException(
          'mount_plan_inputs_invalid',
          field,
        );
      }
      nested[key] = _boundedValue(entry.value, field);
    }
    return nested;
  }
  throw NativeMountPlanFormatException('mount_plan_inputs_invalid', field);
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw const NativeMountPlanFormatException(
      'mount_plan_contribution_invalid',
      'value',
    );
  }
  return value;
}

List<String> _stringList(Object? value, String field) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw NativeMountPlanFormatException('mount_plan_field_invalid', field);
  }
  final result = <String>[];
  for (final entry in value) {
    if (entry is! String || entry.isEmpty) {
      throw NativeMountPlanFormatException('mount_plan_field_invalid', field);
    }
    result.add(entry);
  }
  return result;
}

List<Map<String, Object?>> _objectList(Object? value, String field) {
  if (value == null) return const <Map<String, Object?>>[];
  if (value is! List) {
    throw NativeMountPlanFormatException('mount_plan_field_invalid', field);
  }
  final result = <Map<String, Object?>>[];
  for (final entry in value) {
    if (entry is! Map) {
      throw NativeMountPlanFormatException('mount_plan_field_invalid', field);
    }
    result.add(entry.map((key, value) => MapEntry(key.toString(), value)));
  }
  return result;
}

/// Decodes one mount plan document from its JSON encoding.
///
/// A document that is not a JSON object is refused before any field is read, so
/// a reader never interprets a partial plan.
Map<String, Object?> decodeNativeMountPlan(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw const NativeMountPlanFormatException(
      'mount_plan_document_invalid',
      'document',
    );
  }
  if (decoded is! Map) {
    throw const NativeMountPlanFormatException(
      'mount_plan_document_invalid',
      'document',
    );
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

/// A mount plan this reader cannot own, with the field that decided it.
///
/// The code is stable and is what a host reports; the field names the document
/// member, so a producer learns which declaration is wrong without a stack.
final class NativeMountPlanFormatException implements Exception {
  const NativeMountPlanFormatException(this.code, this.field);

  final String code;
  final String field;

  @override
  String toString() => 'NativeMountPlanFormatException($code, $field)';
}
