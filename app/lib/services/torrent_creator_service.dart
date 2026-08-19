import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/services/service_locator.dart';

/// Bencode encoder (minimal, self-contained).
class _Bencode {
  static Uint8List encode(Object value) {
    final buffer = BytesBuilder();
    _encode(value, buffer);
    return buffer.toBytes();
  }

  static void _encode(Object value, BytesBuilder b) {
    if (value is int) {
      b.add('i${value}e'.codeUnits);
    } else if (value is String) {
      final bytes = utf8.encode(value);
      b.add('${bytes.length}:'.codeUnits);
      b.add(bytes);
    } else if (value is Uint8List) {
      b.add('${value.length}:'.codeUnits);
      b.add(value);
    } else if (value is List) {
      b.addByte(0x6C); // 'l'
      for (final item in value) {
        _encode(item as Object, b);
      }
      b.addByte(0x65); // 'e'
    } else if (value is Map) {
      b.addByte(0x64); // 'd'
      final sorted = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      for (final entry in sorted) {
        _encode(entry.key.toString(), b);
        _encode(entry.value as Object, b);
      }
      b.addByte(0x65); // 'e'
    } else {
      throw ArgumentError('Unsupported type: ${value.runtimeType}');
    }
  }
}

class TorrentCreatorProgress {
  final int filesProcessed;
  final int totalFiles;
  final int bytesProcessed;
  final int totalBytes;
  final bool complete;
  final String? outputPath;

  double get fraction => totalBytes > 0 ? bytesProcessed / totalBytes : 0.0;

  const TorrentCreatorProgress({
    this.filesProcessed = 0,
    this.totalFiles = 0,
    this.bytesProcessed = 0,
    this.totalBytes = 0,
    this.complete = false,
    this.outputPath,
  });
}

class TorrentCreatorService {
  TorrentCreatorService._();

