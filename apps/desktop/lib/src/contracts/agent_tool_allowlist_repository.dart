abstract interface class AgentToolAllowlistRepository {
  Future<Map<String, List<String>>> load(Object portableData);

  Future<void> save(
    Object portableData,
    Map<String, List<String>> allowlistsByAgent,
  );
}
