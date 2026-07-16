import 'package:flutter_client/src/contracts/directory_opener.dart';

final class DirectoryPathStatusUpdate {
  const DirectoryPathStatusUpdate({
    required this.chinese,
    required this.english,
    required this.caption,
    this.error,
  });

  final String chinese;
  final String english;
  final String caption;
  final Object? error;
}

typedef DirectoryPathStatusSink =
    void Function(DirectoryPathStatusUpdate update);
typedef DirectoryCaptionProvider = String Function();

/// Independently testable application workflow for revealing directories.
final class DirectoryPathController {
  const DirectoryPathController({
    required DirectoryOpener opener,
    required DirectoryCaptionProvider defaultCaption,
    required DirectoryPathStatusSink onStatus,
  }) : _opener = opener,
       _defaultCaption = defaultCaption,
       _onStatus = onStatus;

  final DirectoryOpener _opener;
  final DirectoryCaptionProvider _defaultCaption;
  final DirectoryPathStatusSink _onStatus;

  Future<void> open(String path, {String caption = ''}) async {
    final directoryPath = path.trim();
    final resolvedCaption = caption.trim().isEmpty
        ? _defaultCaption()
        : caption.trim();
    if (directoryPath.isEmpty) {
      _onStatus(
        DirectoryPathStatusUpdate(
          chinese: '请先指定目录。',
          english: 'Choose a directory first.',
          caption: resolvedCaption,
          error: const DirectoryPathException('directory_path_not_configured'),
        ),
      );
      return;
    }

    try {
      final result = await _opener.openDirectory(directoryPath);
      if (result.exitCode == 0) {
        _onStatus(
          DirectoryPathStatusUpdate(
            chinese: '已打开目录。',
            english: 'Directory opened.',
            caption: directoryPath,
          ),
        );
        return;
      }
      _onStatus(
        DirectoryPathStatusUpdate(
          chinese: '目录打开失败。',
          english: 'Failed to open the directory.',
          caption: directoryPath,
          error: const DirectoryPathException('directory_open_failed'),
        ),
      );
    } catch (error) {
      _onStatus(
        DirectoryPathStatusUpdate(
          chinese: '目录打开失败。',
          english: 'Failed to open the directory.',
          caption: directoryPath,
          error: error,
        ),
      );
    }
  }
}

final class DirectoryPathException implements Exception {
  const DirectoryPathException(this.code);

  final String code;

  @override
  String toString() => code;
}
