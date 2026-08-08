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

  Duration catalogDelay(ConversationRefreshPriority priority) =>
      switch (priority) {
        ConversationRefreshPriority.active => activeCatalogInterval,
        ConversationRefreshPriority.warm => warmCatalogInterval,
        ConversationRefreshPriority.background => backgroundCatalogInterval,
        ConversationRefreshPriority.suspended => Duration.zero,
      };
}
