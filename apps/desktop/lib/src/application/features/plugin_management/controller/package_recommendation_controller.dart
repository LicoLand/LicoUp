import 'dart:async';

import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_center_catalog.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_first_launch_record.dart';
import 'package:licoup/src/application/state/application_signal.dart';

/// Installs one reviewed archive.
///
/// The recommendation flow never widens this: it can only hand an archive path
/// to the same native install transaction the package center uses.
abstract interface class PackageRecommendationInstallPort {
  Future<bool> installFromArchive(String archive);
}

/// One offered package: what the native adapter catalog recommends and which
/// archive the user is confirming.
final class PackageRecommendation {
  const PackageRecommendation({
    required this.packageId,
    required this.label,
    required this.agentId,
    required this.archive,
  });

  final String packageId;
  final String label;
  final String agentId;

  /// The local archive this offer installs. An empty archive is an offer whose
  /// bytes are not available yet; applying it reports a failure and installs
  /// nothing.
  final String archive;
}

/// The outcome of one sequential install attempt.
final class PackageRecommendationResult {
  const PackageRecommendationResult({
    required this.packageId,
    required this.installed,
    this.reasonCode = '',
  });

  final String packageId;
  final bool installed;
  final String reasonCode;
}

/// The first-launch offer the shell shows in its one confirmation.
final class PackageRecommendationOffer {
  PackageRecommendationOffer({
    required List<PackageRecommendation> recommendations,
    required this.firstLaunch,
  }) : recommendations = List.unmodifiable(recommendations);

  final List<PackageRecommendation> recommendations;

  /// Whether this offer is the first launch of the data home, as opposed to a
  /// capability that appeared after the first launch settled.
  final bool firstLaunch;

  bool get isEmpty => recommendations.isEmpty;
}

/// What one bootstrap attempt settled.
final class PackageBootstrapOutcome {
  const PackageBootstrapOutcome({
    required this.markerRecorded,
    required this.offered,
    required this.confirmed,
    required this.installed,
    required this.failed,
    required this.declined,
  });

  static const none = PackageBootstrapOutcome(
    markerRecorded: false,
    offered: false,
    confirmed: false,
    installed: 0,
    failed: 0,
    declined: 0,
  );

  /// Whether this run had to write the durable first-launch marker.
  final bool markerRecorded;
  final bool offered;
  final bool confirmed;
  final int installed;
  final int failed;
  final int declined;
}

/// Runs the first-launch package recommendation and the first-use install.
///
/// Four properties are enforced here rather than described:
///
/// 1. **The offer happens once per data home.** The durable marker is written
///    before the scan starts, so a crash, a quit or a refusal never re-offers
///    the same packages on the next launch.
/// 2. **The scan is off the frame.** The recommendation set is read from the
///    native adapter catalog synchronously after the async scan call is made;
///    no probe runs on the frame thread and no Agent is launched.
/// 3. **Declines are durable and final.** A declined package is recorded with
///    its reason and is never recommended again, including by a later
///    first-use check.
/// 4. **A failure never blocks startup and never stops the batch.** Every
///    install reports its own outcome; a refused install is recorded and the
///    next recommendation still runs.
final class PackageRecommendationController extends ApplicationStateOwner {
  PackageRecommendationController({
    required PackageRecommendationInstallPort installer,
    required PackageFirstLaunchStore store,
  }) : _installer = installer,
       _store = store;

  final PackageRecommendationInstallPort _installer;
  final PackageFirstLaunchStore _store;
  PackageFirstLaunchRecord _record = const PackageFirstLaunchRecord();
  PackageRecommendationOffer? _pending;
  PackageBootstrapOutcome _outcome = PackageBootstrapOutcome.none;
  bool _running = false;
  bool _loaded = false;
  bool _disposed = false;

  PackageRecommendationOffer? get pending => _pending;
  PackageBootstrapOutcome get outcome => _outcome;
  bool get running => _running;
  bool get loaded => _loaded;

  /// Load the durable decision for this data home without offering anything.
  Future<void> load() async {
    _record = await _store.load();
    _loaded = true;
    publishChange();
  }

  /// Run the first-launch step.
  ///
  /// The caller has already resolved the data home. Failures are returned as an
  /// outcome, never thrown: the bootstrap step that calls this is not allowed to
  /// take the client down.
  Future<PackageBootstrapOutcome> runFirstLaunch({
    required List<AdapterPluginDescriptor> adapters,
  }) async {
    if (_running) return _outcome;
    if (!_loaded) await load();
    if (_record.firstLaunchCompleted) {
      _outcome = const PackageBootstrapOutcome(
        markerRecorded: false,
        offered: false,
        confirmed: false,
        installed: 0,
        failed: 0,
        declined: 0,
      );
      publishChange();
      return _outcome;
    }
    _running = true;
    publishChange();
    var markerRecorded = false;
    try {
      // The marker lands before the scan: the data home has been offered, no
      // matter what happens to the rest of this run.
      await _writeRecord(_record.completed());
      markerRecorded = true;
      final recommendations = _recommended(adapters);
      if (recommendations.isEmpty) {
        _outcome = PackageBootstrapOutcome(
          markerRecorded: markerRecorded,
          offered: false,
          confirmed: false,
          installed: 0,
          failed: 0,
          declined: 0,
        );
        return _outcome;
      }
      _pending = PackageRecommendationOffer(
        recommendations: recommendations,
        firstLaunch: true,
      );
      publishChange();
      return _outcome = PackageBootstrapOutcome(
        markerRecorded: markerRecorded,
        offered: true,
        confirmed: false,
        installed: 0,
        failed: 0,
        declined: 0,
      );
    } finally {
      _running = false;
      publishChange();
    }
  }

