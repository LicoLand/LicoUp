import 'dart:collection';

/// Wire schema of the native `package` command family
/// (`licoup.package-lifecycle.v1`, declared by
/// `schemas/client_bridge/package.json`).
///
/// The renderer never derives a package fact. This file parses exactly what the
/// native package store reported and refuses a report that could not have come
/// from a consistent store, so a locally guessed state can never reach the
/// package center.
const packageLifecycleSchema = 'licoup.package-lifecycle.v1';

/// How far a package version got through the native install lifecycle.
enum PackageLifecycleKind {
  available('available'),
  downloaded('downloaded'),
  verified('verified'),
  localApproved('local-approved'),
  staged('staged'),
  installed('installed');

  const PackageLifecycleKind(this.wireName);

  final String wireName;

  static PackageLifecycleKind parse(Object? value) => switch (value) {
    'available' => available,
    'downloaded' => downloaded,
    'verified' => verified,
    'local-approved' => localApproved,
    'staged' => staged,
    'installed' => installed,
    _ => throw const FormatException('package_lifecycle_invalid'),
  };
}

/// The channel an installed package came from.
enum PackageSourceKind {
  localImport('local-import'),
  localDirectory('local-directory'),
  officialDirectory('official-directory'),
  thirdPartyDirectory('third-party-directory');

  const PackageSourceKind(this.wireName);

  final String wireName;

  static PackageSourceKind parse(Object? value) => switch (value) {
    'local-import' => localImport,
    'local-directory' => localDirectory,
    'official-directory' => officialDirectory,
    'third-party-directory' => thirdPartyDirectory,
    _ => throw const FormatException('package_source_invalid'),
  };
}

/// The capability family a package provides.
///
/// A package documented as a LicoUp capability is offered by the package center.
/// An adapter package that exists only to serve a third-party Agent installs
/// through Agent Hub, which the package center reports instead of offering.
enum PackageCapabilityKind {
  licoupCapability('licoup-capability'),
  agentAdapter('agent-adapter');

  const PackageCapabilityKind(this.wireName);

  final String wireName;

  static PackageCapabilityKind parse(Object? value) => switch (value) {
    'licoup-capability' => licoupCapability,
    'agent-adapter' => agentAdapter,
    _ => throw const FormatException('package_capability_kind_invalid'),
  };
}

/// The four facts the package center renders, exactly as the native package
/// store reported them.
///
/// Only the forward implications the store itself enforces are required: an
/// active instance needs an enabled package, which needs an installed one.
/// Availability is deliberately not part of that chain — a local import is
/// installed without ever being available.
final class PackageFactsProjection {
  const PackageFactsProjection({
    required this.available,
    required this.installed,
    required this.enabled,
    required this.active,
  });

  /// No capability is present at all: the not-installed state.
  static const absent = PackageFactsProjection(
    available: false,
    installed: false,
    enabled: false,
    active: false,
  );

  final bool available;
  final bool installed;
  final bool enabled;
  final bool active;

  bool get notInstalled => !installed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackageFactsProjection &&
          other.available == available &&
          other.installed == installed &&
          other.enabled == enabled &&
          other.active == active;

  @override
  int get hashCode => Object.hash(available, installed, enabled, active);

  @override
  String toString() =>
      'PackageFactsProjection(available: $available, installed: $installed, '
      'enabled: $enabled, active: $active)';
}

/// One package the native store reported.
final class PackageCatalogItem {
  PackageCatalogItem({
    required this.packageId,
    required this.version,
    required this.label,
    required this.capabilityKind,
    required this.lifecycle,
    required this.source,
    required this.facts,
    this.agentId = '',
    this.installedAtUnixMs,
  });

