enum ConversationRefreshPriority { active, warm, background, suspended }

enum ConversationLifecyclePhase { resumed, inactive, hidden, paused, detached }

final class ConversationRefreshPolicy {
  const ConversationRefreshPolicy({
    this.activeInterval = const Duration(seconds: 2),
    this.warmInterval = const Duration(seconds: 10),
    this.backgroundInterval = const Duration(seconds: 30),
    this.activeCatalogInterval = const Duration(seconds: 20),
    this.warmCatalogInterval = const Duration(seconds: 45),
    this.backgroundCatalogInterval = const Duration(seconds: 60),
  });

  final Duration activeInterval;
  final Duration warmInterval;
  final Duration backgroundInterval;
  final Duration activeCatalogInterval;
  final Duration warmCatalogInterval;
  final Duration backgroundCatalogInterval;

  Duration activeDelay(ConversationRefreshPriority priority) =>
      switch (priority) {
        ConversationRefreshPriority.active => activeInterval,
        ConversationRefreshPriority.warm => warmInterval,
        ConversationRefreshPriority.background => backgroundInterval,
        ConversationRefreshPriority.suspended => Duration.zero,
      };

  /// The delay before the next active-lane read after [unchangedReads]
  /// consecutive reads observed no applied change. The lane doubles from
  /// the active interval and stays bounded by the catalog interval, so a
  /// quiet view decays into the discovery lane's cadence instead of
  /// polling a fixed history forever.
  Duration activeDelayAfter(
    ConversationRefreshPriority priority,
    int unchangedReads,
  ) {
    final base = activeDelay(priority);
    final cap = catalogDelay(priority);
    if (base <= Duration.zero || cap <= Duration.zero) {
      return base;
    }
    final factor = 1 << unchangedReads.clamp(0, 10).toInt();
    final scaled = base * factor;
    return scaled > cap ? cap : scaled;
  }

  Duration catalogDelay(ConversationRefreshPriority priority) =>
      switch (priority) {
        ConversationRefreshPriority.active => activeCatalogInterval,
        ConversationRefreshPriority.warm => warmCatalogInterval,
        ConversationRefreshPriority.background => backgroundCatalogInterval,
        ConversationRefreshPriority.suspended => Duration.zero,
      };
}
