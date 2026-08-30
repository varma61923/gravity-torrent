import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Represents a single file inside a torrent metainfo.
class TorrentFileEntry {
  final String path;
  final List<String> pathComponents;
  final int length;
  final String? md5sum;

  const TorrentFileEntry({
    required this.path,
    required this.pathComponents,
    required this.length,
    this.md5sum,
  });

  @override
  String toString() => 'TorrentFileEntry(path: $path, length: $length)';
}

/// Structured metadata extracted from a `.torrent` file.
class TorrentMetadata {
  final String name;
  final int totalSize;
  final int pieceLength;
  final int pieceCount;
  final Uint8List pieces;
  final Uint8List infoHash;
  final String infoHashHex;
  final List<TorrentFileEntry> files;
  final String? announce;
  final List<List<String>> announceList;
  final String? comment;
  final String? createdBy;
  final DateTime? creationDate;
  final bool isPrivate;
  final Map<String, dynamic> rawDictionary;

  const TorrentMetadata({
    required this.name,
    required this.totalSize,
    required this.pieceLength,
    required this.pieceCount,
    required this.pieces,
    required this.infoHash,
    required this.infoHashHex,
    required this.files,
    this.announce,
    this.announceList = const [],
    this.comment,
    this.createdBy,
    this.creationDate,
    this.isPrivate = false,
    required this.rawDictionary,
  });

  bool get isMultiFile =>
      files.length > 1 ||
      (files.length == 1 && files.first.pathComponents.length > 1);

  Uint8List getPieceHash(int index) {
    if (index < 0 || index >= pieceCount) {
      throw RangeError.range(
        index,
        0,
        pieceCount - 1,
        'index',
        'Piece index out of range',
      );
    }
    return Uint8List.sublistView(pieces, index * 20, (index + 1) * 20);
  }
}

/// Comprehensive, BEP 0003 compliant Bencode encoder and decoder.
class Bencode {
  Bencode._();

  /// Encodes [value] into a canonical Bencoded byte buffer.
  ///
  /// Supports [int], [String], [Uint8List], [List<int>], [List], and [Map].
  /// Dictionary keys are sorted lexicographically by raw UTF-8 bytes.
  static Uint8List encode(Object value) {
    final builder = BytesBuilder(copy: false);
    _BencodeEncoder.encodeValue(value, builder);
    return builder.toBytes();
  }

