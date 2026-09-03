import 'package:licoup/src/contracts/provider_quota_models.dart';

abstract interface class ProviderQuotaGateway {
  /// Pulls the current per-agent quota snapshot projection. [agentId] scopes
  /// the refresh to one agent when non-empty; [forceRefresh] bypasses the
  /// native retained-snapshot cache.
  Future<ProviderQuotaSnapshotReport> snapshot({
    String agentId = '',
    bool forceRefresh = false,
  });
}