  /// Creates a `.torrent` file from [inputPath] (file or directory).
  ///
  /// [trackers] can be empty for tracker-less (DHT) torrents.
  /// [pieceLength] defaults to auto-calculation based on total size.
  /// [comment] and [createdBy] are optional metadata.
  /// [onProgress] is called periodically with progress updates.
  /// Returns the path to the generated `.torrent` file.
  static Future<String> create({
    required String inputPath,
    required String outputDirectory,
    List<List<String>> trackers = const [],
    int? pieceLength,
    String? comment,
    String? createdBy,
    bool isPrivate = false,
    ValueChanged<TorrentCreatorProgress>? onProgress,
  }) async {
    final inputEntity = FileSystemEntity.typeSync(inputPath);
    if (inputEntity == FileSystemEntityType.notFound) {
      throw FileSystemException('Input path does not exist', inputPath);
    }

    final isDirectory = inputEntity == FileSystemEntityType.directory;

    // Collect files
    final List<File> files;
    final String baseName;

    if (isDirectory) {
      final dir = Directory(inputPath);
      baseName = p.basename(inputPath);
      files = await dir
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      if (files.isEmpty) {
        throw StateError('Directory contains no files');
      }
      // Sort for deterministic output
      files.sort((a, b) => a.path.compareTo(b.path));
    } else {
      final file = File(inputPath);
      baseName = p.basename(inputPath);
      files = [file];
    }

    // Calculate estimated total size for piece length auto-calculation
    int estimatedTotal = 0;
    for (final f in files) {
      estimatedTotal += await f.length();
    }

    // Auto piece length: roughly aim for 1000–2000 pieces
    final effectivePieceLength =
        pieceLength ?? _autoPieceLength(estimatedTotal);

    // Read all file data and compute piece hashes and actual sizes
    final fileSizes = <int>[];
    int totalBytes = 0;
    int bytesProcessed = 0;
    int fileIndex = 0;
    final piecesBuilder = BytesBuilder();
    var currentPiece = BytesBuilder();
    int currentPieceLen = 0;

    for (final file in files) {
      int fileActualSize = 0;
      final stream = file.openRead();
      await for (final chunk in stream) {
        fileActualSize += chunk.length;
        int offset = 0;
        while (offset < chunk.length) {
          final remaining = effectivePieceLength - currentPieceLen;
          final take = (chunk.length - offset).clamp(0, remaining);
          currentPiece.add(
            chunk is Uint8List
                ? Uint8List.sublistView(chunk, offset, offset + take)
                : Uint8List.fromList(chunk.sublist(offset, offset + take)),
          );
          currentPieceLen += take;
          offset += take;
          bytesProcessed += take;

          if (currentPieceLen == effectivePieceLength) {
            final hash = sha1.convert(currentPiece.toBytes());
            piecesBuilder.add(Uint8List.fromList(hash.bytes));
            currentPiece = BytesBuilder();
            currentPieceLen = 0;
          }
        }
      }
      fileSizes.add(fileActualSize);
      totalBytes += fileActualSize;

      fileIndex++;
      onProgress?.call(
        TorrentCreatorProgress(
          filesProcessed: fileIndex,
          totalFiles: files.length,
          bytesProcessed: bytesProcessed,
          totalBytes: estimatedTotal,
        ),
      );
    }

    // Final piece
    if (currentPieceLen > 0) {
      final hash = sha1.convert(currentPiece.toBytes());
      piecesBuilder.add(Uint8List.fromList(hash.bytes));
    }

    // Build info dictionary
    final info = <String, Object>{
      'piece length': effectivePieceLength,
      'pieces': piecesBuilder.toBytes(),
      'name': baseName,
    };

    if (isPrivate) {
      info['private'] = 1;
    }

    if (isDirectory) {
      final fileList = <Map<String, Object>>[];
      for (int i = 0; i < files.length; i++) {
        final relPath = p.relative(files[i].path, from: inputPath);
        final parts = p.split(relPath);
        fileList.add({'length': fileSizes[i], 'path': parts});
      }
      info['files'] = fileList;
    } else {
      info['length'] = totalBytes;
    }

    // Build top-level dictionary
    final torrent = <String, Object>{
      'info': info,
      'creation date': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

    final validTrackers = trackers
        .map((tier) => tier.where((t) => t.trim().isNotEmpty).toList())
        .where((tier) => tier.isNotEmpty)
        .toList();

    if (validTrackers.isNotEmpty) {
      torrent['announce'] = validTrackers.first.first;
      if (validTrackers.length > 1 ||
          (validTrackers.length == 1 && validTrackers.first.length > 1)) {
        torrent['announce-list'] = validTrackers;
      }
    }

    if (comment != null && comment.isNotEmpty) {
      torrent['comment'] = comment;
    }

    torrent['created by'] = createdBy ?? 'Gravity Torrent';

    // Encode and write
    final encoded = _Bencode.encode(torrent);
    final outputName = '${p.basenameWithoutExtension(baseName)}.torrent';
    final outputPath = p.join(outputDirectory, outputName);

    await Directory(outputDirectory).create(recursive: true);

    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(encoded);

    onProgress?.call(
      TorrentCreatorProgress(
        filesProcessed: files.length,
        totalFiles: files.length,
        bytesProcessed: totalBytes,
        totalBytes: totalBytes,
        complete: true,
        outputPath: outputPath,
      ),
    );

    return outputPath;
  }

  /// Adds the created .torrent to the engine for seeding.
  static Future<void> addForSeeding(
    String torrentFilePath,
    String? downloadDir,
  ) async {
    if (!getIt.isRegistered<Engine>()) {
      throw StateError('Engine is not registered; cannot seed torrent');
    }
    final engine = getIt<Engine>();
    final file = File(torrentFilePath);
    final bytes = await file.readAsBytes();
    // Use base64 metainfo so it works regardless of daemon location.
    await engine.addTorrent(null, base64Encode(bytes), downloadDir);
  }

  static int _autoPieceLength(int totalBytes) {
    if (totalBytes < 1024 * 1024 * 50) return 1 << 15; // 32 KiB
    if (totalBytes < 1024 * 1024 * 150) return 1 << 16; // 64 KiB
    if (totalBytes < 1024 * 1024 * 350) return 1 << 17; // 128 KiB
    if (totalBytes < 1024 * 1024 * 1024) return 1 << 18; // 256 KiB
    if (totalBytes < 1024 * 1024 * 1024 * 2) return 1 << 19; // 512 KiB
    return 1 << 20; // 1 MiB
  }
}