  /// Decodes [bytes] into Dart objects (`int`, `Uint8List`, `List<dynamic>`, `Map<String, dynamic>`).
  ///
  /// Throws [FormatException] on invalid syntax, malformed integers, out-of-order keys, or nesting limits.
  static dynamic decode(
    Uint8List bytes, {
    bool allowTrailingData = false,
    int maxDepth = 512,
    bool strictKeyOrder = true,
  }) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty bencode data');
    }
    final decoder = _BencodeDecoder(
      bytes,
      maxDepth: maxDepth,
      strictKeyOrder: strictKeyOrder,
    );
    final result = decoder.decodeNext();
    if (!allowTrailingData && decoder.hasRemainingBytes) {
      throw FormatException(
        'Extraneous trailing data at offset ${decoder.offset} of ${bytes.length} bytes',
      );
    }
    return result;
  }

  /// Decodes a `.torrent` file's bencoded byte stream into structured [TorrentMetadata].
  ///
  /// Computes the exact 20-byte SHA-1 [TorrentMetadata.infoHash] from the raw slice of the `info` dictionary.
  static TorrentMetadata decodeTorrent(Uint8List bytes) {
    final decoder = _BencodeDecoder(bytes, captureInfoSlice: true);
    final root = decoder.decodeNext();
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Torrent metainfo root must be a dictionary');
    }

    final rawInfoBytes = decoder.rawInfoBytes;
    if (rawInfoBytes == null || !root.containsKey('info')) {
      throw const FormatException(
        'Missing "info" dictionary in torrent metainfo',
      );
    }

    final infoObj = root['info'];
    if (infoObj is! Map<String, dynamic>) {
      throw const FormatException('"info" entry must be a dictionary');
    }

    // SHA-1 of raw sliced bytes
    final digest = sha1.convert(rawInfoBytes);
    final infoHash = Uint8List.fromList(digest.bytes);
    final infoHashHex = digest.toString().toLowerCase();

    // Name
    final rawName = infoObj['name'];
    final name = _asString(rawName, fallback: 'Unnamed Torrent');

    // Piece length
    final pieceLength = infoObj['piece length'];
    if (pieceLength is! int || pieceLength <= 0) {
      throw const FormatException(
        'Invalid or missing "piece length" in info dictionary',
      );
    }

    // Pieces
    final rawPieces = infoObj['pieces'];
    if (rawPieces is! Uint8List) {
      throw const FormatException(
        'Invalid or missing "pieces" byte string in info dictionary',
      );
    }
    if (rawPieces.length % 20 != 0) {
      throw FormatException(
        'Invalid "pieces" length: ${rawPieces.length}, must be a multiple of 20',
      );
    }
    final pieceCount = rawPieces.length ~/ 20;

    // Files & Total Size
    int totalSize = 0;
    final List<TorrentFileEntry> files = [];

    if (infoObj.containsKey('files')) {
      // Multi-file mode
      final rawFiles = infoObj['files'];
      if (rawFiles is! List || rawFiles is Uint8List) {
        throw const FormatException(
          'Invalid "files" list in multi-file torrent',
        );
      }
      for (final f in rawFiles) {
        if (f is! Map<String, dynamic>) {
          throw const FormatException('Invalid file entry in "files" list');
        }
        final fileLen = f['length'];
        if (fileLen is! int || fileLen < 0) {
          throw const FormatException('Invalid file "length" in files entry');
        }
        final rawPathList = f['path'];
        if (rawPathList is! List ||
            rawPathList is Uint8List ||
            rawPathList.isEmpty) {
          throw const FormatException('Invalid or empty "path" in files entry');
        }
        final pathComponents = <String>[];
        for (final p in rawPathList) {
          if (p is! String && p is! Uint8List) {
            throw const FormatException(
              'Invalid path component in files entry',
            );
          }
          final comp = _asString(p);
          if (comp.isEmpty) {
            throw const FormatException('Empty path component in files entry');
          }
          pathComponents.add(comp);
        }
        final pathStr = pathComponents.join('/');
        final md5 = f['md5sum'] != null ? _asString(f['md5sum']) : null;

        files.add(
          TorrentFileEntry(
            path: pathStr,
            pathComponents: pathComponents,
            length: fileLen,
            md5sum: md5,
          ),
        );
        totalSize += fileLen;
      }
    } else if (infoObj.containsKey('length')) {
      // Single-file mode
      final length = infoObj['length'];
      if (length is! int || length < 0) {
        throw const FormatException(
          'Invalid or missing "length" in single-file info dictionary',
        );
      }
      totalSize = length;
      final md5 =
          infoObj['md5sum'] != null ? _asString(infoObj['md5sum']) : null;
      files.add(
        TorrentFileEntry(
          path: name,
          pathComponents: [name],
          length: totalSize,
          md5sum: md5,
        ),
      );
    } else {
      throw const FormatException(
        'Info dictionary must contain either "length" or "files"',
      );
    }

    // Optional metadata
    final announce =
        root['announce'] != null ? _asString(root['announce']) : null;
    final announceList = <List<String>>[];
    if (root['announce-list'] is List) {
      for (final tier in root['announce-list'] as List) {
        if (tier is List) {
          final tierUrls = tier
              .map((u) => _asString(u).trim())
              .where((u) => u.isNotEmpty)
              .toList();
          if (tierUrls.isNotEmpty) {
            announceList.add(tierUrls);
          }
        }
      }
    }

    final comment = root['comment'] != null ? _asString(root['comment']) : null;
    final createdBy =
        root['created by'] != null ? _asString(root['created by']) : null;
    DateTime? creationDate;
    if (root['creation date'] is int) {
      creationDate = DateTime.fromMillisecondsSinceEpoch(
        (root['creation date'] as int) * 1000,
        isUtc: true,
      );
    }
    final isPrivate = infoObj['private'] == 1;

    return TorrentMetadata(
      name: name,
      totalSize: totalSize,
      pieceLength: pieceLength,
      pieceCount: pieceCount,
      pieces: rawPieces,
      infoHash: infoHash,
      infoHashHex: infoHashHex,
      files: files,
      announce: announce,
      announceList: announceList,
      comment: comment,
      createdBy: createdBy,
      creationDate: creationDate,
      isPrivate: isPrivate,
      rawDictionary: root,
    );
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value;
    if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
    if (value is List<int>) return utf8.decode(value, allowMalformed: true);
    return value?.toString() ?? fallback;
  }
}

