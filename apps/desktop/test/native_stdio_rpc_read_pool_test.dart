import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/read_policy.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/read_pool.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

void main() {
  test('query routes leave lifecycle and process-owned commands ordered', () {
    for (final arguments in [
      ['agent-hub', 'catalog', '--agent-id', 'synthetic-agent'],
      ['adapter', 'catalog'],
      ['agent-usage', 'report'],
      ['agents', 'pair', 'list'],
      ['conversations', 'list', '--agent', 'synthetic-agent'],
      ['skill', 'list', '--agent', 'synthetic-agent'],
      ['skill', 'usage', 'report'],
    ]) {
      expect(stdioRpcArgsUseReadPool(arguments), isTrue);
    }
    for (final arguments in [
      ['agent-hub', 'apply'],
      ['agent-hub', 'plan'],
      ['adapter', 'antigravity', 'install'],
      ['agent-usage', 'scan'],
      ['agents', 'pair', 'approve'],
      ['skill', 'delete', 'apply'],
      ['skill', 'usage', 'scan'],
      ['llm-gateway', 'list'],
      ['state', 'admit', '/fixture/data'],
      ['unknown', 'catalog'],
      ['conversation', 'list'],
    ]) {
      expect(stdioRpcArgsUseReadPool(arguments), isFalse);
    }
  });

  test(
    'fast independent reads finish while a slow catalog remains pending',
    () async {
      final slowStarted = Completer<_Request>();
      final context = _ProcessContext((request) {
        if (request.args.contains('slow')) {
          slowStarted.complete(request);
        } else {
          request.reply({'ok': true, 'kind': request.args.first});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      var slowDone = false;
      final slow = client.execute([
        'agent-hub',
        'catalog',
        '--agent-id',
        'slow',
      ])..then((_) => slowDone = true);
      final held = await slowStarted.future;
      final outputs = await Future.wait([
        client.execute(['adapter', 'catalog']),
        client.execute(['skill', 'list', '--agent', 'synthetic-agent']),
        client.execute(['agent-usage', 'report']),
      ]);

      expect(outputs.map((output) => output['kind']), [
        'adapter',
        'skill',
        'agent-usage',
      ]);
      expect(slowDone, isFalse);
      expect(context.processes, hasLength(StdioRpcReadPool.capacity));
      held.reply({'ok': true});
      await slow;
    },
  );

  test(
    'a fast Agent history list is independent of a slow Agent list',
    () async {
      final slowStarted = Completer<_Request>();
      final context = _ProcessContext((request) {
        if (request.args.last == 'slow') {
          slowStarted.complete(request);
        } else {
          request.reply({'ok': true, 'agent': request.args.last});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      var slowDone = false;
      final slow = client.execute(['conversations', 'list', '--agent', 'slow'])
        ..then((_) => slowDone = true);
      final held = await slowStarted.future;
      expect(
        await client.execute(['conversations', 'list', '--agent', 'fast']),
        {'ok': true, 'agent': 'fast'},
      );
      expect(slowDone, isFalse);
      held.reply({'ok': true});
      await slow;
    },
  );

  test(
    'read sessions are bounded, reused, and dispatch pending foreground first',
    () async {
      final occupied = Completer<void>();
      final held = <_Request>[];
      final order = <String>[];
      final context = _ProcessContext((request) {
        final key = request.args.last;
        if (key.startsWith('held-')) {
          held.add(request);
          if (held.length == StdioRpcReadPool.capacity) occupied.complete();
        } else {
          order.add(key);
          request.reply({'ok': true});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      final blocked = [
        for (var i = 0; i < StdioRpcReadPool.capacity; i++)
          client.execute(['agent-hub', 'catalog', '--agent-id', 'held-$i']),
      ];
      await occupied.future;
      final background = runWithRpcPriorityToken(
        RpcPriorityToken(background: true),
        () => client.execute([
          'agent-hub',
          'catalog',
          '--agent-id',
          'background',
        ]),
      );
      final foreground = client.execute([
        'agent-hub',
        'catalog',
        '--agent-id',
        'foreground',
      ]);
      expect(context.processes, hasLength(StdioRpcReadPool.capacity));
      final close = client.dispose();
      held.first.reply({'ok': true});
      await Future.wait([background, foreground]);
      expect(order, ['foreground', 'background']);
      expect(context.processes, hasLength(StdioRpcReadPool.capacity));
      for (final request in held.skip(1)) {
        request.reply({'ok': true});
      }
      await Future.wait(blocked);
      await close;
    },
  );

  test('a read failure releases its session for later queries', () async {
    final context = _ProcessContext((request) => request.reply({'ok': true}))
      ..failSetup = true;
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);
    await expectLater(
      client.execute(['adapter', 'catalog']),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'setup_failed',
        ),
      ),
    );
    context.failSetup = false;
    expect(await client.execute(['adapter', 'catalog']), {'ok': true});
    expect(context.processes, hasLength(1));
  });

  test('queries can outwait the ordinary command watchdog', () async {
    final started = Completer<_Request>();
    final context = _ProcessContext(
      started.complete,
      requestTimeout: const Duration(microseconds: 1),
    );
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);
    final query = client.execute(['adapter', 'catalog']);
    final held = await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(context.processes.single.killed, isFalse);
    held.reply({'ok': true});
    expect(await query, {'ok': true});
  });

  test(
    'mutations retain ordering and a later read sees committed state',
    () async {
      final mutationStarted = Completer<_Request>();
      final mutations = <String>[];
      var revision = 0;
      final context = _ProcessContext((request) {
        if (request.args.first == 'mutate') {
          mutations.add(request.args.last);
          if (request.args.last == 'first') {
            mutationStarted.complete(request);
          } else {
            revision++;
            request.reply({'ok': true});
          }
        } else {
          request.reply({'revision': revision});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      final first = client.execute(['mutate', 'first']);
      final second = client.execute(['mutate', 'second']);
      final held = await mutationStarted.future;
      expect(await client.execute(['adapter', 'catalog']), {'revision': 0});
      expect(mutations, ['first']);
      held.reply({'ok': true});
      await Future.wait([first, second]);
      expect(mutations, ['first', 'second']);
      expect(await client.execute(['adapter', 'catalog']), {'revision': 1});
      expect(context.processes, hasLength(2));
    },
  );

  test(
    'dispose closes idle peers and drains accepted reads without cancelling them',
    () async {
      final slowStarted = Completer<_Request>();
      final context = _ProcessContext((request) {
        if (request.args.first == 'agent-hub') {
          slowStarted.complete(request);
        } else {
          request.reply({'ok': true});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      final slow = client.execute(['agent-hub', 'catalog']);
      final held = await slowStarted.future;
      await client.execute(['adapter', 'catalog']);
      final idle = context.processes.last;
      var disposed = false;
      final close = client.dispose()..then((_) => disposed = true);
      await idle.exitCode;

      expect(idle.killed, isFalse);
      expect(disposed, isFalse);
      expect(context.processes.first.killed, isFalse);
      await expectLater(
        client.execute(['skill', 'list']),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'service_disposed',
          ),
        ),
      );
      held.reply({'ok': true});
      await Future.wait([slow, close]);
      expect(context.processes.every((process) => !process.killed), isTrue);
      await client.dispose();
    },
  );
}

class _ProcessContext implements NativeCliProcessContext {
  _ProcessContext(
    this.onRequest, {
    this.requestTimeout = const Duration(seconds: 5),
  });

  final void Function(_Request) onRequest;
  final List<_Process> processes = [];
  bool failSetup = false;

  @override
  final Duration requestTimeout;

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    if (failSetup) throw StateError('synthetic setup failure');
    return null;
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
    final process = _Process(onRequest);
    processes.add(process);
    return process;
  }
}

class _Request {
  _Request(this.process, this.frame);

  final _Process process;
  final Map<String, dynamic> frame;

  List<String> get args => (frame['args'] as List).cast<String>();

  void reply(Map<String, dynamic> result) {
    process.output.add(
      utf8.encode(
        '${jsonEncode({'protocol': 'licoup.stdio.v1', 'id': frame['id'], 'workflowId': frame['workflowId'], 'ok': true, 'result': result})}\n',
      ),
    );
  }
}

class _Process implements Process {
  _Process(void Function(_Request) onRequest) {
    stdin = IOSink(input.sink);
    input.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final frame = jsonDecode(line) as Map<String, dynamic>;
        final request = _Request(this, frame);
        if (frame['method'] == 'shutdown') {
          request.reply({});
          unawaited(output.close());
          unawaited(errors.close());
          exited.complete(0);
        } else {
          onRequest(request);
        }
      },
    );
  }

  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  bool killed = false;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => errors.stream;

  @override
  Future<int> get exitCode => exited.future;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) {
      unawaited(output.close());
      unawaited(errors.close());
      exited.complete(-1);
    }
    return true;
  }
}
