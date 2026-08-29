import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:gravity_torrent/storage/shared_preferences.dart';

class AutoExtractService extends ChangeNotifier {
  static const _keyEnabled = 'auto_extract_enabled';
  static const _keyDestination = 'auto_extract_destination';

  static final AutoExtractService instance = AutoExtractService._();

  AutoExtractService._() {
    // SharedPrefs.init() happens in main() before the first frame; reading
    // synchronously here would miss the persisted value if this singleton is
    // accessed before init. Load asynchronously and patch the defaults once
    // storage is ready.
    _autoExtractEnabled = SharedPrefs.getBool(_keyEnabled) ?? false;
    _destinationFolder = SharedPrefs.getString(_keyDestination) ?? '';
    unawaited(_loadAsync());
  }

  Future<void> _loadAsync() async {
    // SharedPrefsStorage helpers are async and safe before init (they await
    // the SharedPreferences instance internally). Use them as a fallback.
    try {
      final enabled = await SharedPrefsStorage.getBool(_keyEnabled);
      if (enabled != null) _autoExtractEnabled = enabled;
      final dest = await SharedPrefsStorage.getString(_keyDestination);
      if (dest != null) _destinationFolder = dest;
      _safeNotify();
    } catch (_) {}
  }

  bool _autoExtractEnabled = false;
  String _destinationFolder = '';
  bool _disposed = false;
  final Set<String> _extracting = {};

  bool get autoExtractEnabled => _autoExtractEnabled;
  String get destinationFolder => _destinationFolder;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void setAutoExtractEnabled(bool value) {
    if (_disposed) return;
    _autoExtractEnabled = value;
    unawaited(SharedPrefs.setBool(_keyEnabled, value));
    _safeNotify();
  }

  void setDestinationFolder(String value) {
    if (_disposed) return;
    _destinationFolder = value;
    unawaited(SharedPrefs.setString(_keyDestination, value));
    _safeNotify();
  }

  Future<void> handleTorrentCompletion(
    String torrentName,
    String filePath,
  ) async {
    if (kIsWeb || !_autoExtractEnabled || _disposed) return;

    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.zip') ||
        lowerPath.endsWith('.tar') ||
        lowerPath.endsWith('.gz') ||
        lowerPath.endsWith('.tgz') ||
        lowerPath.endsWith('.tar.gz') ||
        lowerPath.endsWith('.bz2')) {
      if (!_extracting.add(filePath)) return;
      debugPrint(
        'AutoExtractService: Initiating extraction for $torrentName at $filePath',
      );

      final destDir = _destinationFolder.isEmpty
          ? File(filePath).parent.path
          : _destinationFolder;

      // Sanitize the torrent name so it cannot escape the destination dir.
      final safeName = p.basename(
        torrentName.replaceAll('..', '_').replaceAll(RegExp(r'[\\/]'), '_'),
      );
      final targetFolder = Directory(p.join(destDir, safeName));
      final baseDir = p.normalize(p.absolute(destDir));
      final targetPath = p.normalize(p.absolute(targetFolder.path));

      try {
        if (!p.isWithin(baseDir, targetPath) && targetPath != baseDir) {
          if (kDebugMode) {
            debugPrint(
              'AutoExtractService: skipping path-traversal target $targetPath',
            );
          }
          return;
        }

        await targetFolder.create(recursive: true);
        if (lowerPath.endsWith('.zip') ||
            lowerPath.endsWith('.tar.gz') ||
            lowerPath.endsWith('.tgz') ||
            lowerPath.endsWith('.tar') ||
            lowerPath.endsWith('.gz') ||
            lowerPath.endsWith('.bz2')) {
          if ((lowerPath.endsWith('.gz') && !lowerPath.endsWith('.tar.gz')) ||
              (lowerPath.endsWith('.bz2') && !lowerPath.endsWith('.tar.bz2'))) {
            // Single gzipped/bzip2ed file - handled via streaming.
            // extractFileToDisk only understands tar/zip containers, so a
            // standalone (non-tar) .gz or .bz2 file must be decompressed
            // directly instead.
            final isGzip = lowerPath.endsWith('.gz');
            final originalFileName = p.basename(filePath);
            final outPath = p.join(
              targetFolder.path,
              originalFileName.replaceFirst(
                RegExp(isGzip ? r'\.gz$' : r'\.bz2$', caseSensitive: false),
                '',
              ),
            );
            try {
              await Isolate.run(() async {
                final inputStream = InputFileStream(filePath);
                final outputStream = OutputFileStream(outPath);
                try {
                  if (isGzip) {
                    const GZipDecoder().decodeStream(
                      inputStream,
                      outputStream,
                    );
                  } else {
                    BZip2Decoder().decodeStream(inputStream, outputStream);
                  }
                } finally {
                  await outputStream.close();
                  await inputStream.close();
                }
              });
              final outFile = File(outPath);
              if (!outFile.existsSync() || outFile.lengthSync() == 0) {
                throw StateError('Decompression produced no output');
              }
            } catch (e) {
              try {
                final outFile = File(outPath);
                if (outFile.existsSync()) outFile.deleteSync();
              } catch (_) {}
              rethrow;
            }
          } else {
            // Archive extraction using memory-efficient and zip-slip protected extractFileToDisk
            await extractFileToDisk(filePath, targetFolder.path);
          }
        }
        debugPrint('AutoExtractService: Extraction complete for $torrentName');
      } catch (e) {
        debugPrint('AutoExtractService: Error extracting $torrentName: $e');
      } finally {
        _extracting.remove(filePath);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