class _BencodeEncoder {
  static void encodeValue(Object value, BytesBuilder builder) {
    if (value is int) {
      builder.add(ascii.encode('i${value}e'));
    } else if (value is String) {
      final bytes = utf8.encode(value);
      builder.add(ascii.encode('${bytes.length}:'));
      builder.add(bytes);
    } else if (value is Uint8List) {
      builder.add(ascii.encode('${value.length}:'));
      builder.add(value);
    } else if (value is List<int>) {
      builder.add(ascii.encode('${value.length}:'));
      builder.add(value);
    } else if (value is List) {
      builder.addByte(0x6C); // 'l'
      for (final item in value) {
        if (item == null) {
          throw ArgumentError('Bencode does not support null list elements');
        }
        encodeValue(item as Object, builder);
      }
      builder.addByte(0x65); // 'e'
    } else if (value is Map) {
      builder.addByte(0x64); // 'd'
      final entries = <MapEntry<Uint8List, Object>>[];
      for (final entry in value.entries) {
        final key = entry.key;
        final val = entry.value;
        if (val == null) continue;
        final Uint8List keyBytes;
        if (key is Uint8List) {
          keyBytes = key;
        } else if (key is String) {
          keyBytes = Uint8List.fromList(utf8.encode(key));
        } else if (key is List<int>) {
          keyBytes = Uint8List.fromList(key);
        } else {
          keyBytes = Uint8List.fromList(utf8.encode(key.toString()));
        }
        entries.add(MapEntry(keyBytes, val as Object));
      }

      // Sort keys strictly by raw UTF-8 byte order
      entries.sort((a, b) => _compareUtf8Bytes(a.key, b.key));

      for (final entry in entries) {
        builder.add(ascii.encode('${entry.key.length}:'));
        builder.add(entry.key);
        encodeValue(entry.value, builder);
      }
      builder.addByte(0x65); // 'e'
    } else {
      throw ArgumentError(
        'Unsupported type for bencoding: ${value.runtimeType}',
      );
    }
  }

  static int _compareUtf8Bytes(Uint8List a, Uint8List b) {
    final minLen = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < minLen; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }
}

class _BencodeDecoder {
  final Uint8List _bytes;
  final int _maxDepth;
  final bool _strictKeyOrder;
  final bool _captureInfoSlice;

  int _offset = 0;
  int _depth = 0;
  Uint8List? rawInfoBytes;

  _BencodeDecoder(
    this._bytes, {
    int maxDepth = 512,
    bool strictKeyOrder = true,
    bool captureInfoSlice = false,
  })  : _maxDepth = maxDepth,
        _strictKeyOrder = strictKeyOrder,
        _captureInfoSlice = captureInfoSlice;

  int get offset => _offset;
  bool get hasRemainingBytes => _offset < _bytes.length;

