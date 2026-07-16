import 'dart:collection';

const int catalogConvergenceMaxPartitions = 64;
const int catalogConvergenceMaxToolsPerPartition = 4096;

final class CatalogInvalidation {
  CatalogInvalidation({
    required Iterable<String> affectedPartitions,
    required this.sourceRevision,
    required this.catalogRevision,
    required this.audienceRevision,
    required this.reasonCode,
  }) : affectedPartitions = List<String>.unmodifiable(
         affectedPartitions
             .map((value) => value.trim())
             .where((value) => value.isNotEmpty)
             .toSet(),
       ) {
    if (this.affectedPartitions.isEmpty ||
        this.affectedPartitions.length > catalogConvergenceMaxPartitions ||
        sourceRevision < 0 ||
        audienceRevision < 0 ||
        catalogRevision.trim().isEmpty) {
      throw const FormatException('catalog_invalidation_invalid');
    }
  }

  final List<String> affectedPartitions;
  final int sourceRevision;
  final String catalogRevision;
  final int audienceRevision;
  final String reasonCode;

  Map<String, dynamic> toJson() => {
    'affectedPartitions': affectedPartitions,
    'sourceRevision': sourceRevision,
    'catalogRevision': catalogRevision.trim(),
    'audienceRevision': audienceRevision,
    'reasonCode': reasonCode.trim(),
  };
}

final class CatalogFetchedSnapshot {
  CatalogFetchedSnapshot({
    required this.sourceRevision,
    required this.catalogRevision,
    required this.audienceRevision,
    required Iterable<Map<String, dynamic>> tools,
  }) : tools = List<Map<String, dynamic>>.unmodifiable(
         tools.map(
           (tool) => UnmodifiableMapView<String, dynamic>(
             Map<String, dynamic>.from(tool),
           ),
         ),
       ) {
    final names = <String>{};
    if (sourceRevision < 0 ||
        audienceRevision < 0 ||
        catalogRevision.trim().isEmpty ||
        this.tools.length > catalogConvergenceMaxToolsPerPartition ||
        this.tools.any((tool) {
          final name = tool['name'];
          return name is! String ||
              name.trim().isEmpty ||
              !names.add(name.trim());
        })) {
      throw const FormatException('catalog_snapshot_invalid');
    }
  }

  final int sourceRevision;
  final String catalogRevision;
  final int audienceRevision;
  final List<Map<String, dynamic>> tools;

  Map<String, dynamic> toJson(String partitionKey) => {
    'partitionKey': partitionKey.trim(),
    'sourceRevision': sourceRevision,
    'catalogRevision': catalogRevision.trim(),
    'audienceRevision': audienceRevision,
    'tools': tools,
  };
}

final class CatalogConvergenceStatus {
  const CatalogConvergenceStatus({
    required this.partitionCount,
    required this.inFlightCount,
    required this.pendingInvalidationCount,
    required this.reconnectFence,
    required this.lastKnownAudienceRevision,
    required this.uiObservedRevision,
    required this.appliedCohortCount,
    required this.pendingCohortCount,
    required this.fencedCohortCount,
    required this.disconnectedCohortCount,
  });

  factory CatalogConvergenceStatus.empty() => const CatalogConvergenceStatus(
    partitionCount: 0,
    inFlightCount: 0,
    pendingInvalidationCount: 0,
    reconnectFence: false,
    lastKnownAudienceRevision: -1,
    uiObservedRevision: -1,
    appliedCohortCount: 0,
    pendingCohortCount: 0,
    fencedCohortCount: 0,
    disconnectedCohortCount: 0,
  );

  factory CatalogConvergenceStatus.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 'v0.0.1:licoarc:catalog-convergence-1') {
      throw const FormatException('catalog_status_schema_invalid');
    }
    final cohort = json['cohort'];
    if (cohort is! List || cohort.length > catalogConvergenceMaxPartitions) {
      throw const FormatException('catalog_status_cohort_invalid');
    }
    var applied = 0;
    var pending = 0;
    var fenced = 0;
    var disconnected = 0;
    for (final raw in cohort) {
      if (raw is! Map) {
        throw const FormatException('catalog_status_cohort_invalid');
      }
      switch (raw['outcome']) {
        case 'applied':
          applied += 1;
          break;
        case 'pending':
          pending += 1;
          break;
        case 'fenced':
          fenced += 1;
          break;
        case 'disconnected':
          disconnected += 1;
          break;
        default:
          throw const FormatException('catalog_status_cohort_invalid');
      }
    }
    return CatalogConvergenceStatus(
      partitionCount: _boundedCount(json, 'partitionCount'),
      inFlightCount: _boundedCount(json, 'inFlightCount'),
      pendingInvalidationCount: _boundedCount(json, 'pendingInvalidationCount'),
      reconnectFence: json['reconnectFence'] == true,
      lastKnownAudienceRevision: _revision(json, 'lastKnownAudienceRevision'),
      uiObservedRevision: _revision(json, 'uiObservedRevision'),
      appliedCohortCount: applied,
      pendingCohortCount: pending,
      fencedCohortCount: fenced,
      disconnectedCohortCount: disconnected,
    );
  }

  final int partitionCount;
  final int inFlightCount;
  final int pendingInvalidationCount;
  final bool reconnectFence;
  final int lastKnownAudienceRevision;
  final int uiObservedRevision;
  final int appliedCohortCount;
  final int pendingCohortCount;
  final int fencedCohortCount;
  final int disconnectedCohortCount;

  bool get discoveryBlocked => reconnectFence || pendingInvalidationCount > 0;
}

final class CatalogDiscoveryResult {
  CatalogDiscoveryResult({
    required this.ok,
    required this.reasonCode,
    required Iterable<Map<String, dynamic>> tools,
    required this.sourceRevision,
    required this.catalogRevision,
    required this.audienceRevision,
  }) : tools = List<Map<String, dynamic>>.unmodifiable(
         tools.map(
           (tool) => UnmodifiableMapView<String, dynamic>(
             Map<String, dynamic>.from(tool),
           ),
         ),
       );

  factory CatalogDiscoveryResult.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tools'];
    if (json['ok'] is! bool ||
        json['reasonCode'] is! String ||
        rawTools is! List ||
        rawTools.length > catalogConvergenceMaxToolsPerPartition) {
      throw const FormatException('catalog_discovery_invalid');
    }
    final tools = rawTools.map((raw) {
      if (raw is! Map) {
        throw const FormatException('catalog_discovery_invalid');
      }
      return Map<String, dynamic>.from(raw);
    });
    return CatalogDiscoveryResult(
      ok: json['ok'] as bool,
      reasonCode: (json['reasonCode'] as String).trim(),
      tools: tools,
      sourceRevision: json['sourceRevision'] as int?,
      catalogRevision: json['catalogRevision'] as String?,
      audienceRevision: json['audienceRevision'] as int?,
    );
  }

  final bool ok;
  final String reasonCode;
  final List<Map<String, dynamic>> tools;
  final int? sourceRevision;
  final String? catalogRevision;
  final int? audienceRevision;
}

int _boundedCount(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value > catalogConvergenceMaxPartitions) {
    throw const FormatException('catalog_status_count_invalid');
  }
  return value;
}

int _revision(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < -1) {
    throw const FormatException('catalog_status_revision_invalid');
  }
  return value;
}
