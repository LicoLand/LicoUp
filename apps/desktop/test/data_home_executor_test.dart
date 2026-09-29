import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/data_home_executor.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

void main() {
  test('dedicated relocation environment drops inherited root selections', () {
    final environment = environmentWithoutInheritedRoot({
      'LICOUP_HOME': '/old/root',
      'LICOUP_PORTABLE_DIR': '/stale/root',
      'PATH': '/synthetic/bin',
    });

    expect(environment['LICOUP_HOME'], '');
    expect(environment['LICOUP_PORTABLE_DIR'], '');
    expect(environment['PATH'], '/synthetic/bin');
  });

  test(
    'recovery builds its process environment without resolving the root',
    () async {
      final process = _DataHomeProcess();
      final context = _ProcessContext(process);

      await DataHomeExecutor(context).recover('/synthetic/existing-root');

      expect(context.normalEnvironmentBuilds, 0);
      expect(context.dataHomeEnvironmentBuilds, 1);
      expect(context.startedArguments, ['rpc', 'data-home']);
      expect(context.startedEnvironment?['LICOUP_HOME'], '');
      expect(context.startedEnvironment?['LICOUP_PORTABLE_DIR'], '');
      expect(context.startedEnvironment?['PATH'], '/synthetic/bin');
    },
  );

  test(
    'relocation request is encoded through the generated method contract',
    () {
      final request = ConversationCommand.decode(
        Uint8List.fromList(
          encodeDataHomeRpcRequest(
            method: ConversationProtocolMethod.dataHomeRelocate,
            params: const {
              'destinationParent': '/synthetic/destination',
              'confirmed': true,
            },
            requestId: 'request-1',
          ),
        ),
      );

      expect(request.method, ConversationProtocolMethod.dataHomeRelocate);
      expect(request.id, 'request-1');
      expect(request.workflowId, 'request-1');
      expect(request.params, {
        'destinationParent': '/synthetic/destination',
        'confirmed': true,
      });
    },
  );

  test(
    'relocation response validates identity and projects only its result',
    () {
      final response = utf8.encode(
        jsonEncode({
          'protocol': conversationProtocolVersion,
          'id': 'request-1',
          'workflowId': 'request-1',
          'ok': true,
          'result': {'status': 'relocated'},
        }),
      );

      expect(decodeDataHomeResponse(response, 'request-1'), {
        'status': 'relocated',
      });
      expect(
        () => decodeDataHomeResponse(response, 'another-request'),
        throwsA(isA<LicoClientRpcException>()),
      );
    },
  );

  test('native relocation error remains a typed bounded code', () {
    final response = utf8.encode(
      jsonEncode({
        'protocol': conversationProtocolVersion,
        'id': 'request-1',
        'workflowId': 'request-1',
        'ok': false,
        'error': {'code': 'data_home_destination_exists'},
      }),
    );

    expect(
      () => decodeDataHomeResponse(response, 'request-1'),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'data_home_destination_exists',
        ),
      ),
    );
  });

  test(
    'oversized stdout is drained without cancelling a submitted move',
    () async {
      final process = _DataHomeProcess(
        oversizedStdout: conversationProtocolMaxResponseBytes + 1,
      );
      final executor = DataHomeExecutor(_ProcessContext(process));

      final error = await _captureError(
        executor.relocate('/synthetic/destination'),
      );

      expect(process.stdoutBytesRead, conversationProtocolMaxResponseBytes + 1);
      expect(process.killCount, 0);
      expect(error, isA<LicoClientRpcException>());
      expect((error as LicoClientRpcException).code, 'response_too_large');
    },
  );

  test(
    'oversized progress stderr is drained without cancelling a submitted move',
    () async {
      final process = _DataHomeProcess(
        oversizedStderr: conversationProtocolMaxStderrBytes + 1,
      );
      final executor = DataHomeExecutor(_ProcessContext(process));

      final error = await _captureError(
        executor.relocate('/synthetic/destination'),
      );

      expect(process.stderrBytesRead, conversationProtocolMaxStderrBytes + 1);
      expect(process.killCount, 0);
      expect(error, isA<LicoClientRpcException>());
      expect((error as LicoClientRpcException).code, 'stderr_too_large');
    },
  );
}

Future<Object?> _captureError<T>(Future<T> operation) async {
  try {
    await operation;
    return null;
  } on Object catch (error) {
    return error;
  }
}

final class _ProcessContext
    implements NativeCliProcessContext, NativeCliDataHomeMutationContext {
  _ProcessContext(this.process);

  final _DataHomeProcess process;
  var normalEnvironmentBuilds = 0;
  var dataHomeEnvironmentBuilds = 0;
  List<String>? startedArguments;
  Map<String, String>? startedEnvironment;

  @override
  Duration get requestTimeout => const Duration(seconds: 1);

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    normalEnvironmentBuilds += 1;
    return const {'LICOUP_HOME': '/old/root'};
  }

  @override
  Future<Map<String, String>?> buildDataHomeMutationEnvironment() async {
    dataHomeEnvironmentBuilds += 1;
    return const {
      'LICOUP_HOME': '/old/root',
      'LICOUP_PORTABLE_DIR': '/older/root',
      'PATH': '/synthetic/bin',
    };
  }

  @override
  Future<File?> resolveCliBinary() async => null;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startedArguments = arguments;
    startedEnvironment = environment;
    return process;
  }
}

final class _DataHomeProcess extends Fake implements Process {
  _DataHomeProcess({this.oversizedStdout, this.oversizedStderr}) {
    stdin = IOSink(input.sink);
    input.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        request = jsonDecode(line) as Map<String, dynamic>;
      },
      onDone: _finish,
    );
  }

  final int? oversizedStdout;
  final int? oversizedStderr;
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  @override
  late final IOSink stdin;
  late Map<String, dynamic> request;
  var stdoutBytesRead = 0;
  var stderrBytesRead = 0;
  var killCount = 0;

  @override
  Stream<List<int>> get stdout => output.stream.map((chunk) {
    stdoutBytesRead += chunk.length;
    return chunk;
  });

  @override
  Stream<List<int>> get stderr => errors.stream.map((chunk) {
    stderrBytesRead += chunk.length;
    return chunk;
  });

  @override
  Future<int> get exitCode => exited.future;

  @override
  int get pid => 42;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount += 1;
    return true;
  }

  void _finish() {
    if (oversizedStdout case final size?) {
      output.add(List<int>.filled(size, 0, growable: false));
    } else {
      output.add(
        utf8.encode(
          '${jsonEncode({
            'protocol': conversationProtocolVersion,
            'id': request['id'],
            'workflowId': request['workflowId'],
            'ok': true,
            'result': {'status': 'relocated'},
          })}\n',
        ),
      );
    }
    if (oversizedStderr case final size?) {
      errors.add(List<int>.filled(size, 120, growable: false));
    }
    unawaited(output.close());
    unawaited(errors.close());
    exited.complete(0);
  }
}