  dynamic decodeNext() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected end of stream at offset $_offset');
    }

    final byte = _bytes[_offset];

    if (byte == 0x69) {
      // 'i' -> integer
      return _decodeInteger();
    } else if (byte >= 0x30 && byte <= 0x39) {
      // '0'..'9' -> byte string
      return _decodeByteString();
    } else if (byte == 0x6C) {
      // 'l' -> list
      return _decodeList();
    } else if (byte == 0x64) {
      // 'd' -> dictionary
      return _decodeDictionary();
    } else {
      throw FormatException(
        'Invalid bencode token 0x${byte.toRadixString(16).padLeft(2, '0')} at offset $_offset',
      );
    }
  }

  int _decodeInteger() {
    _offset++; // skip 'i'
    final start = _offset;
    while (_offset < _bytes.length && _bytes[_offset] != 0x65) {
      _offset++;
    }
    if (_offset >= _bytes.length) {
      throw const FormatException('Unterminated integer: missing "e"');
    }

    final end = _offset;
    _offset++; // skip 'e'

    if (start == end) {
      throw const FormatException('Empty integer: "ie" is invalid');
    }

    for (int k = start; k < end; k++) {
      final b = _bytes[k];
      if (k == start && b == 0x2D) {
        if (end - start == 1) {
          throw const FormatException('Malformed integer: "-" without digits');
        }
        continue;
      }
      if (b < 0x30 || b > 0x39) {
        throw FormatException(
          'Invalid character in integer token at offset $k: 0x${b.toRadixString(16).padLeft(2, '0')}',
        );
      }
    }

    final str = ascii.decode(Uint8List.sublistView(_bytes, start, end));

    // BEP 0003 Canonical Validation
    if (str == '-0') {
      throw const FormatException('Invalid negative zero: "i-0e" is forbidden');
    }
    if (str.startsWith('0') && str.length > 1) {
      throw FormatException('Invalid leading zero in integer: "i${str}e"');
    }
    if (str.startsWith('-0') && str.length > 2) {
      throw FormatException('Invalid negative leading zero: "i${str}e"');
    }
    if (str.startsWith('+')) {
      throw FormatException('Invalid positive sign in integer: "i${str}e"');
    }

    final value = int.tryParse(str);
    if (value == null) {
      throw FormatException('Malformed integer token: "i${str}e"');
    }
    return value;
  }

  Uint8List _decodeByteString() {
    final startLen = _offset;
    while (_offset < _bytes.length && _bytes[_offset] != 0x3A) {
      final b = _bytes[_offset];
      if (b < 0x30 || b > 0x39) {
        throw FormatException(
          'Invalid character in string length at offset $_offset',
        );
      }
      _offset++;
    }
    if (_offset >= _bytes.length) {
      throw const FormatException(
        'Unterminated string length: missing ":" delimiter',
      );
    }

    final endLen = _offset;
    _offset++; // skip ':'

    final lenStr =
        ascii.decode(Uint8List.sublistView(_bytes, startLen, endLen));
    if (lenStr.startsWith('0') && lenStr.length > 1) {
      throw FormatException('Invalid leading zero in string length: "$lenStr"');
    }

    final length = int.tryParse(lenStr);
    if (length == null || length < 0) {
      throw FormatException(
        'Invalid string length "$lenStr" at offset $startLen',
      );
    }

    if (length > _bytes.length - _offset) {
      throw FormatException(
        'Unexpected EOF: expected $length bytes string, only ${_bytes.length - _offset} bytes available',
      );
    }

    final slice = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  List<dynamic> _decodeList() {
    if (++_depth > _maxDepth) {
      throw FormatException(
        'Exceeded maximum bencode nesting depth of $_maxDepth',
      );
    }
    _offset++; // skip 'l'

    final list = <dynamic>[];
    while (_offset < _bytes.length && _bytes[_offset] != 0x65) {
      list.add(decodeNext());
    }

    if (_offset >= _bytes.length) {
      throw const FormatException('Unterminated list: missing "e" delimiter');
    }
    _offset++; // skip 'e'
    _depth--;
    return list;
  }

  Map<String, dynamic> _decodeDictionary() {
    if (++_depth > _maxDepth) {
      throw FormatException(
        'Exceeded maximum bencode nesting depth of $_maxDepth',
      );
    }
    _offset++; // skip 'd'

    final dict = <String, dynamic>{};
    Uint8List? previousKeyBytes;

    while (_offset < _bytes.length && _bytes[_offset] != 0x65) {
      if (_bytes[_offset] < 0x30 || _bytes[_offset] > 0x39) {
        throw FormatException(
          'Dictionary key must be a byte string at offset $_offset',
        );
      }

      final keyBytes = _decodeByteString();
      final keyString = utf8.decode(keyBytes, allowMalformed: false);

      // Key Order & Uniqueness Validation
      if (previousKeyBytes != null) {
        final cmp = _BencodeEncoder._compareUtf8Bytes(
          previousKeyBytes,
          keyBytes,
        );
        if (cmp == 0) {
          throw FormatException('Duplicate dictionary key: "$keyString"');
        }
        if (cmp > 0 && _strictKeyOrder) {
          throw FormatException(
            'Dictionary keys out of order: key "$keyString" appeared after previous key',
          );
        }
      }
      previousKeyBytes = keyBytes;

      // Check for info dictionary slice capture
      if (_captureInfoSlice && keyString == 'info' && _depth == 1) {
        final infoStart = _offset;
        final value = decodeNext();
        final infoEnd = _offset;
        rawInfoBytes = Uint8List.sublistView(_bytes, infoStart, infoEnd);
        dict[keyString] = value;
      } else {
        dict[keyString] = decodeNext();
      }
    }

    if (_offset >= _bytes.length) {
      throw const FormatException(
        'Unterminated dictionary: missing "e" delimiter',
      );
    }
    _offset++; // skip 'e'
    _depth--;
    return dict;
  }
}
