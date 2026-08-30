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
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/bitfield.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ===========================================================================
// Mocks and Test Fakes for Empirical Challenger 2
// ===========================================================================

class Challenger2MockEngine implements Engine {
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
    throw UnimplementedError();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Challenger2FakeTorrent extends Torrent {
  final List<String> filePriorityCalls = [];
  int? sequentialFromPiece;

  Challenger2FakeTorrent({
    required super.id,
    super.name = 'Challenger2 Torrent',
    super.status = TorrentStatus.seeding,
    super.progress = 1.0,
    super.size = 1000000,
    super.downloadedEver = 0,
    super.uploadedEver = 0,
    super.pieceCount = 10,
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
      filePriorityCalls.add('high: $priorityHigh');
    }
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int piece) async {
    sequentialFromPiece = piece;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ===========================================================================
// Challenger 2 Main Adversarial Suite
// ===========================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 1. BENCODE & METAINFO PRE-INSPECTION ADVERSARIAL STRESS
  // -------------------------------------------------------------------------
  group('Challenger 2 — Bencode & Metainfo Pre-Inspection', () {
    test(
        'Bencode recursion depth defense: deep nested lists throw FormatException',
        () {
      final buffer = StringBuffer();
      for (var i = 0; i < 600; i++) {
        buffer.write('l');
      }
      buffer.write('i1e');
      for (var i = 0; i < 600; i++) {
        buffer.write('e');
      }
      final payload = Uint8List.fromList(utf8.encode(buffer.toString()));

      expect(
        () => Bencode.decode(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test(
        'Bencode byte-level dictionary key sort ordering adheres strictly to BEP 0003',
        () {
      final input = <String, dynamic>{
        'zebra': 1,
        'alpha': 2,
        'beta': 'hello',
        'Zebra': 3,
        '': 4,
      };

      final encoded = Bencode.encode(input);
      final encodedStr = utf8.decode(encoded);

      expect(
        encodedStr
            .startsWith('d0:i4e5:Zebrai3e5:alphai2e4:beta5:hello5:zebrai1ee'),
        isTrue,
      );
    });

    test(
        'Bencode decodeTorrent accurately extracts info_hash from single and multi file torrents',
        () {
      final piecesHash = Uint8List(20);
      final infoDict = <String, dynamic>{
        'length': 1024,
        'name': 'single_file.dat',
        'piece length': 1024,
        'pieces': piecesHash,
      };

      final torrentDict = <String, dynamic>{
        'announce': 'http://tracker.example.com/announce',
        'info': infoDict,
      };

      final encoded = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(encoded);

      final encodedInfo = Bencode.encode(infoDict);
      final expectedHashHex = sha1.convert(encodedInfo).toString();

      expect(
        metadata.infoHashHex.toLowerCase(),
        equals(expectedHashHex.toLowerCase()),
      );
      expect(metadata.name, equals('single_file.dat'));
      expect(metadata.totalSize, equals(1024));
      expect(metadata.pieceLength, equals(1024));
      expect(metadata.pieceCount, equals(1));
      expect(metadata.files.length, equals(1));
    });

    test(
        'Bencode decodeTorrent handles path sanitization for multi-file torrents',
        () {
      final piecesHash = Uint8List(40);
      final infoDict = <String, dynamic>{
        'name': 'multi_pack',
        'piece length': 1024,
        'pieces': piecesHash,
        'files': [
          {
            'length': 1000,
            'path': ['subfolder', 'video.mp4'],
          },
          {
            'length': 500,
            'path': ['document.pdf'],
          },
        ],
      };

      final torrentDict = <String, dynamic>{
        'announce': 'http://tracker.example.com/announce',
        'info': infoDict,
      };

      final encoded = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.name, equals('multi_pack'));
      expect(metadata.totalSize, equals(1500));
      expect(metadata.files.length, equals(2));
      expect(metadata.files[0].path, equals('subfolder/video.mp4'));
      expect(metadata.files[1].path, equals('document.pdf'));
    });
  });

  // -------------------------------------------------------------------------
  // 2. TRANSMISSION MODEL & PIECE COUNT SCALE
  // -------------------------------------------------------------------------
  group('Challenger 2 — Transmission Model Scale & Bitfield', () {
    test(
        'TransmissionTorrentModel handles pieceCount = 10,000,000 without clamping or crashing',
        () {
      final model = TransmissionTorrentModel.fromJson({
        'id': 777,
        'name': 'Huge Swarm',
        'pieceCount': 10000000,
        'pieceSize': 16384,
        'pieces': '',
        'sizeWhenDone': 163840000000,
      });

      expect(model.pieceCount, equals(10000000));
      expect(model.pieces.length, equals(10000000));
    });

    test(
        'convertBitfieldToBoolList handles arbitrary length bitfields with exact padding',
        () {
      // 10 pieces with piece 0, 1, 9 set
      // byte 0: 11000000 (0xC0), byte 1: 01000000 (0x40) -> 2 bytes: [192, 64]
      final bytes = Uint8List.fromList([192, 64]);

      final bitfield = convertBitfieldToBoolList(bytes, 10);
      expect(bitfield.length, equals(10));
      expect(bitfield[0], isTrue);
      expect(bitfield[1], isTrue);
      expect(bitfield[2], isFalse);
      expect(bitfield[8], isFalse);
      expect(bitfield[9], isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // 3. UI PORT VALIDATION BOUNDS & DEFAULT FALLBACK
  // -------------------------------------------------------------------------
  group('Challenger 2 — Peer Port UI Validation Bounds', () {
    Widget buildPortDialog({
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

    testWidgets('Initial 0 falls back to 51413', (tester) async {
      await tester.pumpWidget(
        buildPortDialog(
          currentValue: 0,
          onSave: (_) {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('51413'), findsOneWidget);
    });

    testWidgets('Accepts lower bound port 1', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildPortDialog(
          currentValue: 51413,
          onSave: (val) => savedPort = val,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(1));
    });

    testWidgets('Accepts upper bound port 65535', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildPortDialog(
          currentValue: 51413,
          onSave: (val) => savedPort = val,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '65535');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(65535));
    });

    testWidgets('Rejects out-of-bounds port 65536', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildPortDialog(
          currentValue: 51413,
          onSave: (val) => savedPort = val,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '65536');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('Rejects port 0', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildPortDialog(
          currentValue: 51413,
          onSave: (val) => savedPort = val,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 4. BEP 12 MULTI-TRACKER TIERING COMPREHENSIVE TESTS
  // -------------------------------------------------------------------------
  group('Challenger 2 — BEP 12 Multi-Tracker Tiers', () {
    test(
        'parses arbitrary whitespace, empty lines, and multi-tier tracker URLs',
        () {
      const input = '''

udp://tracker.opentrackr.org:1337/announce
http://tracker.openbittorrent.com:80/announce


http://retracker.local/announce
udp://ipv6.tracker.org:6969/announce

udp://backup.tracker.com:80/announce

''';

      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers.length, equals(3));
      expect(
        tiers[0],
        equals([
          'udp://tracker.opentrackr.org:1337/announce',
          'http://tracker.openbittorrent.com:80/announce',
        ]),
      );
      expect(
        tiers[1],
        equals([
          'http://retracker.local/announce',
          'udp://ipv6.tracker.org:6969/announce',
        ]),
      );
      expect(
        tiers[2],
        equals([
          'udp://backup.tracker.com:80/announce',
        ]),
      );
    });

    test('preserves unicode / IDN tracker URLs in tiers', () {
      const input = 'http://тракер.рф/announce\nhttp://tracker2.com/announce';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(1));
      expect(
        tiers[0],
        equals(
          ['http://тракер.рф/announce', 'http://tracker2.com/announce'],
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 5. SEED RATIO CALCULATION & AUTO-STOP SERVICE
  // -------------------------------------------------------------------------
  group('Challenger 2 — Seed Ratio Canonical Alignment', () {
    late Challenger2MockEngine mockEngine;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      SeedRatioService.instance.resetForTest();
      mockEngine = Challenger2MockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
    });

    tearDown(() {
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test('calculateRatio formula adherence for all mathematical domains', () {
      // 1. Standard download: uploadedEver / downloadedEver
      final standard = Challenger2FakeTorrent(
        id: 1,
        downloadedEver: 1000,
        uploadedEver: 2500,
        size: 1000,
      );
      expect(SeedRatioService.calculateRatio(standard), equals(2.5));

      // 2. Initial seeder (downloadedEver == 0, size > 0): uploadedEver / size
      final seeder = Challenger2FakeTorrent(
        id: 2,
        downloadedEver: 0,
        uploadedEver: 3000,
        size: 2000,
      );
      expect(SeedRatioService.calculateRatio(seeder), equals(1.5));

      // 3. Zero size and zero downloaded: 0.0
      final zeroAll = Challenger2FakeTorrent(
        id: 3,
        downloadedEver: 0,
        uploadedEver: 500,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(zeroAll), equals(0.0));

      // 4. Zero uploaded: 0.0
      final zeroUp = Challenger2FakeTorrent(
        id: 4,
        downloadedEver: 1000,
        uploadedEver: 0,
        size: 1000,
      );
      expect(SeedRatioService.calculateRatio(zeroUp), equals(0.0));

      // 5. Extreme numbers (multi-terabyte)
      final huge = Challenger2FakeTorrent(
        id: 5,
        downloadedEver: 5000000000000,
        uploadedEver: 15000000000000,
        size: 5000000000000,
      );
      expect(SeedRatioService.calculateRatio(huge), equals(3.0));
    });

    test(
        'checkAndStop triggers pause strictly when ratio >= goal for seeding torrents',
        () async {
      final service = SeedRatioService.instance;
      await service.setGoal(10, 2.0);
      await service.setGoal(20, 2.0);
      await service.setGoal(30, 2.0);

      final torrent1 = Challenger2FakeTorrent(
        id: 10,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      final torrent2 = Challenger2FakeTorrent(
        id: 20,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1999,
      );

      final torrent3 = Challenger2FakeTorrent(
        id: 30,
        status: TorrentStatus.downloading,
        downloadedEver: 1000,
        uploadedEver: 5000,
      );

      await service.checkAndStop([torrent1, torrent2, torrent3]);
      expect(mockEngine.pausedIds, equals([10]));
    });
  });

  // -------------------------------------------------------------------------
  // 6. SEARCH SERVICE MULTI-FORMAT PARSING & ADVERSARIAL PAYLOADS
  // -------------------------------------------------------------------------
  group('Challenger 2 — Search Engine Parser Across Formats', () {
    test('Stage 1: JSON Apibay and wrapped object parser', () {
      const wrappedJson = '''
{
  "status": "ok",
  "results": [
    {
      "name": "Ubuntu 24.04 Desktop ISO",
      "info_hash": "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2",
      "size": 4831838208,
      "seeders": 1500,
      "leechers": 50
    }
  ]
}
''';
      final results =
          SearchService.instance.parseResultsForTesting('Apibay', wrappedJson);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Ubuntu 24.04 Desktop ISO'));
      expect(results.first.seeders, equals(1500));
      expect(results.first.leechers, equals(50));
      expect(results.first.size, equals(4831838208));
      expect(
        results.first.magnetLink,
        contains('A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2'),
      );
    });

    test('Stage 2: Torznab XML feed with enclosures and custom attributes', () {
      const torznabXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <title>Indexer Feed</title>
    <item>
      <title>Debian 12 Netinst</title>
      <link>https://indexer.org/details/123</link>
      <enclosure url="magnet:?xt=urn:btih:00112233445566778899aabbccddeeff00112233&amp;dn=Debian+12" length="650000000" type="application/x-bittorrent" />
      <torznab:attr name="seeders" value="450" />
      <torznab:attr name="peers" value="30" />
      <torznab:attr name="size" value="650000000" />
    </item>
  </channel>
</rss>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Torznab', torznabXml);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Debian 12 Netinst'));
      expect(results.first.seeders, equals(450));
      expect(results.first.leechers, equals(30));
      expect(results.first.size, equals(650000000));
      expect(
        results.first.magnetLink,
        contains('00112233445566778899aabbccddeeff00112233'),
      );
    });

    test(
        'Stage 3 & 4: HTML Table / Card Scraper with size unit conversions and entity unescaping',
        () {
      const htmlBody = '''
<!DOCTYPE html>
<html>
<body>
  <table id="searchResult">
    <tr>
      <td>
        <a class="detLink" href="/torrent/999/Arch_Linux">&quot;Arch Linux&quot; 2026.08 &amp; Tools</a>
        <a href="magnet:?xt=urn:btih:1234567890123456789012345678901234567890&dn=Arch+Linux"><img src="magnet.png"/></a>
      </td>
      <td>Size 2.5 GB, ULed by admin</td>
      <td align="right">320</td>
      <td align="right">15</td>
    </tr>
  </table>
</body>
</html>
''';
      final results =
          SearchService.instance.parseResultsForTesting('TPB', htmlBody);
      expect(results.length, equals(1));
      expect(results.first.title, equals('"Arch Linux" 2026.08 & Tools'));
      expect(results.first.seeders, equals(320));
      expect(results.first.leechers, equals(15));
      expect(results.first.size, equals((2.5 * 1024 * 1024 * 1024).round()));
    });

    test(
        'Stage 5: Raw Magnet Fallback Crawler extracts magnets when markup is irregular',
        () {
      const messyHtml = '''
<div>
  <span>Some text without any standard table</span>
  <p>Download here: <a href="magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd&dn=Custom+Raw+Torrent">Direct Magnet</a></p>
  <span>Random notes</span>
</div>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Fallback', messyHtml);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Custom Raw Torrent'));
      expect(
        results.first.magnetLink,
        contains('abcdefabcdefabcdefabcdefabcdefabcdefabcd'),
      );
    });

    test('Adversarial ReDoS and malformed input safety: runs in < 200ms', () {
      final malformedPayload =
          '${'<div class="torrent">' * 1000}<a href="magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=Safe">Link</a>${'</div>' * 1000}';

      final sw = Stopwatch()..start();
      final results = SearchService.instance
          .parseResultsForTesting('ReDoSTest', malformedPayload);
      sw.stop();

      expect(results.length, equals(1));
      expect(results.first.title, equals('Safe'));
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  // -------------------------------------------------------------------------
  // 7. MOOV PRIORITY BOOSTER CONCURRENCY & LIMIT HARDENING
  // -------------------------------------------------------------------------
  group('Challenger 2 — Moov Priority Booster Concurrency & Restoration', () {
    late Challenger2MockEngine mockEngine;

    setUp(() {
      mockEngine = Challenger2MockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
      app_main.engine = mockEngine;
      MoovPriorityBooster.resetForTest();
    });

    tearDown(() {
      MoovPriorityBooster.resetForTest();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test(
        'MoovPriorityBooster ref-counts active sessions and restores speed limit only after all files finish',
        () async {
      final multiFileTorrent = Challenger2FakeTorrent(
        id: 201,
        pieceCount: 30,
        pieceSize: 16384,
        pieces: List.filled(30, true),
        files: [
          torrent_file.File(
            name: 'video_track1.mp4',
            length: 163840,
            bytesCompleted: 163840,
            wanted: true,
            beginPiece: 0,
            endPiece: 9,
          ),
          torrent_file.File(
            name: 'video_track2.mp4',
            length: 163840,
            bytesCompleted: 163840,
            wanted: true,
            beginPiece: 10,
            endPiece: 19,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 750,
      );

      final liveTorrent = Challenger2FakeTorrent(
        id: 201,
        pieceCount: 30,
        pieceSize: 16384,
        pieces: List.filled(30, true),
        files: multiFileTorrent.files,
        speedLimitDownEnabled: false,
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => liveTorrent;

      await Future.wait([
        MoovPriorityBooster.boostForStreaming(
          torrent: multiFileTorrent,
          file: multiFileTorrent.files[0],
        ),
        MoovPriorityBooster.boostForStreaming(
          torrent: multiFileTorrent,
          file: multiFileTorrent.files[1],
        ),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        mockEngine.callLog
            .where((c) => c.contains('setTorrentSpeedLimit(201, dl: 0')),
        isNotEmpty,
      );

      expect(
        mockEngine.callLog
            .where((c) => c.contains('setTorrentSpeedLimit(201, dl: 750')),
        hasLength(1),
      );
    });

    test(
        'MoovPriorityBooster does not crash on empty files or out-of-bound piece indices',
        () async {
      final edgeTorrent = Challenger2FakeTorrent(
        id: 202,
        pieceCount: 5,
        pieceSize: 16384,
        files: [
          torrent_file.File(
            name: 'empty.mp4',
            length: 0,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 0,
            endPiece: 0,
          ),
        ],
      );

      mockEngine.onFetchTorrent = (id) => edgeTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: edgeTorrent,
        file: edgeTorrent.files.first,
      );

      expect(
        mockEngine.callLog,
        contains('setTorrentSequentialDownload(202, true)'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 8. SSRF & IP ADDRESS RANGE CLASSIFICATION
  // -------------------------------------------------------------------------
  group('Challenger 2 — SSRF Defense & IP Address Scope', () {
    test('Classifies all IPv4 and IPv6 special ranges accurately', () {
      expect(
        IpAddressScope.classify(InternetAddress('8.8.8.8')),
        equals(AddressScope.global),
      );
      expect(
        IpAddressScope.classify(InternetAddress('1.1.1.1')),
        equals(AddressScope.global),
      );

      expect(
        IpAddressScope.classify(InternetAddress('10.254.0.1')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('172.16.50.1')),
        equals(AddressScope.private),
      );
      expect(
        IpAddressScope.classify(InternetAddress('192.168.100.1')),
        equals(AddressScope.private),
      );

      expect(
        IpAddressScope.classify(InternetAddress('100.64.1.1')),
        equals(AddressScope.cgnat),
      );

      expect(
        IpAddressScope.classify(InternetAddress('127.0.0.1')),
        equals(AddressScope.loopback),
      );
      expect(
        IpAddressScope.classify(InternetAddress('::1')),
        equals(AddressScope.loopback),
      );

      expect(
        IpAddressScope.classify(InternetAddress('fd00::1')),
        equals(AddressScope.uniqueLocal),
      );
    });
  });
}
