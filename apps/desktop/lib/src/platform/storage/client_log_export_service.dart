import 'dart:io';
import 'dart:math';

import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

class ClientLogExportResult {
  const ClientLogExportResult({
    required this.path,
    required this.bytes,
    required this.sourceExists,
  });

  final String path;
  final int bytes;
  final bool sourceExists;
}

class ClientLogExportService {
  const ClientLogExportService({this.maxExportBytes = 64 * 1024 * 1024});

  final int maxExportBytes;

  Future<ClientLogExportResult> exportLogs({
    required PortableDataRoot portableData,
    required String destinationPath,
  }) async {
    final trimmed = destinationPath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(destinationPath, 'destinationPath');
    }

    final requestedDestination = File(p.normalize(p.absolute(trimmed)));
    final rawSource = await portableData.activityLogFile();
    final source = File(
      await _canonicalizeParentWithoutFollowingLeaf(rawSource.path),
    );
    final destination = File(
      await _canonicalizeParentWithoutFollowingLeaf(requestedDestination.path),
    );
    await _ensureDirectoryTreeWithoutLinks(destination.parent);
    await _rejectSymbolicLinkLeaf(source.path);
    await _rejectSymbolicLinkLeaf(destination.path);

    final sourceExists = await source.exists();
    if (sourceExists &&
        await destination.exists() &&
        await FileSystemEntity.identical(source.path, destination.path)) {
      throw const FileSystemException(
        'Client log source and export destination must be different files.',
      );
    }

    RandomAccessFile? sourceHandle;
    RandomAccessFile? temporaryHandle;
    final temporary = File(
      p.join(
        destination.parent.path,
        '.${p.basename(destination.path)}.$pid.${_secureNonce()}.tmp',
      ),
    );
    var exportedBytes = 0;
    if (sourceExists) {
      final sourceLength = await source.length();
      if (sourceLength > maxExportBytes) {
        throw FileSystemException(
          'Client log exceeds the maximum export size.',
          source.path,
        );
      }
    }

    try {
      if (sourceExists) {
        sourceHandle = await source.open(mode: FileMode.read);
        await _rejectSymbolicLinkLeaf(source.path, requireExisting: true);
      }
      await temporary.create(exclusive: true);
      temporaryHandle = await temporary.open(mode: FileMode.writeOnly);
      if (sourceHandle != null) {
        while (true) {
          final chunk = await sourceHandle.read(64 * 1024);
          if (chunk.isEmpty) {
            break;
          }
          exportedBytes += chunk.length;
          if (exportedBytes > maxExportBytes) {
            throw FileSystemException(
              'Client log exceeded the maximum export size while reading.',
              source.path,
            );
          }
          await temporaryHandle.writeFrom(chunk);
        }
      }
      await temporaryHandle.flush();
      await temporaryHandle.close();
      temporaryHandle = null;
      await sourceHandle?.close();
      sourceHandle = null;

      await _rejectSymbolicLinkLeaf(destination.path);
      if (sourceExists &&
          await destination.exists() &&
          await FileSystemEntity.identical(source.path, destination.path)) {
        throw const FileSystemException(
          'Client log source and export destination became the same file.',
        );
      }
      // Rename is the only live-destination mutation. Platforms that cannot atomically replace
      // an existing file fail closed instead of deleting it before the commit.
      await temporary.rename(destination.path);
    } catch (_) {
      await sourceHandle?.close();
      await temporaryHandle?.close();
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }

    return ClientLogExportResult(
      path: requestedDestination.path,
      bytes: exportedBytes,
      sourceExists: sourceExists,
    );
  }

  Future<void> _ensureDirectoryTreeWithoutLinks(Directory directory) async {
    final absolute = Directory(p.normalize(p.absolute(directory.path)));
    final ancestors = <Directory>[];
    var current = absolute;
    while (true) {
      ancestors.add(current);
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    for (final ancestor in ancestors.reversed) {
      final type = await FileSystemEntity.type(
        ancestor.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        throw FileSystemException(
          'Client log export path contains a symbolic-link directory.',
          ancestor.path,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        await ancestor.create();
        final createdType = await FileSystemEntity.type(
          ancestor.path,
          followLinks: false,
        );
        if (createdType != FileSystemEntityType.directory) {
          throw FileSystemException(
            'Client log export directory changed during creation.',
            ancestor.path,
          );
        }
      } else if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Client log export parent is not a directory.',
          ancestor.path,
        );
      }
    }
  }

  Future<String> _canonicalizeParentWithoutFollowingLeaf(String path) async {
    final absolute = p.normalize(p.absolute(path));
    var ancestor = Directory(p.dirname(absolute));
    final missingDirectories = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(
        ancestor.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.link) {
          throw FileSystemException(
            'Client log export ancestor is not a directory.',
            ancestor.path,
          );
        }
        break;
      }
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) {
        throw FileSystemException(
          'Client log export has no existing directory ancestor.',
          absolute,
        );
      }
      missingDirectories.add(p.basename(ancestor.path));
      ancestor = parent;
    }
    var canonicalParent = await ancestor.resolveSymbolicLinks();
    for (final directoryName in missingDirectories.reversed) {
      canonicalParent = p.join(canonicalParent, directoryName);
    }
    return p.join(canonicalParent, p.basename(absolute));
  }

  Future<void> _rejectSymbolicLinkLeaf(
    String path, {
    bool requireExisting = false,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FileSystemException(
        'Client log source and destination must not be symbolic links.',
        path,
      );
    }
    if (requireExisting && type == FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Client log path disappeared during validation.',
        path,
      );
    }
  }

  String _secureNonce() {
    final random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
      growable: false,
    ).join();
  }
}
