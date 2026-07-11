abstract class RoutingModuleRegistration {
  bool get isEnabled;
  bool get isReady;

  Future<void> activate();
  Future<void> deactivate();
  Future<void> unload();
}
