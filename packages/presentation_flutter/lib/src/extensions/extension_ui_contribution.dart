/// C13: one declarative interface contribution, as data.
///
/// A contribution names what it adds (settings, command, navigation, metric
/// panel, resource view), the resource the host prepares and hands back, the
/// action the host may invoke, and the least profile it needs. It has no place
/// for code, a widget tree, a provider, an RPC handle or a secret: unknown
/// fields are refused at the wire boundary, and [ExtensionUiContribution.refusal]
/// mirrors the host's own validation so one contribution that cannot be mounted
/// fails alone.
///
/// The shapes here mirror `schemas/extensions/ui.schema.json` and the native
/// `licoup-extension-contracts` planner. The host still re-checks them: the
/// client renders the data, so a malformed contribution must be refused before
/// it reaches a primitive, not after.
library;

import 'package:presentation_contract/presentation_contract.dart';

/// Wire schema id of one interface contribution.
const String extensionUiContributionSchema = 'licoup.ui-contribution.v1';

/// The versioned prepared graph resource view this shell compiles a renderer
/// for.
///
/// A `resource-view` contribution names a format; the shell mounts it only
/// when it has a renderer for that format, and an unknown format keeps the
/// contribution preserved while every other contribution mounts unchanged.
const String extensionUiGraphResourceFormat = graphResourceV1Schema;

/// Resource-view formats this shell build compiles a renderer for.
const Set<String> extensionUiResourceViewFormats = <String>{
  extensionUiGraphResourceFormat,
};

/// The longest namespaced name accepted, matching the native bound.
const int extensionUiMaxNamespacedNameBytes = 160;

/// Why one contribution cannot be accepted, and which field caused it.
final class ExtensionUiRefusal {
  const ExtensionUiRefusal(this.code, {this.field});

  /// Stable refusal code, such as `ui_contribution_invalid`.
  final String code;

  /// The offending field, when the refusal names one.
  final String? field;

  @override
  String toString() => field == null ? code : '$code($field)';
}

/// What a contribution adds to the interface.
enum ExtensionContributionKind {
  settings('settings'),
  command('command'),
  navigation('navigation'),
  metricPanel('metric-panel'),
  resourceView('resource-view');

  const ExtensionContributionKind(this.wireName);

  /// The name the wire schema uses.
  final String wireName;

  static ExtensionContributionKind? fromWireName(String name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }
}

/// The kind of value one form field holds.
enum ExtensionFieldType {
  text('text'),
  number('number'),
  boolean('boolean'),
  select('select'),

  /// A value the host collects in its own control and stores as a credential
  /// handle. A contribution never sees the secret, and the wire schema refuses
  /// a `secret-ref` field that carries a value.
  secretRef('secret-ref');

  const ExtensionFieldType(this.wireName);

  final String wireName;

