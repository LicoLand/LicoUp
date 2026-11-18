import 'dart:collection';
import 'dart:convert';

/// Stable machine codes of the plugin window host. Adapters report only
/// these or other codes matching [pluginWindowStableCode]; free-form text
/// never reaches the renderer.
const String pluginWindowUnsupported = 'plugin_window_unsupported';
const String pluginWindowNotInstalled = 'plugin_window_not_installed';
const String pluginWindowFailed = 'plugin_window_failed';
const String pluginCapabilityUndeclared = 'plugin_capability_undeclared';
const String pluginCapabilityUnavailable = 'plugin_capability_unavailable';
const String pluginBridgePayloadTooLarge = 'plugin_bridge_payload_too_large';

final RegExp pluginWindowStableCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Upper bound of one bridge payload in UTF-8 bytes, in either direction.
const int pluginBridgePayloadLimit = 64 * 1024;

const int _maxNetworkOrigins = 32;
const int _maxCapabilities = 32;
const int _maxNameLength = 64;
final RegExp _pluginId = RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)*$');
final RegExp _capabilityId = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');

/// Who publishes a plugin. Official plugins are signed by LicoLand; every
/// other publisher is third party and always shown as such.
enum PluginPublisher {
  official('official'),
  thirdParty('thirdParty');

  const PluginPublisher(this.wire);

  final String wire;

  static PluginPublisher parse(String value) {
    for (final publisher in values) {
      if (publisher.wire == value) return publisher;
    }
    throw const FormatException('plugin_window_publisher_invalid');
  }
}

/// Clipboard access a plugin declares; `ask` prompts on every use.
enum PluginClipboardAccess {
  none('none'),
  ask('ask'),
  allow('allow');

  const PluginClipboardAccess(this.wire);

  final String wire;

  static PluginClipboardAccess parse(String value) {
    for (final access in values) {
      if (access.wire == value) return access;
    }
    throw const FormatException('plugin_window_clipboard_invalid');
  }
}

/// Declared permissions. Local files are never granted: a plugin reads only
/// its own bundle and its per-plugin storage partition, so the manifest has
/// no file permission to declare.
final class PluginWindowPermissions {
  factory PluginWindowPermissions({
    Iterable<String> network = const [],
    PluginClipboardAccess clipboard = PluginClipboardAccess.none,
    Iterable<String> capabilities = const [],
  }) {
    final origins = <String>{};
    for (final raw in network) {
      if (!origins.add(normalizePluginOrigin(raw))) {
        throw const FormatException('plugin_window_network_duplicate');
      }
    }
    if (origins.length > _maxNetworkOrigins) {
      throw const FormatException('plugin_window_network_too_many');
    }
    final capabilityIds = <String>{};
    for (final capability in capabilities) {
      if (capability.length > 64 || !_capabilityId.hasMatch(capability)) {
        throw const FormatException('plugin_window_capability_invalid');
      }
      if (!capabilityIds.add(capability)) {
        throw const FormatException('plugin_window_capability_duplicate');
      }
    }
    if (capabilityIds.length > _maxCapabilities) {
      throw const FormatException('plugin_window_capability_too_many');
    }
    return PluginWindowPermissions._(
      network: UnmodifiableListView(origins.toList(growable: false)),
      clipboard: clipboard,
      capabilities: UnmodifiableListView(capabilityIds.toList(growable: false)),
    );
  }

  const PluginWindowPermissions._({
    required this.network,
    required this.clipboard,
    required this.capabilities,
  });

  /// Allowed `https` origins, normalized to `https://host[:port]`.
  final List<String> network;
  final PluginClipboardAccess clipboard;

  /// LicoUp capability ids the plugin may call through the message bridge.
  final List<String> capabilities;

  bool allowsOrigin(String origin) => network.contains(origin);

  bool declaresCapability(String capability) =>
      capabilities.contains(capability);
}

/// Normalizes an allowlist entry to `https://host[:port]`. Anything other
/// than a bare `https` origin is rejected.
String normalizePluginOrigin(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('plugin_window_origin_invalid');
  }
  final host = uri.host.toLowerCase();
  return uri.hasPort && uri.port != 443
      ? 'https://$host:${uri.port}'
      : 'https://$host';
}

/// Where a plugin window loads its content from.
sealed class PluginWindowEntry {
  const PluginWindowEntry();
}

/// A page inside the packaged local bundle; the default entry kind.
final class PluginWindowBundleEntry extends PluginWindowEntry {
  factory PluginWindowBundleEntry(String path) {
    if (!isPluginBundlePath(path) || path.isEmpty) {
      throw const FormatException('plugin_window_entry_invalid');
    }
    return PluginWindowBundleEntry._(path);
  }

  const PluginWindowBundleEntry._(this.path);

  final String path;
}

/// A remote `https` origin; valid only when the network allowlist lists it.
final class PluginWindowOriginEntry extends PluginWindowEntry {
  factory PluginWindowOriginEntry(String origin) =>
      PluginWindowOriginEntry._(normalizePluginOrigin(origin));

  const PluginWindowOriginEntry._(this.origin);

  final String origin;
}

