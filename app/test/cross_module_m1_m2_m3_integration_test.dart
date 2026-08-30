import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/bitfield.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ===========================================================================
// Test Fakes and Mock Engine for Cross-Module Integration Testing
// ===========================================================================

class CrossModuleMockEngine implements Engine {
  final List<int> pausedIds = [];
  final List<String> callLog = [];
  Torrent Function(int id)? onFetchTorrent;

  @override
  Future<void> pauseTorrent(int id) async {
    pausedIds.add(id);
    callLog.add('pauseTorrent($id)');
  }

  @override
  Future<void> setTorrentSequentialDownload(int id, bool sequential) async {
    callLog.add('setTorrentSequentialDownload($id, $sequential)');
  }

  @override
  Future<void> setTorrentSpeedLimit(
    int id, {
    int? downloadLimit,
    int? uploadLimit,
  }) async {
    callLog
        .add('setTorrentSpeedLimit($id, dl: $downloadLimit, ul: $uploadLimit)');
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    callLog.add('fetchTorrent($id)');
    if (onFetchTorrent != null) {
      return onFetchTorrent!(id);
    }
    return CrossModuleFakeTorrent(id: id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CrossModuleFakeTorrent extends Torrent {
  final List<String> priorityCalls = [];
  int? sequentialStartPiece;

  CrossModuleFakeTorrent({
    required super.id,
    super.name = 'CrossModule Torrent',
    super.status = TorrentStatus.seeding,
    super.progress = 1.0,
    super.size = 1048576,
    super.downloadedEver = 0,
    super.uploadedEver = 0,
    super.pieceCount = 64,
    super.pieceSize = 16384,
    List<bool>? pieces,
    List<torrent_file.File>? files,
    super.speedLimitDownEnabled = false,
    super.speedLimitDown = 0,
    super.speedLimitUpEnabled = false,
    super.speedLimitUp = 0,
    super.labels = const [],
    super.rateDownload = 0,
    super.rateUpload = 0,
    super.eta = 0,
    super.errorString = '',
    super.location = '/downloads',
    super.isPrivate = false,
    super.addedDate = 0,
    super.comment = '',
    super.creator = '',
    super.peersConnected = 0,
    super.magnetLink = '',
    super.sequentialDownload = false,
    DateTime? doneDate,
  }) : super(
          pieces: pieces ?? List.filled(pieceCount > 0 ? pieceCount : 1, false),
          files: files ?? const [],
          doneDate: doneDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        );

  @override
  Future<void> setFilesPriority({
    List<int>? priorityHigh,
    List<int>? priorityLow,
    List<int>? priorityNormal,
  }) async {
    if (priorityHigh != null) {
      priorityCalls.add('high: $priorityHigh');
    }
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int piece) async {
    sequentialStartPiece = piece;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // VECTOR 1: BENCODE & TORRENT METAINFO PRE-INSPECTION
  // =========================================================================
  group('Vector 1 — Bencode & Torrent Metainfo Pre-Inspection', () {
    test('BEP 0003 raw UTF-8 byte key ordering in dictionary serialization',
        () {
      final map = <String, dynamic>{
        'z': 1,
        'a': 2,
        'ä': 3, // UTF-8: 0xC3 0xA4 (must sort after 'z' 0x7A in raw bytes)
        'A': 4, // ASCII: 0x41 (must sort before 'a' 0x61)
        '': 5, // Empty string: length 0 (must sort first)
        'aa': 6,
      };

      final encoded = Bencode.encode(map);
      final decoded = Bencode.decode(encoded);

      expect(decoded, isA<Map<String, dynamic>>());
      final decodedMap = decoded as Map<String, dynamic>;
      expect(decodedMap.keys.toList(), equals(['', 'A', 'a', 'aa', 'z', 'ä']));

      final raw = utf8.decode(encoded);
      expect(raw, equals('d0:i5e1:Ai4e1:ai2e2:aai6e1:zi1e2:äi3ee'));
    });

    test('64-bit integer limits, boundary conditions, and overflow rejection',
        () {
      // 1. Exact int64 positive max (9223372036854775807)
      final maxIntBytes = utf8.encode('i9223372036854775807e');
      expect(
        Bencode.decode(Uint8List.fromList(maxIntBytes)),
        equals(9223372036854775807),
      );

      // 2. Exact int64 negative max (-9223372036854775808)
      final minIntBytes = utf8.encode('i-9223372036854775808e');
      expect(
        Bencode.decode(Uint8List.fromList(minIntBytes)),
        equals(-9223372036854775808),
      );

      // 3. Overflow beyond 64-bit bounds throws FormatException
      final overflowInt = utf8.encode('i9223372036854775808e');
      expect(
        () => Bencode.decode(Uint8List.fromList(overflowInt)),
        throwsA(isA<FormatException>()),
      );

      // 4. String length overflow check without integer wrapping (Defect 2)
      final hugeLength = utf8.encode('9223372036854775807:abc');
      expect(
        () => Bencode.decode(Uint8List.fromList(hugeLength)),
        throwsA(isA<FormatException>()),
      );

      // 5. Canonical BEP 0003 integer validation rules
      final invalidIntegers = [
        'i-0e', // Negative zero forbidden
        'i03e', // Leading zero forbidden
        'i-05e', // Negative leading zero forbidden
        'i+42e', // Positive sign forbidden
        'ie', // Empty integer forbidden
        'i-e', // Minus sign alone forbidden
        'i 42e', // Leading whitespace forbidden
        'i42 e', // Trailing whitespace forbidden
        'i\t42e', // Tab character forbidden
        'i\n42e', // Newline forbidden
      ];

      for (final invalid in invalidIntegers) {
        expect(
          () => Bencode.decode(Uint8List.fromList(utf8.encode(invalid))),
          throwsA(isA<FormatException>()),
          reason: 'Expected FormatException for invalid integer: $invalid',
        );
      }
    });

    test(
        'Recursion depth defense: exactly 512 passes, 513 throws FormatException',
        () {
      // 1. Exactly 512 nested lists -> Success
      final buffer512 = StringBuffer();
      for (var i = 0; i < 512; i++) {
        buffer512.write('l');
      }
      buffer512.write('i42e');
      for (var i = 0; i < 512; i++) {
        buffer512.write('e');
      }
      final payload512 = Uint8List.fromList(utf8.encode(buffer512.toString()));
      final result512 = Bencode.decode(payload512);
      expect(result512, isA<List<dynamic>>());

      // 2. 513 nested lists -> FormatException
      final buffer513 = StringBuffer();
      for (var i = 0; i < 513; i++) {
        buffer513.write('l');
      }
      buffer513.write('i42e');
      for (var i = 0; i < 513; i++) {
        buffer513.write('e');
      }
      final payload513 = Uint8List.fromList(utf8.encode(buffer513.toString()));
      expect(
        () => Bencode.decode(payload513),
        throwsA(isA<FormatException>()),
      );

      // 3. Custom maxDepth parameter works
      expect(
        () => Bencode.decode(payload512, maxDepth: 100),
        throwsA(isA<FormatException>()),
      );
    });

    test('SHA-1 infoHash calculation from verbatim raw info dictionary slice',
        () {
      final piecesBytes =
          Uint8List.fromList(List.generate(40, (i) => (i * 7) % 256));

      final infoMap = <String, dynamic>{
        'length': 1048576,
        'name': 'sample.file',
        'piece length': 524288,
        'pieces': piecesBytes,
      };

      final infoSlice = Bencode.encode(infoMap);

      final torrentMap = <String, dynamic>{
        'announce': 'http://tracker.test/announce',
        'info': infoMap,
      };

      final rawTorrentBytes = Bencode.encode(torrentMap);

      final metadata = Bencode.decodeTorrent(rawTorrentBytes);

      final expectedDigest = sha1.convert(infoSlice);
      expect(
        metadata.infoHash,
        equals(Uint8List.fromList(expectedDigest.bytes)),
      );
      expect(
        metadata.infoHashHex,
        equals(expectedDigest.toString().toLowerCase()),
      );
      expect(metadata.pieceCount, equals(2));
      expect(metadata.totalSize, equals(1048576));
      expect(metadata.name, equals('sample.file'));
    });

    test('Single-file and multi-file predictedSize and hierarchy verification',
        () {
      final pieces20 = Uint8List(20);

      // 1. Single-file metainfo
      final singleTorrent = Bencode.encode({
        'announce': 'http://tracker.example.com',
        'info': {
          'name': 'single_video.mkv',
          'length': 734003200,
          'piece length': 1048576,
          'pieces': pieces20,
        },
      });

      final singleMeta = Bencode.decodeTorrent(singleTorrent);
      expect(singleMeta.isMultiFile, isFalse);
      expect(singleMeta.totalSize, equals(734003200));
      expect(singleMeta.files.length, equals(1));
      expect(singleMeta.files.first.path, equals('single_video.mkv'));
      expect(singleMeta.files.first.length, equals(734003200));

      // 2. Multi-file metainfo
      final multiTorrent = Bencode.encode({
        'announce': 'http://tracker.example.com',
        'info': {
          'name': 'Album',
          'piece length': 524288,
          'pieces': pieces20,
          'files': [
            {
              'length': 1000000,
              'path': ['Track01.flac'],
            },
            {
              'length': 2500000,
              'path': ['Subdir', 'Track02.flac'],
            },
            {
              'length': 1500000,
              'path': ['Art', 'cover.jpg'],
            },
          ],
        },
      });

      final multiMeta = Bencode.decodeTorrent(multiTorrent);
      expect(multiMeta.isMultiFile, isTrue);
      expect(multiMeta.totalSize, equals(5000000));
      expect(multiMeta.files.length, equals(3));
      expect(multiMeta.files[0].path, equals('Track01.flac'));
      expect(multiMeta.files[1].path, equals('Subdir/Track02.flac'));
      expect(multiMeta.files[2].path, equals('Art/cover.jpg'));

      // 3. Multi-file rejection of byte strings / invalid path entries (Defect 3)
      final corruptTorrent = Bencode.encode({
        'info': {
          'name': 'Corrupt',
          'piece length': 524288,
          'pieces': pieces20,
          'files': [
            {
              'length': 100,
              'path': Uint8List.fromList(utf8.encode('not_a_list')),
            },
          ],
        },
      });
      expect(
        () => Bencode.decodeTorrent(corruptTorrent),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // =========================================================================
  // VECTOR 2: TRANSMISSION TORRENT MODEL SCALE (>1,000,000 PIECES)
  // =========================================================================
  group('Vector 2 — Transmission Torrent Model Scale & Bitfield Unpacking', () {
    test(
        'Handles 1,000,000, 2,000,000 and 10,000,000 piece swarms without clamping',
        () {
      // 1. Exactly 1,000,000 pieces
      final model1M = TransmissionTorrentModel.fromJson({
        'id': 101,
        'name': 'Scale 1M Swarm',
        'pieceCount': 1000000,
        'pieceSize': 16384,
      });
      expect(model1M.pieceCount, equals(1000000));
      expect(model1M.pieces.length, equals(1000000));

      // 2. 2,000,000 pieces
      final model2M = TransmissionTorrentModel.fromJson({
        'id': 102,
        'name': 'Scale 2M Swarm',
        'pieceCount': 2000000,
        'pieceSize': 16384,
      });
      expect(model2M.pieceCount, equals(2000000));
      expect(model2M.pieces.length, equals(2000000));

      // 3. 10,000,000 pieces (massive swarm)
      final model10M = TransmissionTorrentModel.fromJson({
        'id': 103,
        'name': 'Scale 10M Swarm',
        'pieceCount': 10000000,
        'pieceSize': 16384,
      });
      expect(model10M.pieceCount, equals(10000000));
      expect(model10M.pieces.length, equals(10000000));
    });

    test(
        'convertBitfieldToBoolList bit-exact unpacking with partial and overlong buffers',
        () {
      // 1. Partial trailing bits: 11 pieces with bytes [0b10101010, 0b11100000] = [170, 224]
      // Byte 0 (8 bits): 1, 0, 1, 0, 1, 0, 1, 0
      // Byte 1 (3 bits needed): 1, 1, 1 (remaining 5 bits ignored)
      final bytes = Uint8List.fromList([170, 224]);
      final bits = convertBitfieldToBoolList(bytes, 11);

      expect(bits.length, equals(11));
      expect(
        bits,
        equals([
          true,
          false,
          true,
          false,
          true,
          false,
          true,
          false,
          true,
          true,
          true,
        ]),
      );

      // 2. Truncated bitfield buffer: pieceCount = 16, but only 1 byte (8 bits) provided
      final truncatedBytes = Uint8List.fromList([255]);
      final truncatedBits = convertBitfieldToBoolList(truncatedBytes, 16);
      expect(truncatedBits.length, equals(16));
      expect(truncatedBits.sublist(0, 8), equals(List.filled(8, true)));
      expect(truncatedBits.sublist(8, 16), equals(List.filled(8, false)));

      // 3. Overlong bitfield buffer: pieceCount = 3, but 5 bytes provided
      final overlongBytes = Uint8List.fromList([0xE0, 255, 255, 255, 255]);
      final overlongBits = convertBitfieldToBoolList(overlongBytes, 3);
      expect(overlongBits.length, equals(3));
      expect(overlongBits, equals([true, true, true]));

      // 4. Zero and negative counts
      expect(convertBitfieldToBoolList(Uint8List(0), 0), isEmpty);
    });

    test(
        'Base64 decoded bitfield parsing inside TransmissionTorrentModel.fromJson',
        () {
      // Base64 of [0b11000000, 0b00000011] -> [192, 3] -> Base64: 'wAM='
      final base64String = base64Encode(Uint8List.fromList([192, 3]));
      final model = TransmissionTorrentModel.fromJson({
        'id': 105,
        'pieceCount': 16,
        'pieces': base64String,
      });

      expect(model.pieceCount, equals(16));
      expect(model.pieces.length, equals(16));
      expect(model.pieces[0], isTrue);
      expect(model.pieces[1], isTrue);
      expect(model.pieces[2], isFalse);
      expect(model.pieces[14], isTrue);
      expect(model.pieces[15], isTrue);
    });
  });

  // =========================================================================
  // VECTOR 3: BLOCKLIST SERVICE & SSRF DEFENSE
  // =========================================================================
  group('Vector 3 — Blocklist Service & SSRF Defense', () {
    test(
        'Offline IP classification covers all private, CGNAT, loopback, link-local, and IPv6 ranges',
        () {
      // Private (RFC 1918)
      expect(
        IpAddressScope.classify(InternetAddress('10.0.0.1')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('10.255.255.255')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('172.16.0.1')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('172.31.255.254')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('192.168.0.1')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('192.168.254.254')),
        equals(AddressScope.private),
      );

      // CGNAT (RFC 6598: 100.64.0.0/10)
      expect(
        IpAddressScope.classify(InternetAddress('100.64.0.1')),
        equals(AddressScope.cgnat),
      );
      expect(
        IpAddressScope.classify(InternetAddress('100.127.255.254')),
        equals(AddressScope.cgnat),
      );

      // Loopback (127.0.0.0/8 and ::1)
      expect(
        IpAddressScope.classify(InternetAddress('127.0.0.1')),
        equals(AddressScope.loopback),
      );
      expect(
        IpAddressScope.classify(InternetAddress('127.100.50.1')),
        equals(AddressScope.loopback),
      );
      expect(
        IpAddressScope.classify(InternetAddress('::1')),
        equals(AddressScope.loopback),
      );

      // Link-Local (169.254.0.0/16 and fe80::/10)
      expect(
        IpAddressScope.classify(InternetAddress('169.254.1.1')),
        equals(AddressScope.linkLocal),
      );
      expect(
        IpAddressScope.classify(InternetAddress('fe80::1')),
        equals(AddressScope.linkLocal),
      );

      // Unique Local IPv6 ULA (fc00::/7 / fd00::/8)
      expect(
        IpAddressScope.classify(InternetAddress('fc00::1')),
        equals(AddressScope.uniqueLocal),
      );
      expect(
        IpAddressScope.classify(InternetAddress('fd12:3456:789a::1')),
        equals(AddressScope.uniqueLocal),
      );

      // Public Global Addresses
      expect(
        IpAddressScope.classify(InternetAddress('8.8.8.8')),
        equals(AddressScope.global),
      );
      expect(
        IpAddressScope.classify(InternetAddress('1.1.1.1')),
        equals(AddressScope.global),
      );
      expect(
        IpAddressScope.classify(InternetAddress('2606:4700:4700::1111')),
        equals(AddressScope.global),
      );
      expect(
        IpAddressScope.classify(InternetAddress('2001:4860:4860::8888')),
        equals(AddressScope.global),
      );
    });

    test(
        'BlocklistService.isValidBlocklistUrl rejects SSRF vectors with mock DNS lookup',
        () async {
      Future<List<InternetAddress>> mockLookup(String host) async {
        if (host == 'localhost' || host == 'local.dev') {
          return [InternetAddress('127.0.0.1')];
        }
        if (host == 'internal.corp') {
          return [InternetAddress('10.0.5.1')];
        }
        if (host == 'cgnat.carrier') {
          return [InternetAddress('100.64.10.1')];
        }
        if (host == 'public.blocklist.org') {
          return [InternetAddress('104.21.5.1')];
        }
        return <InternetAddress>[];
      }

      // 1. Valid public HTTP/HTTPS URLs accepted
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://public.blocklist.org/rules.txt',
          lookup: mockLookup,
        ),
        isTrue,
      );

      // 2. Empty URL accepted (represents disabled/cleared)
      expect(await BlocklistService.isValidBlocklistUrl(''), isTrue);

      // 3. Localhost & Private hosts rejected
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://127.0.0.1/blocklist.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://localhost:8080/rules.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://internal.corp/rules.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://cgnat.carrier/rules.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );

      // 4. Credentials in URL rejected
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://admin:pass@public.blocklist.org/rules.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );

      // 5. Non-HTTP/HTTPS schemes rejected
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'ftp://public.blocklist.org/rules.txt',
          lookup: mockLookup,
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'file:///etc/passwd',
          lookup: mockLookup,
        ),
        isFalse,
      );
    });

    test('SSRF DNS Timeout fails closed (returns false)', () async {
      Future<List<InternetAddress>> timingOutLookup(String host) async {
        throw TimeoutException('DNS resolution timed out');
      }

      final result = await IpAddressScope.isPubliclyRoutableHost(
        'slow-dns.attacker.com',
        lookup: timingOutLookup,
      );

      expect(
        result,
        isFalse,
        reason: 'DNS timeout must fail closed to prevent SSRF',
      );
    });

    test(
        'Offline SocketException defers to fetch time (returns true for public hostnames)',
        () async {
      Future<List<InternetAddress>> offlineLookup(String host) async {
        throw const SocketException(
          'No address associated with hostname (offline)',
        );
      }

      final result = await IpAddressScope.isPubliclyRoutableHost(
        'valid-public-domain.com',
        lookup: offlineLookup,
      );

      expect(
        result,
        isTrue,
        reason: 'Offline SocketException should defer to runtime fetch',
      );
    });
  });

  // =========================================================================
  // VECTOR 4: SEARCH ENGINE WATERFALL & HTML ENTITIES
  // =========================================================================
  group('Vector 4 — Search Engine Waterfall & HTML Entities', () {
    test('Waterfall Stage 1: JSON APIs (Apibay & object wrappers)', () {
      // 1. Apibay direct array format with info_hash synthesis
      const apibayJson = '''
[
  {
    "name": "Arch Linux 2026 ISO",
    "info_hash": "e1f2a3b4c5d6e1f2a3b4c5d6e1f2a3b4c5d6e1f2",
    "size": "950245000",
    "seeders": "3200",
    "leechers": "150"
  }
]
''';
      final results1 =
          SearchService.instance.parseResultsForTesting('Apibay', apibayJson);
      expect(results1.length, equals(1));
      expect(results1.first.title, equals('Arch Linux 2026 ISO'));
      expect(results1.first.size, equals(950245000));
      expect(results1.first.seeders, equals(3200));
      expect(results1.first.leechers, equals(150));
      expect(
        results1.first.magnetLink,
        contains('e1f2a3b4c5d6e1f2a3b4c5d6e1f2a3b4c5d6e1f2'),
      );

      // 2. Object wrapper with 'torrents' key
      const wrapperJson = '''
{
  "status": "success",
  "torrents": [
    {
      "title": "Fedora Workstation 42",
      "magnet": "magnet:?xt=urn:btih:1234567890123456789012345678901234567890&dn=Fedora+42",
      "sizeBytes": 2147483648,
      "seeds": 800,
      "leeches": 20
    }
  ]
}
''';
      final results2 = SearchService.instance
          .parseResultsForTesting('CustomAPI', wrapperJson);
      expect(results2.length, equals(1));
      expect(results2.first.title, equals('Fedora Workstation 42'));
      expect(results2.first.size, equals(2147483648));
      expect(results2.first.seeders, equals(800));
      expect(results2.first.leechers, equals(20));
      expect(
        results2.first.magnetLink,
        contains('1234567890123456789012345678901234567890'),
      );
    });

    test('Waterfall Stage 2: XML / Torznab RSS parsing', () {
      const torznabRss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <title>Torznab Indexer</title>
    <item>
      <title>OpenSUSE Tumbleweed</title>
      <enclosure url="https://indexer.com/dl/opensuse.torrent" length="4500000000" type="application/x-bittorrent" />
      <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12&amp;dn=OpenSUSE" />
      <torznab:attr name="seeders" value="512" />
      <torznab:attr name="peers" value="64" />
      <torznab:attr name="size" value="4500000000" />
    </item>
  </channel>
</rss>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Torznab', torznabRss);
      expect(results.length, equals(1));
      expect(results.first.title, equals('OpenSUSE Tumbleweed'));
      expect(results.first.size, equals(4500000000));
      expect(results.first.seeders, equals(512));
      expect(results.first.leechers, equals(64));
      expect(
        results.first.torrentUrl,
        equals('https://indexer.com/dl/opensuse.torrent'),
      );
      expect(
        results.first.magnetLink,
        contains('abcdef1234567890abcdef1234567890abcdef12'),
      );
    });

    test('Waterfall Stage 3 & 4: HTML Tables, Cards, and Entity Unescaping',
        () {
      const htmlTable = '''
<table>
  <tr>
    <td>
      <a class="detLink" title="Details for Test Movie 2026">Test &amp; Movie &quot;2026&quot; &#39;Special&#39; &#x41;</a>
      <a href="magnet:?xt=urn:btih:fedcba0987654321fedcba0987654321fedcba09&amp;dn=Test+Movie">Magnet</a>
    </td>
    <td class="size">1.45 GiB</td>
    <td class="seeders">1,234</td>
    <td class="leechers">56</td>
  </tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('TPB', htmlTable);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Test & Movie "2026" \'Special\' A'));
      expect(results.first.seeders, equals(1234));
      expect(results.first.leechers, equals(56));
      expect(results.first.size, equals((1.45 * 1024 * 1024 * 1024).round()));
    });

    test('ReDoS safety on malformed and deep HTML payloads', () {
      final stopwatch = Stopwatch()..start();

      // Deeply nested brackets and unclosed anchors
      final adversarialHtml = '${'<div>' * 500}'
          '<a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111">'
          '${'Repeated Unclosed Text ' * 200}'
          '${'</div>' * 500}';

      final results = SearchService.instance
          .parseResultsForTesting('Adversarial', adversarialHtml);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(300),
        reason: 'ReDoS attack must parse in < 300ms',
      );
      expect(results.isNotEmpty, isTrue);
    });
  });

  // =========================================================================
  // VECTOR 5: SEED RATIO CALCULATION & UI DETAILS TAB CONSISTENCY
  // =========================================================================
  group('Vector 5 — Seed Ratio Service & Details UI Consistency', () {
    late CrossModuleMockEngine mockEngine;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      SeedRatioService.instance.resetForTest();
      mockEngine = CrossModuleMockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
    });

    tearDown(() {
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test('SeedRatioService.calculateRatio canonical formula compliance', () {
      // 1. Partial/Complete download: uploadedEver / downloadedEver
      final downloadedTorrent = CrossModuleFakeTorrent(
        id: 1,
        downloadedEver: 2048,
        uploadedEver: 5120,
        size: 4096,
      );
      expect(SeedRatioService.calculateRatio(downloadedTorrent), equals(2.5));

      // 2. Initial Seeder (downloadedEver == 0, size > 0): uploadedEver / size
      final initialSeeder = CrossModuleFakeTorrent(
        id: 2,
        downloadedEver: 0,
        uploadedEver: 3000,
        size: 1000,
      );
      expect(SeedRatioService.calculateRatio(initialSeeder), equals(3.0));

      // 3. Zero downloaded and zero size: 0.0
      final zeroTorrent = CrossModuleFakeTorrent(
        id: 3,
        downloadedEver: 0,
        uploadedEver: 1000,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(zeroTorrent), equals(0.0));
    });

    test(
        'checkAndStop strictly pauses seeding torrents exceeding personal goal',
        () async {
      final service = SeedRatioService.instance;
      await service.setGoal(10, 1.5);
      await service.setGoal(20, 2.0);

      // Torrent 10: seeding, ratio = 2.0 >= goal 1.5 -> Must be paused
      final torrent10 = CrossModuleFakeTorrent(
        id: 10,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      // Torrent 20: seeding, ratio = 1.0 < goal 2.0 -> Must NOT be paused
      final torrent20 = CrossModuleFakeTorrent(
        id: 20,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1000,
      );

      // Torrent 30: downloading, ratio = 3.0 >= goal 1.5 -> Must NOT be paused (not seeding)
      final torrent30 = CrossModuleFakeTorrent(
        id: 30,
        status: TorrentStatus.downloading,
        downloadedEver: 1000,
        uploadedEver: 3000,
      );

      await service.checkAndStop([torrent10, torrent20, torrent30]);

      expect(mockEngine.pausedIds, equals([10]));
    });

    Widget buildDialog({
      required int currentValue,
      required void Function(int) onSave,
    }) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PeerPortDialog(
            currentValue: currentValue,
            onSave: onSave,
          ),
        ),
      );
    }

    testWidgets('PeerPortDialog defaults initial 0 to 51413', (tester) async {
      await tester.pumpWidget(buildDialog(currentValue: 0, onSave: (_) {}));
      await tester.pumpAndSettle();
      expect(find.text('51413'), findsOneWidget);
    });

    testWidgets('PeerPortDialog accepts valid lower bound port 1',
        (tester) async {
      int? saved;
      await tester.pumpWidget(
        buildDialog(currentValue: 51413, onSave: (v) => saved = v),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, equals(1));
    });

    testWidgets('PeerPortDialog accepts valid upper bound port 65535',
        (tester) async {
      int? saved;
      await tester.pumpWidget(
        buildDialog(currentValue: 51413, onSave: (v) => saved = v),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '65535');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, equals(65535));
    });

    testWidgets('PeerPortDialog rejects out-of-bounds port 65536',
        (tester) async {
      int? saved;
      await tester.pumpWidget(
        buildDialog(currentValue: 51413, onSave: (v) => saved = v),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '65536');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('PeerPortDialog rejects port 0', (tester) async {
      int? saved;
      await tester.pumpWidget(
        buildDialog(currentValue: 51413, onSave: (v) => saved = v),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });
  });
}
