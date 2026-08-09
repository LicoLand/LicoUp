import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/contracts/client_update_gateway.dart';

export 'package:licoup/src/contracts/client_update_models.dart';

class ClientUpdateService implements ClientUpdateGateway {
  const ClientUpdateService();

  static const _manifestUrl =
      'https://github.com/LicoLand/LicoUp/releases/latest/download/LicoUp-update-stable.json';
  static const _publicKeysJson =
      '{"keys":{"licoup-update-offline-root-v1":{"publicKey":"GrICHXUYU+aX7qR2UiZC90Uj/XWssMrVKDZx6vDdkgg="},"licoup-update-online-channel-v1":{"publicKey":"5OWD3HUFAlukj9Ha9ubH9864ni81eDrHfjxBrskpXU4="}}}';
  static const _maxMetadataBytes = 1024 * 1024;
  static const _maxArtifactBytes = 1024 * 1024 * 1024;

  @override
  Future<bool> autoDownloadOverWifiEnabled() async {
    final file = await _preferenceFile();
    if (!await file.exists()) return true;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map && value['autoDownloadOverWifi'] != false;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> setAutoDownloadOverWifiEnabled(bool enabled) async {
    final file = await _preferenceFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'autoDownloadOverWifi': enabled}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  @override
  Future<bool> isWifiConnected() async {
    if (!Platform.isMacOS) return false;
    final ports = await Process.run('/usr/sbin/networksetup', const [
      '-listallhardwareports',
    ]);
    if (ports.exitCode != 0) return false;
    final match = RegExp(
      r'Hardware Port: (?:Wi-Fi|AirPort)\s+Device: ([A-Za-z0-9._-]+)',
    ).firstMatch(ports.stdout.toString());
    final device = match?.group(1);
    if (device == null) return false;
    final state = await Process.run('/sbin/ifconfig', [device]);
    return state.exitCode == 0 &&
        RegExp(
          r'^\s*status:\s*active\s*$',
          multiLine: true,
        ).hasMatch(state.stdout.toString());
  }

  @override
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  }) async {
    final output = await agentService.runCli([
      'update',
      'status',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
    ]);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateRemoteCheck> check({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  }) async {
    final root = await Directory.systemTemp.createTemp('licoup-update-');
    final manifestPath = '${root.path}/manifest.json';
    final publicKeysPath = '${root.path}/public-keys.json';
    final manifestBytes = await _downloadBytes(
      Uri.parse(_manifestUrl),
      maxBytes: _maxMetadataBytes,
    );
    await File(manifestPath).writeAsBytes(manifestBytes, flush: true);
    await File(publicKeysPath).writeAsString(_publicKeysJson, flush: true);
    final args = [
      'update',
      'check',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
    ];
    final output = await agentService.runCli(args);
    final status = ClientUpdateStatus.fromJson(output);
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    final artifactUrl = status.updateAvailable
        ? _verifiedArtifactUrl(manifest, status)
        : '';
    return ClientUpdateRemoteCheck(
      status: status,
      manifestPath: manifestPath,
      publicKeysPath: publicKeysPath,
      artifactUrl: artifactUrl,
    );
  }

  @override
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String artifactUrl,
    required int expectedBytes,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    if (expectedBytes <= 0 || expectedBytes > _maxArtifactBytes) {
      throw StateError('client_update_artifact_size_invalid');
    }
    final uri = Uri.parse(artifactUrl);
    _requireGitHubReleaseAsset(uri);
    final sourcePath = '${File(manifestPath).parent.path}/artifact.download';
    await _downloadFile(uri, File(sourcePath), expectedBytes: expectedBytes);
    final args = [
      'update',
      'download',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--source-path',
      sourcePath.trim(),
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'verify',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> apply({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'apply',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--execute',
      'true',
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  Future<List<int>> _downloadBytes(Uri uri, {required int maxBytes}) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', uri));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('client_update_http_status');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          throw StateError('client_update_download_too_large');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  Future<void> _downloadFile(
    Uri uri,
    File destination, {
    required int expectedBytes,
  }) async {
    final client = http.Client();
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    var received = 0;
    try {
      final response = await client.send(http.Request('GET', uri));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('client_update_http_status');
      }
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > expectedBytes) {
          throw StateError('client_update_artifact_oversized');
        }
        sink.add(chunk);
      }
      await sink.flush();
      if (received != expectedBytes) {
        throw StateError('client_update_artifact_truncated');
      }
    } finally {
      await sink.close();
      client.close();
    }
  }

  String _verifiedArtifactUrl(dynamic document, ClientUpdateStatus status) {
    if (document is! Map<String, dynamic>) {
      throw const FormatException('client_update_manifest_invalid');
    }
    final releases = document['releases'];
    if (releases is! List) {
      throw const FormatException('client_update_releases_invalid');
    }
    for (final release in releases.whereType<Map>()) {
      if (release['version'] != status.availableVersion) continue;
      final artifacts = release['artifacts'];
      if (artifacts is! List) continue;
      for (final artifact in artifacts.whereType<Map>()) {
        if (artifact['targetId'] != status.targetId) continue;
        final value = artifact['url'];
        if (value is! String) break;
        final uri = Uri.parse(value);
        _requireGitHubReleaseAsset(uri);
        return value;
      }
    }
    throw const FormatException('client_update_artifact_url_missing');
  }

  void _requireGitHubReleaseAsset(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/LicoLand/LicoUp/releases/download/') ||
        uri.pathSegments.last != 'LicoUp-macos-arm64-update.tar.gz') {
      throw const FormatException('client_update_artifact_url_forbidden');
    }
  }

  Future<File> _preferenceFile() async {
    final root = await getApplicationSupportDirectory();
    return File('${root.path}/client-update-preferences.json');
  }
}
