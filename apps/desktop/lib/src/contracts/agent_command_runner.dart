abstract class AgentCommandRunner {
  Future<Map<String, dynamic>> runCli(List<String> args);

  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  );

  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args);

  /// NDJSON stdout stream for commands that also consume a private stdin body.
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  );
}
