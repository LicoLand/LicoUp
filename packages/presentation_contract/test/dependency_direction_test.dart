import 'dart:io';

import 'package:test/test.dart';

/// A03 dependency-direction probes for the C04 contract package.
///
/// The oracle is the real analyzer dependency graph, never a class name or a
/// directory string: every probe below is a real Dart library handed to
/// `dart analyze` inside this package's own resolution context.
///
/// * A consumer-owned port implementation resolves against the contract alone.
/// * An out-of-bounds reference into the presentation runtime that consumes the
///   contract, into the view implementation layer, or into the client transport
///   that owns RPC must fail with the analyzer's own unresolved-URI diagnostic
///   for that exact URI.
///
/// The same probe bodies prove the fail side is caused by the dependency and
/// not by an unrelated syntax error: the legal probe shares every contract
/// symbol used by the illegal ones.
const String _legalConsumerPort = r'''
import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

/// Consumer-owned ports: implementations live outside this package.
final class ProbeSource implements PresentationSource<String> {
  const ProbeSource(this.fieldGroup);

  @override
  final ResourceFieldGroup<String> fieldGroup;

  @override
  Future<SourceObservation<String>> open() async => SourceObservation<String>(
    initial: ResourceSnapshot<String>(
      fieldGroup: fieldGroup,
      epoch: const SourceEpoch('probe'),
      version: const SourceVersion(1),
      value: 'value',
    ),
    changes: const Stream<SourceChange<String>>.empty(),
  );
}

final class ProbeInstaller implements PresentationInstaller<String> {
  const ProbeInstaller();

  @override
  bool install(
    PreparedResource<String> result,
    PreparationAcceptance<String> acceptance,
  ) => acceptance.canInstall(result) && result.value.isNotEmpty;
}

final class ProbeActions implements PresentationActions<String> {
  const ProbeActions();

  @override
  ActionOrigin get origin => const ActionOrigin(scope: ResourceScope('probe'));

  @override
  FutureOr<void> dispatch(String action) {}
}
''';

const String _illegalRuntimeReference = r'''
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

/// Out of bounds: the contract reaching into the runtime that consumes it.
final class DelegatingInstaller implements PresentationInstaller<String> {
  const DelegatingInstaller(this.inner);

  final PreparedResourceInstaller<String> inner;

  @override
  bool install(
    PreparedResource<String> result,
    PreparationAcceptance<String> acceptance,
  ) => inner.install(result, acceptance);
}
''';

const String _illegalViewReference = r'''
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

/// Out of bounds: the contract reaching into the Flutter view implementation.
Widget contractSidePreview(PreparedResource<String> result) =>
    Text(result.value);
''';

const String _illegalTransportReference = r'''
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:presentation_contract/presentation_contract.dart';

/// Out of bounds: the contract reaching into the client transport that owns
/// the RPC surface.
NativeStdioRpcClient contractSideTransport() => throw UnimplementedError();
''';

const List<String> _illegalUris = <String>[
  'package:presentation_runtime/presentation_runtime.dart',
  'package:flutter/material.dart',
  'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart',
];

void main() {
  late final Directory packageRoot = _packageRoot();
  late final Directory probes = Directory(
    '${packageRoot.path}/.dart_tool/v7-f0/dependency-direction/'
    '${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);

  test(
    'a consumer-owned port implementation resolves against the contract',
    () async {
      final file = _write(
        probes,
        'legal_consumer_port.dart',
        _legalConsumerPort,
      );
      final result = await _analyze(file, packageRoot);
      final output = _transcript(file, result, packageRoot);
      expect(result.exitCode, 0, reason: output);
      expect(output, contains('No issues found'), reason: output);
    },
  );

  for (final uri in _illegalUris) {
    final layer = uri.split('/').first;
    test('an out-of-bounds $layer reference fails to resolve', () async {
      final source = switch (uri) {
        'package:presentation_runtime/presentation_runtime.dart' =>
          _illegalRuntimeReference,
        'package:flutter/material.dart' => _illegalViewReference,
        _ => _illegalTransportReference,
      };
      final file = _write(
        probes,
        'illegal_${layer.replaceAll(':', '_')}.dart',
        source,
      );
      final result = await _analyze(file, packageRoot);
      final output = _transcript(file, result, packageRoot);
      expect(result.exitCode, isNot(0), reason: output);
      expect(
        output,
        contains('uri_does_not_exist'),
        reason: 'the analyzer must refuse the undeclared dependency: $output',
      );
      expect(
        output,
        contains('Target of URI doesn\'t exist: \'$uri\''),
        reason: 'the refusal must name the out-of-bounds URI: $output',
      );
    });
  }
}

File _write(Directory probes, String name, String source) =>
    File('${probes.path}/$name')..writeAsStringSync(source);

/// Records the analyzer session next to the probe and returns it, so the same
/// bytes are the test's assertion source, the printed log, and the audit trail.
/// Paths are package-relative so logs carry no machine-specific prefix.
String _transcript(File probe, ProcessResult result, Directory packageRoot) {
  final label = probe.absolute.path.replaceFirst(
    '${packageRoot.absolute.path}/',
    '',
  );
  final output =
      'analyze $label (exit ${result.exitCode})\n'
      '${result.stdout}${result.stderr}';
  File('${probe.path}.analyzer.log').writeAsStringSync(output);
  print(output);
  return output;
}

Future<ProcessResult> _analyze(File file, Directory packageRoot) => Process.run(
  Platform.resolvedExecutable,
  <String>['analyze', file.absolute.path],
  workingDirectory: packageRoot.path,
);

/// The package root, whether the suite runs from this package or the checkout.
Directory _packageRoot() {
  for (final candidate in <Directory>[
    Directory.current.absolute,
    Directory(
      '${Directory.current.absolute.path}/packages/presentation_contract',
    ),
  ]) {
    var directory = candidate;
    while (true) {
      final pubspec = File('${directory.path}/pubspec.yaml');
      if (pubspec.existsSync() &&
          pubspec.readAsStringSync().contains('name: presentation_contract')) {
        return directory;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        break;
      }
      directory = parent;
    }
  }
  throw StateError(
    'presentation_contract package root not found from '
    '${Directory.current.path}',
  );
}