  /// Parse one `packages[]` entry of `package.catalog`.
  ///
  /// `available` is read from the report and never inferred: a caller that does
  /// not know availability reports `available: false`, which is the same fact a
  /// fresh local import has.
  factory PackageCatalogItem.fromJson(Map<Object?, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('package_catalog_invalid');
      }
      return value;
    }

    bool requiredBool(String key) {
      final value = json[key];
      if (value is! bool) {
        throw const FormatException('package_catalog_invalid');
      }
      return value;
    }

    // An entry only reaches this parser from the store's installed set, so the
    // lifecycle must say so. `available`, `enabled` and `active` are reported
    // facts, never inferred from the entry's presence.
    final lifecycle = PackageLifecycleKind.parse(json['lifecycle']);
    if (lifecycle != PackageLifecycleKind.installed) {
      throw const FormatException('package_catalog_facts_inconsistent');
    }
    final active = switch (json['active']) {
      null => false,
      final bool value => value,
      _ => throw const FormatException('package_catalog_invalid'),
    };
    final facts = PackageFactsProjection(
      available: requiredBool('available'),
      installed: true,
      enabled: requiredBool('enabled'),
      active: active,
    );
    _requireConsistentFacts(facts);
    final installedAt = switch (json['installedAtUnixMs']) {
      null => null,
      final int value => value,
      _ => throw const FormatException('package_catalog_invalid'),
    };
    final label = json['label'];
    return PackageCatalogItem(
      packageId: requiredString('packageId'),
      version: requiredString('version'),
      label: label is String && label.trim().isNotEmpty
          ? label
          : requiredString('packageId'),
      capabilityKind: json['capabilityKind'] == null
          ? PackageCapabilityKind.licoupCapability
          : PackageCapabilityKind.parse(json['capabilityKind']),
      lifecycle: lifecycle,
      source: PackageSourceKind.parse(json['source']),
      facts: facts,
      agentId: json['agentId'] is String ? json['agentId'] as String : '',
      installedAtUnixMs: installedAt,
    );
  }

  final String packageId;
  final String version;
  final String label;
  final PackageCapabilityKind capabilityKind;
  final PackageLifecycleKind lifecycle;
  final PackageSourceKind source;
  final PackageFactsProjection facts;

  /// The detected Agent this package serves, when it serves one.
  final String agentId;
  final int? installedAtUnixMs;

  bool get isAgentAdapter =>
      capabilityKind == PackageCapabilityKind.agentAdapter;

  /// Whether the package center offers this package as a LicoUp capability.
  bool get isOfferedToPackageCenter =>
      capabilityKind == PackageCapabilityKind.licoupCapability;

  /// The entry rendered when a capability is absent from the native catalog.
  ///
  /// It carries no package id: the renderer must not invent one.
  static PackageCatalogItem absent({
    required String label,
    required String agentId,
  }) => PackageCatalogItem(
    packageId: '',
    version: '',
    label: label,
    capabilityKind: PackageCapabilityKind.licoupCapability,
    lifecycle: PackageLifecycleKind.available,
    source: PackageSourceKind.officialDirectory,
    facts: PackageFactsProjection.absent,
    agentId: agentId,
  );

  static void _requireConsistentFacts(PackageFactsProjection facts) {
    if ((facts.active && !facts.enabled) ||
        (facts.enabled && !facts.installed)) {
      throw const FormatException('package_catalog_facts_inconsistent');
    }
  }
}

/// The parsed `package catalog` report.
final class PackageCenterCatalog {
  PackageCenterCatalog({required List<PackageCatalogItem> packages})
    : packages = UnmodifiableListView(packages);

  const PackageCenterCatalog._empty() : packages = const [];

  /// Parse the native report, refusing anything the store could not have
  /// produced.
  factory PackageCenterCatalog.fromJson(Map<String, dynamic> json) {
    if (json['isError'] == true) {
      throw FormatException(
        json['reasonCode'] is String
            ? json['reasonCode'] as String
            : 'package_catalog_refused',
      );
    }
    if (json['schemaVersion'] != packageLifecycleSchema) {
      throw const FormatException('package_catalog_schema_invalid');
    }
    final rawPackages = json['packages'];
    if (rawPackages is! List) {
      throw const FormatException('package_catalog_invalid');
    }
    final identities = <String>{};
    final packages = <PackageCatalogItem>[];
    for (final raw in rawPackages) {
      if (raw is! Map) {
        throw const FormatException('package_catalog_invalid');
      }
      final item = PackageCatalogItem.fromJson(raw);
      if (!identities.add('${item.packageId}@${item.version}')) {
        throw const FormatException('package_catalog_duplicate');
      }
      packages.add(item);
    }
    packages.sort((left, right) {
      final byId = left.packageId.compareTo(right.packageId);
      return byId != 0 ? byId : left.version.compareTo(right.version);
    });
    return PackageCenterCatalog(packages: packages);
  }

  static const empty = PackageCenterCatalog._empty();

  final List<PackageCatalogItem> packages;

  bool get isEmpty => packages.isEmpty;

  PackageCatalogItem? package(String packageId) {
    for (final item in packages) {
      if (item.packageId == packageId) return item;
    }
    return null;
  }

  /// The first package the store reported for one detected Agent.
  PackageCatalogItem? packageForAgent(String agentId) {
    if (agentId.isEmpty) return null;
    for (final item in packages) {
      if (item.agentId == agentId) return item;
    }
    return null;
  }
}

/// The `package install-plan` report: a reviewed plan and the token bound to it.
final class PackageInstallPlan {
  const PackageInstallPlan({
    required this.packageId,
    required this.version,
    required this.planDigest,
    required this.confirmation,
    required this.archive,
  });

  factory PackageInstallPlan.fromJson(Map<String, dynamic> json) {
    if (json['isError'] == true) {
      throw FormatException(
        json['reasonCode'] is String
            ? json['reasonCode'] as String
            : 'package_install_plan_refused',
      );
    }
    if (json['schemaVersion'] != packageLifecycleSchema) {
      throw const FormatException('package_install_plan_schema_invalid');
    }
    final plan = json['plan'];
    if (plan is! Map) {
      throw const FormatException('package_install_plan_invalid');
    }
    String requiredString(Object? value) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('package_install_plan_invalid');
      }
      return value;
    }

    return PackageInstallPlan(
      packageId: requiredString(plan['packageId']),
      version: requiredString(plan['version']),
      planDigest: requiredString(json['planDigest']),
      confirmation: requiredString(json['confirmation']),
      archive: requiredString(json['archive']),
    );
  }

  final String packageId;
  final String version;
  final String planDigest;
  final String confirmation;
  final String archive;
}