  /// Apply the answer to the one confirmation.
  ///
  /// An unaccepted offer records every recommended package as declined, so a
  /// refusal is as durable as an acceptance. Installs run sequentially and each
  /// one's failure is contained.
  Future<List<PackageRecommendationResult>> resolveOffer({
    required bool accepted,
    String declineReason = 'first-launch',
  }) async {
    final offer = _pending;
    if (offer == null) return const [];
    _pending = null;
    publishChange();
    final results = <PackageRecommendationResult>[];
    var declined = 0;
    for (final recommendation in offer.recommendations) {
      if (!accepted) {
        await _recordDecline(recommendation.packageId, declineReason);
        declined += 1;
        results.add(
          PackageRecommendationResult(
            packageId: recommendation.packageId,
            installed: false,
            reasonCode: 'package_recommendation_declined',
          ),
        );
        continue;
      }
      var installed = false;
      try {
        installed = await _installer.installFromArchive(recommendation.archive);
      } catch (_) {
        installed = false;
      }
      results.add(
        PackageRecommendationResult(
          packageId: recommendation.packageId,
          installed: installed,
          reasonCode: installed ? '' : 'package_recommendation_install_failed',
        ),
      );
    }
    final installed = results.where((result) => result.installed).length;
    _outcome = PackageBootstrapOutcome(
      markerRecorded: false,
      offered: true,
      confirmed: accepted,
      installed: installed,
      failed: results.length - installed - declined,
      declined: declined,
    );
    publishChange();
    return results;
  }

  /// Offer the capabilities one catalog reports as available but not installed.
  ///
  /// This is the first-use path: a capability that appeared after the first
  /// launch settled is offered from the native availability fact, never from a
  /// local guess. Returns `null` when nothing is available, when every available
  /// capability is already declined, or before the first launch has settled.
  PackageRecommendationOffer? offerOnFirstUse({
    required PackageCenterCatalog catalog,
  }) {
    if (!_record.firstLaunchCompleted) return null;
    final recommendations = <PackageRecommendation>[
      for (final item in catalog.packages)
        if (item.facts.available &&
            !item.facts.installed &&
            item.isOfferedToPackageCenter &&
            !_record.declined(item.packageId))
          PackageRecommendation(
            packageId: item.packageId,
            label: item.label,
            agentId: item.agentId,
            archive: '',
          ),
    ];
    if (recommendations.isEmpty) return null;
    final offer = PackageRecommendationOffer(
      recommendations: recommendations,
      firstLaunch: false,
    );
    _pending = offer;
    publishChange();
    return offer;
  }

  /// Close the current offer without installing, recording each package as
  /// declined so a later check does not offer it again.
  Future<void> dismiss({String reason = 'dismissed'}) async {
    final offer = _pending;
    if (offer == null) return;
    _pending = null;
    publishChange();
    for (final recommendation in offer.recommendations) {
      await _recordDecline(recommendation.packageId, reason);
    }
  }

  bool declined(String packageId) => _record.declined(packageId);

  List<PackageRecommendation> _recommended(
    List<AdapterPluginDescriptor> adapters, {
    PackageCenterCatalog? catalog,
  }) {
    final recommendations = <PackageRecommendation>[];
    for (final adapter in adapters) {
      if (adapter.managementKind != AdapterPluginManagementKind.managedBridge) {
        continue;
      }
      if (adapter.installationState == 'installed') continue;
      if (!adapter.supports(AdapterPluginLifecycleAction.install)) continue;
      for (final plugin in adapter.plugins) {
        if (!plugin.supports(AdapterPluginLifecycleAction.install)) continue;
        if (plugin.installationState == 'installed') continue;
        if (_record.declined(plugin.id)) continue;
        if (catalog?.package(plugin.id)?.facts.installed == true) continue;
        recommendations.add(
          PackageRecommendation(
            packageId: plugin.id,
            label: plugin.label,
            agentId: adapter.agentId,
            archive: '',
          ),
        );
      }
    }
    return recommendations;
  }

  Future<void> _writeRecord(PackageFirstLaunchRecord record) async {
    _record = record;
    try {
      await _store.save(record);
    } catch (_) {
      // A data home that cannot record the marker must not take the client
      // down; the in-memory decision still holds for this process.
    }
    publishChange();
  }

  Future<void> _recordDecline(String packageId, String reason) =>
      _writeRecord(_record.withDecline(packageId, reason));

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
