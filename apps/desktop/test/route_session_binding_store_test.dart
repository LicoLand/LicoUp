import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/backend/features/routing/services/route_session_binding_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('route-bindings-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('opaque handles recover exact native sessions after restart', () {
    final first = ProtectedRouteSessionBindingStore(rootDirectory: root);
    final sourceHandle = first.bind(
      taskId: 'task-recovery',
      agentId: 'agent-a',
      nativeSessionId: 'native-source-private',
    );
    final targetHandle = first.bind(
      taskId: 'task-recovery',
      agentId: 'agent-b',
      nativeSessionId: 'native-target-private',
    );

    expect(sourceHandle, matches(RegExp(r'^rh_[A-Za-z0-9_-]{24}$')));
    expect(targetHandle, matches(RegExp(r'^rh_[A-Za-z0-9_-]{24}$')));
    expect(sourceHandle, isNot(targetHandle));

    final restarted = ProtectedRouteSessionBindingStore(rootDirectory: root);
    expect(
      restarted.bindingForHandle(sourceHandle)!.nativeSessionId,
      'native-source-private',
    );
    expect(
      restarted.currentForTask('task-recovery')!.nativeSessionId,
      'native-target-private',
    );
    expect(
      restarted
          .currentForTaskAgent(taskId: 'task-recovery', agentId: 'agent-a')
          ?.nativeSessionId,
      'native-source-private',
    );
    expect(
      restarted
          .currentForTaskAgent(taskId: 'task-recovery', agentId: 'agent-b')
          ?.nativeSessionId,
      'native-target-private',
    );
    expect(
      restarted.containsNativeSession(
        taskId: 'task-recovery',
        nativeSessionId: 'native-source-private',
      ),
      isTrue,
    );
  });

  test('private store uses task digest and owner-only POSIX permissions', () {
    final store = ProtectedRouteSessionBindingStore(rootDirectory: root);
    store.bind(
      taskId: 'private-task-name',
      agentId: 'agent-a',
      nativeSessionId: 'native-private',
    );
    final directory = Directory(
      '${root.path}/lico-client/routing/private-bindings',
    );
    final file = File('${directory.path}/bindings.json');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final binding = (decoded['bindings'] as List<dynamic>).single as Map;

    expect(file.readAsStringSync(), isNot(contains('private-task-name')));
    expect(binding['taskDigest'], matches(RegExp(r'^[a-f0-9]{64}$')));
    if (!Platform.isWindows) {
      expect(directory.statSync().mode & 0x1ff, 0x1c0); // 0700
      expect(file.statSync().mode & 0x1ff, 0x180); // 0600
    }
  });

  test('clearing a task removes every exact native binding', () {
    final store = ProtectedRouteSessionBindingStore(rootDirectory: root);
    final handle = store.bind(
      taskId: 'task-clear',
      agentId: 'agent-a',
      nativeSessionId: 'native-clear',
    );

    store.clearTask('task-clear');

    final restarted = ProtectedRouteSessionBindingStore(rootDirectory: root);
    expect(restarted.bindingForHandle(handle), isNull);
    expect(restarted.currentForTask('task-clear'), isNull);
    expect(
      restarted.currentForTaskAgent(taskId: 'task-clear', agentId: 'agent-a'),
      isNull,
    );
    expect(
      restarted.containsNativeSession(
        taskId: 'task-clear',
        nativeSessionId: 'native-clear',
      ),
      isFalse,
    );
  });
}