/// A relative path that stays inside the plugin bundle: no scheme, no
/// absolute root, no parent traversal. Empty means "no file".
bool isPluginBundlePath(String path) {
  if (path.isEmpty) return true;
  if (path.length > 256 || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  if (path.contains(':')) return false;
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

/// One installed UI plugin as declared by its manifest.
final class PluginWindowManifest {
  factory PluginWindowManifest({
    required String id,
    required String name,
    required PluginPublisher publisher,
    String iconPath = '',
    required PluginWindowEntry entry,
    required PluginWindowPermissions permissions,
  }) {
    if (id.length > 128 || !_pluginId.hasMatch(id)) {
      throw const FormatException('plugin_window_id_invalid');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > _maxNameLength) {
      throw const FormatException('plugin_window_name_invalid');
    }
    if (!isPluginBundlePath(iconPath)) {
      throw const FormatException('plugin_window_icon_invalid');
    }
    if (entry is PluginWindowOriginEntry &&
        !permissions.allowsOrigin(entry.origin)) {
      throw const FormatException('plugin_window_entry_not_allowed');
    }
    return PluginWindowManifest._(
      id: id,
      name: trimmed,
      publisher: publisher,
      iconPath: iconPath,
      entry: entry,
      permissions: permissions,
    );
  }

  const PluginWindowManifest._({
    required this.id,
    required this.name,
    required this.publisher,
    required this.iconPath,
    required this.entry,
    required this.permissions,
  });

  final String id;
  final String name;
  final PluginPublisher publisher;

  /// Bundle-relative icon path; empty when the plugin ships no icon.
  final String iconPath;
  final PluginWindowEntry entry;
  final PluginWindowPermissions permissions;
}

/// The adapter-supplied platform view hosting a ready plugin window.
final class PluginWindowContentView {
  factory PluginWindowContentView({
    required String viewType,
    Map<String, String> parameters = const {},
  }) {
    if (viewType.isEmpty || viewType.length > 128) {
      throw const FormatException('plugin_window_view_invalid');
    }
    return PluginWindowContentView._(
      viewType: viewType,
      parameters: UnmodifiableMapView(Map<String, String>.of(parameters)),
    );
  }

  const PluginWindowContentView._({
    required this.viewType,
    required this.parameters,
  });

  final String viewType;
  final Map<String, String> parameters;
}

/// Session state reported by the adapter.
sealed class PluginWindowState {
  const PluginWindowState();
}

final class PluginWindowLoading extends PluginWindowState {
  factory PluginWindowLoading({double? progress}) {
    if (progress != null && (progress.isNaN || progress < 0 || progress > 1)) {
      throw const FormatException('plugin_window_progress_invalid');
    }
    return PluginWindowLoading._(progress);
  }

  const PluginWindowLoading._(this.progress);

  /// Load progress in `[0, 1]`; null while indeterminate.
  final double? progress;
}

final class PluginWindowReady extends PluginWindowState {
  const PluginWindowReady(this.content);

  final PluginWindowContentView content;
}

/// The plugin asked for a declared capability that needs the user's
/// decision. [detail] is a short plugin-supplied explanation.
final class PluginWindowPermissionRequest extends PluginWindowState {
  factory PluginWindowPermissionRequest({
    required String capability,
    String detail = '',
  }) {
    if (!_capabilityId.hasMatch(capability)) {
      throw const FormatException('plugin_window_capability_invalid');
    }
    final runes = detail.trim().runes;
    return PluginWindowPermissionRequest._(
      capability,
      runes.length > 160
          ? '${String.fromCharCodes(runes.take(159))}…'
          : String.fromCharCodes(runes),
    );
  }

  const PluginWindowPermissionRequest._(this.capability, this.detail);

  final String capability;
  final String detail;
}

/// The capability id used when a plugin asks for clipboard access under
/// the `ask` clipboard policy.
const String pluginClipboardCapability = 'clipboard';

final class PluginWindowError extends PluginWindowState {
  /// Codes that are not stable machine codes collapse to
  /// [pluginWindowFailed].
  factory PluginWindowError(String code) => PluginWindowError._(
    pluginWindowStableCode.hasMatch(code) ? code : pluginWindowFailed,
  );

  const PluginWindowError._(this.code);

  final String code;
}

final class PluginWindowOffline extends PluginWindowState {
  const PluginWindowOffline();
}

final class PluginWindowUnsupported extends PluginWindowState {
  const PluginWindowUnsupported();
}

enum PluginPermissionDecision { allowOnce, allowAlways, deny }

/// One typed bridge request from a plugin, addressed to a capability id.
final class PluginBridgeRequest {
  factory PluginBridgeRequest({
    required String requestId,
    required String capability,
    String payload = '',
  }) {
    if (requestId.isEmpty || requestId.length > 64) {
      throw const FormatException('plugin_bridge_request_invalid');
    }
    if (!_capabilityId.hasMatch(capability)) {
      throw const FormatException('plugin_window_capability_invalid');
    }
    return PluginBridgeRequest._(requestId, capability, payload);
  }

  const PluginBridgeRequest._(this.requestId, this.capability, this.payload);

  final String requestId;
  final String capability;

  /// JSON text; may exceed the bound, which the host refuses.
  final String payload;

  bool get withinLimit => pluginBridgePayloadFits(payload);
}

bool pluginBridgePayloadFits(String payload) =>
    payload.length <= pluginBridgePayloadLimit &&
    utf8.encode(payload).length <= pluginBridgePayloadLimit;

sealed class PluginBridgeResponse {
  const PluginBridgeResponse();
}

final class PluginBridgeSuccess extends PluginBridgeResponse {
  factory PluginBridgeSuccess(String payload) {
    if (!pluginBridgePayloadFits(payload)) {
      throw const FormatException(pluginBridgePayloadTooLarge);
    }
    return PluginBridgeSuccess._(payload);
  }

  const PluginBridgeSuccess._(this.payload);

  final String payload;
}

final class PluginBridgeFailure extends PluginBridgeResponse {
  factory PluginBridgeFailure(String code) => PluginBridgeFailure._(
    pluginWindowStableCode.hasMatch(code) ? code : pluginWindowFailed,
  );

  const PluginBridgeFailure._(this.code);

  final String code;
}