  static ExtensionFieldType? fromWireName(String name) {
    for (final type in values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// The profiles this host build publishes.
///
/// A `requiredProfile` id outside this set belongs to a newer host: it is
/// preserved and the contribution is not mounted.
const Set<String> extensionUiPublishedProfiles = <String>{
  'agent-execution',
  'model-provider',
  'usage-metric',
  'package-deployment',
  'declarative-ui',
};

/// Whether [name] is a namespaced extension name, such as `vendor.example/render`.
///
/// The rule is the one the extension schemas publish: two lowercase segments
/// separated by `.` or `-`, optionally followed by `.`/`-`/`/`-separated leaves
/// that may keep uppercase letters. A bare word is not namespaced, so no vendor
/// can claim a name the product itself publishes.
bool isExtensionUiNamespacedName(String name) {
  if (name.isEmpty || name.length > extensionUiMaxNamespacedNameBytes) {
    return false;
  }
  return RegExp(
    r'^[a-z0-9]+(?:[.-][a-z0-9]+)(?:[./-][A-Za-z0-9_-]+)*$',
  ).hasMatch(name);
}

/// One field of a settings form contribution.
final class ExtensionContributionField {
  const ExtensionContributionField({
    required this.id,
    required this.label,
    required this.type,
    this.isRequired = false,
    this.value,
  });

  final String id;
  final String label;
  final ExtensionFieldType type;
  final bool isRequired;

  /// The current value of an ordinary field. Always absent for
  /// [ExtensionFieldType.secretRef].
  final String? value;

  /// The refusal this field would cause, or null when it is acceptable.
  ExtensionUiRefusal? refusal() {
    if (id.isEmpty || label.isEmpty) {
      return const ExtensionUiRefusal(
        'ui_contribution_invalid',
        field: 'fields',
      );
    }
    if (type == ExtensionFieldType.secretRef && value != null) {
      return const ExtensionUiRefusal(
        'ui_secret_inline_refused',
        field: 'fields.value',
      );
    }
    return null;
  }

  static ExtensionContributionField fromJson(Map<String, Object?> json) {
    _refuseUnknownKeys(json, const {
      'id',
      'label',
      'type',
      'required',
      'value',
    }, 'fields');
    final id = _string(json, 'id', 'fields');
    final label = _string(json, 'label', 'fields');
    final typeName = _string(json, 'type', 'fields');
    final type = ExtensionFieldType.fromWireName(typeName);
    if (type == null) {
      throw FormatException('unknown field type: $typeName', json, 0);
    }
    final required = json['required'];
    if (required != null && required is! bool) {
      throw FormatException('field required must be a boolean', json, 0);
    }
    final value = json['value'];
    if (value != null && value is! String) {
      throw FormatException('field value must be a string', json, 0);
    }
    return ExtensionContributionField(
      id: id,
      label: label,
      type: type,
      isRequired: required == true,
      value: value as String?,
    );
  }

  @override
  String toString() => 'ExtensionContributionField($id, ${type.wireName})';
}

/// One series of a metric panel contribution.
///
/// A panel names the standardized metric it draws; it never parses a vendor's
/// files and it never carries a vendor name into the chart.
final class ExtensionMetricSeries {
  const ExtensionMetricSeries({
    required this.metric,
    required this.label,
    required this.unit,
  });

  final String metric;
  final String label;
  final String unit;

  /// The refusal this series would cause, or null when it is acceptable.
  ExtensionUiRefusal? refusal() {
    if (!isExtensionUiNamespacedName(metric) || label.isEmpty || unit.isEmpty) {
      return const ExtensionUiRefusal(
        'ui_contribution_invalid',
        field: 'series',
      );
    }
    return null;
  }

  static ExtensionMetricSeries fromJson(Map<String, Object?> json) {
    _refuseUnknownKeys(json, const {'metric', 'label', 'unit'}, 'series');
    return ExtensionMetricSeries(
      metric: _string(json, 'metric', 'series'),
      label: _string(json, 'label', 'series'),
      unit: _string(json, 'unit', 'series'),
    );
  }

  @override
  String toString() => 'ExtensionMetricSeries($metric, $unit)';
}

/// One interface contribution.
final class ExtensionUiContribution {
  const ExtensionUiContribution({
    required this.schema,
    required this.id,
    required this.kind,
    required this.title,
    this.requiredProfile,
    this.resourceRef,
    this.actionRef,
    this.resourceFormat,
    this.fields = const <ExtensionContributionField>[],
    this.series = const <ExtensionMetricSeries>[],
  });

  final String schema;
  final String id;
  final ExtensionContributionKind kind;
  final String title;

  /// The least profile this contribution needs, as a profile id.
  final String? requiredProfile;

  /// The resource the host prepares and hands back.
  final String? resourceRef;

  /// The action this contribution may invoke. The host owns its authority.
  final String? actionRef;

  /// The bounded pure-data format a `resource-view` contribution wants
  /// rendered, such as `licoup.ui.graph-resource.v1`.
  final String? resourceFormat;

  final List<ExtensionContributionField> fields;
  final List<ExtensionMetricSeries> series;

  /// Decodes one contribution, refusing unknown keys and unknown enum names.
  static ExtensionUiContribution fromJson(Map<String, Object?> json) {
    _refuseUnknownKeys(json, const {
      'schema',
      'id',
      'kind',
      'title',
      'requiredProfile',
      'resourceRef',
      'actionRef',
      'resourceFormat',
      'fields',
      'series',
    }, 'contribution');
    final kindName = _string(json, 'kind', 'kind');
    final kind = ExtensionContributionKind.fromWireName(kindName);
    if (kind == null) {
      throw FormatException('unknown contribution kind: $kindName', json, 0);
    }
    final fieldsJson = json['fields'];
    final fields = <ExtensionContributionField>[];
    if (fieldsJson != null) {
      if (fieldsJson is! List) {
        throw FormatException('fields must be a list', json, 0);
      }
      for (final entry in fieldsJson) {
        fields.add(
          ExtensionContributionField.fromJson(_object(entry, 'fields')),
        );
      }
    }
    final seriesJson = json['series'];
    final series = <ExtensionMetricSeries>[];
    if (seriesJson != null) {
      if (seriesJson is! List) {
        throw FormatException('series must be a list', json, 0);
      }
      for (final entry in seriesJson) {
        series.add(ExtensionMetricSeries.fromJson(_object(entry, 'series')));
      }
    }
    return ExtensionUiContribution(
      schema: _string(json, 'schema', 'schema'),
      id: _string(json, 'id', 'id'),
      kind: kind,
      title: _string(json, 'title', 'title'),
      requiredProfile: _optionalString(json, 'requiredProfile'),
      resourceRef: _optionalString(json, 'resourceRef'),
      actionRef: _optionalString(json, 'actionRef'),
      resourceFormat: _optionalString(json, 'resourceFormat'),
      fields: List<ExtensionContributionField>.unmodifiable(fields),
      series: List<ExtensionMetricSeries>.unmodifiable(series),
    );
  }

  /// Structural validation. It names the offending field and refuses only this
  /// contribution.
  ExtensionUiRefusal? refusal() {
    if (schema != extensionUiContributionSchema) {
      return const ExtensionUiRefusal(
        'ui_contribution_invalid',
        field: 'schema',
      );
    }
    if (!isExtensionUiNamespacedName(id)) {
      return const ExtensionUiRefusal('ui_contribution_invalid', field: 'id');
    }
    if (title.isEmpty) {
      return const ExtensionUiRefusal(
        'ui_contribution_invalid',
        field: 'title',
      );
    }
    if (kind == ExtensionContributionKind.metricPanel) {
      if (series.isEmpty) {
        return const ExtensionUiRefusal(
          'ui_contribution_invalid',
          field: 'series',
        );
      }
    } else if (series.isNotEmpty) {
      return const ExtensionUiRefusal(
        'ui_contribution_invalid',
        field: 'series',
      );
    }
    if (resourceFormat != null) {
      if (kind != ExtensionContributionKind.resourceView ||
          !isExtensionUiNamespacedName(resourceFormat!)) {
        // A settings form, command, navigation entry or metric panel has no
        // format to render: naming one is a declaration error.
        return const ExtensionUiRefusal(
          'ui_contribution_invalid',
          field: 'resourceFormat',
        );
      }
    }
    for (final field in fields) {
      final refusal = field.refusal();
      if (refusal != null) return refusal;
    }
    for (final entry in series) {
      final refusal = entry.refusal();
      if (refusal != null) return refusal;
    }
    return null;
  }

  @override
  String toString() => 'ExtensionUiContribution($id, ${kind.wireName})';
}

/// What a contribution needs before it can be mounted.
enum ExtensionUiMountRequirement {
  /// It binds only to data the host already has.
  none,

  /// It needs a published profile this host serves.
  served,

  /// It needs a profile id this host does not publish, so it belongs to a newer
  /// host. It is preserved and not mounted.
  unpublished,
}

/// The requirement [contribution] declares, against the profiles this build
/// publishes.
ExtensionUiMountRequirement extensionUiRequirementOf(
  ExtensionUiContribution contribution,
) {
  final profile = contribution.requiredProfile;
  if (profile == null) return ExtensionUiMountRequirement.none;
  return extensionUiPublishedProfiles.contains(profile)
      ? ExtensionUiMountRequirement.served
      : ExtensionUiMountRequirement.unpublished;
}

/// The host primitive one contribution kind binds to.
///
/// These are compiled into the shell. A contribution chooses among them; it
/// does not bring its own, and a capability that needs a genuinely new
/// primitive negotiates a core version instead of shipping one. A resource view
/// does not bind to a widget primitive: it mounts through the renderer
/// registered for its declared resource format.
DeclarativePrimitive? extensionUiPrimitiveFor(ExtensionContributionKind kind) =>
    switch (kind) {
      ExtensionContributionKind.settings => DeclarativePrimitive.form,
      ExtensionContributionKind.command ||
      ExtensionContributionKind.navigation => DeclarativePrimitive.command,
      ExtensionContributionKind.metricPanel => DeclarativePrimitive.chart,
      ExtensionContributionKind.resourceView => null,
    };

/// Why one contribution is not mounted.
enum ExtensionUiMountBlock {
  /// Its own declaration is invalid; the refusal names the field.
  contributionInvalid('contribution_invalid'),

  /// A published profile it needs is not served at this epoch.
  profileNotInstalled('profile_not_installed'),

  /// It needs a profile id this host does not publish.
  profileUnpublished('profile_unpublished'),

  /// The running shell does not provide the primitive it binds to.
  primitiveUnavailable('primitive_unavailable'),

  /// A resource view without a format cannot be rendered at all.
  resourceFormatMissing('resource_format_missing'),

  /// The view names a format this shell does not compile a renderer for. It is
  /// preserved for a newer shell and refused locally.
  resourceFormatUnavailable('resource_format_unavailable');

  const ExtensionUiMountBlock(this.code);

  final String code;
}

/// One contribution and the decision made about it.
final class ExtensionUiMountDecision {
  const ExtensionUiMountDecision({
    required this.contribution,
    this.blocked,
    this.refusal,
  });

  final ExtensionUiContribution contribution;

  /// Null when it mounts; otherwise why it does not.
  final ExtensionUiMountBlock? blocked;

  /// The declaration refusal, when the block is [ExtensionUiMountBlock.contributionInvalid].
  final ExtensionUiRefusal? refusal;

  bool get isMounted => blocked == null;

  @override
  String toString() =>
      'ExtensionUiMountDecision(${contribution.id}, ${blocked?.code ?? 'mounted'})';
}

/// Decide each contribution against the profiles this host serves and the
/// primitives this shell compiles.
///
/// The decision is per contribution. A settings form that needs a profile the
/// host does not serve is not mounted, and every other contribution mounts
/// exactly as before.
List<ExtensionUiMountDecision> planExtensionUiMount(
  Iterable<ExtensionUiContribution> contributions, {
  required Set<String> servedProfiles,
  required Set<DeclarativePrimitive> availablePrimitives,
  Set<String> availableResourceFormats = extensionUiResourceViewFormats,
}) {
  final decisions = <ExtensionUiMountDecision>[];
  for (final contribution in contributions) {
    final refusal = contribution.refusal();
    if (refusal != null) {
      decisions.add(
        ExtensionUiMountDecision(
          contribution: contribution,
          blocked: ExtensionUiMountBlock.contributionInvalid,
          refusal: refusal,
        ),
      );
      continue;
    }
    final requirement = extensionUiRequirementOf(contribution);
    if (requirement == ExtensionUiMountRequirement.unpublished) {
      decisions.add(
        ExtensionUiMountDecision(
          contribution: contribution,
          blocked: ExtensionUiMountBlock.profileUnpublished,
        ),
      );
      continue;
    }
    if (requirement == ExtensionUiMountRequirement.served &&
        !servedProfiles.contains(contribution.requiredProfile)) {
      decisions.add(
        ExtensionUiMountDecision(
          contribution: contribution,
          blocked: ExtensionUiMountBlock.profileNotInstalled,
        ),
      );
      continue;
    }
    if (contribution.kind == ExtensionContributionKind.resourceView) {
      // A resource view mounts through the renderer registered for its format,
      // not through a compiled widget primitive.
      final format = contribution.resourceFormat;
      if (format == null) {
        decisions.add(
          ExtensionUiMountDecision(
            contribution: contribution,
            blocked: ExtensionUiMountBlock.resourceFormatMissing,
          ),
        );
        continue;
      }
      if (!availableResourceFormats.contains(format)) {
        decisions.add(
          ExtensionUiMountDecision(
            contribution: contribution,
            blocked: ExtensionUiMountBlock.resourceFormatUnavailable,
          ),
        );
        continue;
      }
      decisions.add(ExtensionUiMountDecision(contribution: contribution));
      continue;
    }
    final primitive = extensionUiPrimitiveFor(contribution.kind);
    if (primitive == null || !availablePrimitives.contains(primitive)) {
      decisions.add(
        ExtensionUiMountDecision(
          contribution: contribution,
          blocked: ExtensionUiMountBlock.primitiveUnavailable,
        ),
      );
      continue;
    }
    decisions.add(ExtensionUiMountDecision(contribution: contribution));
  }
  return List<ExtensionUiMountDecision>.unmodifiable(decisions);
}

void _refuseUnknownKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String field,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('unknown $field field: $key', json, 0);
    }
  }
}

String _string(Map<String, Object?> json, String key, String field) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$field.$key must be a non-empty string', json, 0);
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string', json, 0);
  }
  return value;
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw FormatException('$field entries must be objects', value, 0);
  }
  return value.map((key, entry) => MapEntry(key.toString(), entry));
}
