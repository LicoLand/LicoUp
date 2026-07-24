import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

class NativeOneShotCommandExecutor implements NativeCommandExecutor {
  NativeOneShotCommandExecutor({
    required NativeCliProcessContext processContext,
    NativeRunCliExecutable? runCliExecutable,
  }) : _processContext = processContext,
       _runCliExecutable = runCliExecutable ?? _defaultRunCliExecutable;

  final NativeCliProcessContext _processContext;
  final NativeRunCliExecutable _runCliExecutable;

  static Future<ProcessResult> _defaultRunCliExecutable(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    return Process.run(executable, arguments, environment: environment);
  }

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    late File? cli;
    late Map<String, String>? environment;
    try {
      cli = await _processContext.resolveCliBinary();
      environment = await _processContext.buildEnvironment();
    } on Object {
      throw Exception('licoup command could not be completed.');
    }

    if (cli == null) {
      try {
        final result = await _runCliExecutable(
          'licoup',
          arguments,
          environment,
        );
        if (result.exitCode != 0) {
          throw Exception('licoup command failed.');
        }
        return _decodeResponse(result.stdout);
      } on Object {
        throw Exception('licoup command could not be completed.');
      }
    }

    late ProcessResult result;
    try {
      result = await _runCliExecutable(cli.path, arguments, environment);
    } on Object {
      throw Exception('licoup command could not be completed.');
    }
    if (result.exitCode != 0) {
      throw Exception(
        'licoup command failed '
        '(exit code ${result.exitCode}, stderr bytes ${utf8.encode(result.stderr.toString()).length}).',
      );
    }
    return _decodeResponse(result.stdout);
  }

  Map<String, dynamic> _decodeResponse(Object? stdout) {
    try {
      final decoded = jsonDecode(stdout?.toString() ?? '');
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on Object {
      // The caller receives a fixed error without native command output.
    }
    throw Exception('licoup returned an invalid JSON response.');
  }
}
