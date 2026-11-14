import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/contracts/plugin_window_host_port.dart';

Matcher _rejects(String code) =>
    throwsA(isA<FormatException>().having((e) => e.message, 'code', code));

PluginWindowManifest _manifest({
  String id = 'sketch.board',
  String name = 'Sketch Board',
  String iconPath = '',
  PluginWindowEntry? entry,
  PluginWindowPermissions? permissions,
}) => PluginWindowManifest(
  id: id,
  name: name,
  publisher: PluginPublisher.thirdParty,
  iconPath: iconPath,
  entry: entry ?? PluginWindowBundleEntry('index.html'),
  permissions: permissions ?? PluginWindowPermissions(),
);

void main() {
  group('manifest', () {
    test('accepts a bundle plugin and trims its name', () {
      final manifest = _manifest(name: '  Sketch Board ', iconPath: 'icon.png');
      expect(manifest.id, 'sketch.board');
      expect(manifest.name, 'Sketch Board');
      expect(manifest.iconPath, 'icon.png');
      expect(manifest.permissions.network, isEmpty);
      expect(manifest.permissions.clipboard, PluginClipboardAccess.none);
    });

    test('rejects malformed ids, names and icon paths', () {
      expect(
        () => _manifest(id: 'Sketch'),
        _rejects('plugin_window_id_invalid'),
      );
      expect(() => _manifest(id: 'a..b'), _rejects('plugin_window_id_invalid'));
      expect(
        () => _manifest(name: '  '),
        _rejects('plugin_window_name_invalid'),
      );
      expect(
        () => _manifest(name: 'x' * 65),
        _rejects('plugin_window_name_invalid'),
      );
      expect(
        () => _manifest(iconPath: '../icon.png'),
        _rejects('plugin_window_icon_invalid'),
      );
    });

    test('a remote entry must be on the network allowlist', () {
      expect(
        () => _manifest(entry: PluginWindowOriginEntry('https://app.example')),
        _rejects('plugin_window_entry_not_allowed'),
      );
      final manifest = _manifest(
        entry: PluginWindowOriginEntry('https://app.example'),
        permissions: PluginWindowPermissions(network: ['https://app.example']),
      );
      expect(
        (manifest.entry as PluginWindowOriginEntry).origin,
        'https://app.example',
      );
    });

    test('publisher and clipboard wire names parse strictly', () {
      expect(PluginPublisher.parse('official'), PluginPublisher.official);
      expect(
        () => PluginPublisher.parse('Official'),
        _rejects('plugin_window_publisher_invalid'),
      );
      expect(PluginClipboardAccess.parse('ask'), PluginClipboardAccess.ask);
      expect(
        () => PluginClipboardAccess.parse('always'),
        _rejects('plugin_window_clipboard_invalid'),
      );
    });
  });

  group('permissions', () {
    test('origins normalize to bare https origins', () {
      expect(
        normalizePluginOrigin('https://Example.com:443/'),
        'https://example.com',
      );
      expect(
        normalizePluginOrigin('https://api.example.com:8443'),
        'https://api.example.com:8443',
      );
      for (final raw in [
        'http://example.com',
        'https://example.com/path',
        'https://user@example.com',
        'https://example.com?q=1',
        'https://example.com#top',
        'file:///etc/hosts',
        'https://',
      ]) {
        expect(
          () => normalizePluginOrigin(raw),
          _rejects('plugin_window_origin_invalid'),
          reason: raw,
        );
      }
    });

    test('duplicates and malformed capabilities are rejected', () {
      expect(
        () => PluginWindowPermissions(
          network: ['https://a.example', 'https://A.example/'],
        ),
        _rejects('plugin_window_network_duplicate'),
      );
      expect(
        () => PluginWindowPermissions(capabilities: ['Notes']),
        _rejects('plugin_window_capability_invalid'),
      );
      expect(
        () => PluginWindowPermissions(capabilities: ['notes', 'notes']),
        _rejects('plugin_window_capability_duplicate'),
      );
      expect(
        () => PluginWindowPermissions(
          capabilities: [for (var i = 0; i < 33; i++) 'cap$i'],
        ),
        _rejects('plugin_window_capability_too_many'),
      );
    });

    test('declared capabilities and origins are queryable', () {
      final permissions = PluginWindowPermissions(
        network: ['https://a.example'],
        capabilities: ['notes.read'],
      );
      expect(permissions.declaresCapability('notes.read'), isTrue);
      expect(permissions.declaresCapability('notes.write'), isFalse);
      expect(permissions.allowsOrigin('https://a.example'), isTrue);
      expect(permissions.allowsOrigin('https://b.example'), isFalse);
    });
  });

  test('bundle paths stay inside the bundle', () {
    expect(isPluginBundlePath(''), isTrue);
    expect(isPluginBundlePath('pages/index.html'), isTrue);
    for (final path in [
      '/index.html',
      '../index.html',
      'pages/../../x',
      './index.html',
      'pages//index.html',
      r'pages\index.html',
      'file:index.html',
      'x' * 257,
    ]) {
      expect(isPluginBundlePath(path), isFalse, reason: path);
    }
    expect(
      () => PluginWindowBundleEntry(''),
      _rejects('plugin_window_entry_invalid'),
    );
  });

  group('session states', () {
    test('loading progress stays within [0, 1]', () {
      expect(PluginWindowLoading(progress: 0.5).progress, 0.5);
      expect(PluginWindowLoading().progress, isNull);
      expect(
        () => PluginWindowLoading(progress: 1.2),
        _rejects('plugin_window_progress_invalid'),
      );
      expect(
        () => PluginWindowLoading(progress: double.nan),
        _rejects('plugin_window_progress_invalid'),
      );
    });

    test('permission details are trimmed and bounded', () {
      final request = PluginWindowPermissionRequest(
        capability: 'clipboard',
        detail: '  ${'字' * 200}  ',
      );
      expect(request.detail.runes.length, 160);
      expect(request.detail.endsWith('…'), isTrue);
      expect(
        () => PluginWindowPermissionRequest(capability: 'Clipboard!'),
        _rejects('plugin_window_capability_invalid'),
      );
    });

    test('only stable machine codes reach the renderer', () {
      expect(
        PluginWindowError('render_process_gone').code,
        'render_process_gone',
      );
      expect(
        PluginWindowError('Crashed at bundle/index.js:12').code,
        pluginWindowFailed,
      );
      expect(PluginWindowError('').code, pluginWindowFailed);
      expect(PluginBridgeFailure('Nope!').code, pluginWindowFailed);
    });

    test('content views require a view type', () {
      expect(
        () => PluginWindowContentView(viewType: ''),
        _rejects('plugin_window_view_invalid'),
      );
      final view = PluginWindowContentView(
        viewType: 'licoup/plugin-window',
        parameters: {'session': 's1'},
      );
      expect(() => view.parameters['x'] = 'y', throwsUnsupportedError);
    });
  });

  group('bridge payloads', () {
    test('the bound counts UTF-8 bytes', () {
      expect(pluginBridgePayloadFits('a' * pluginBridgePayloadLimit), isTrue);
      expect(
        pluginBridgePayloadFits('a' * (pluginBridgePayloadLimit + 1)),
        isFalse,
      );
      // Fewer characters than the bound, but more bytes.
      expect(pluginBridgePayloadFits('é' * 40000), isFalse);
      final request = PluginBridgeRequest(
        requestId: 'r1',
        capability: 'notes.read',
        payload: 'é' * 40000,
      );
      expect(request.withinLimit, isFalse);
    });

    test('oversized successes cannot be built', () {
      expect(
        () => PluginBridgeSuccess('a' * (pluginBridgePayloadLimit + 1)),
        _rejects(pluginBridgePayloadTooLarge),
      );
    });

    test('requests need an id and a well-formed capability', () {
      expect(
        () => PluginBridgeRequest(requestId: '', capability: 'notes'),
        _rejects('plugin_bridge_request_invalid'),
      );
      expect(
        () => PluginBridgeRequest(requestId: 'r1', capability: '../x'),
        _rejects('plugin_window_capability_invalid'),
      );
    });
  });

  test(
    'the placeholder adapter has no plugins and supports no window',
    () async {
      const port = UnsupportedPluginWindowHostPort();
      expect(await port.watchCatalog().first, isEmpty);
      final session = port.open('sketch');
      expect(session.pluginId, 'sketch');
      expect(await session.states.first, isA<PluginWindowUnsupported>());
      expect(await session.requests.isEmpty, isTrue);
      await session.reload();
      await session.decidePermission(PluginPermissionDecision.deny);
      await session.close();
    },
  );
}
