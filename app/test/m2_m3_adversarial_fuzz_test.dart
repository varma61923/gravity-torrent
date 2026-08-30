import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Test Fakes & Mocks for Adversarial / Fuzz Testing
// ---------------------------------------------------------------------------

class FuzzMockEngine implements Engine {
  final List<int> pausedIds = [];
  final List<String> callLog = [];
  Torrent Function(int id)? onFetchTorrent;
  bool shouldThrowOnPause = false;

  @override
  Future<void> pauseTorrent(int id) async {
    callLog.add('pauseTorrent($id)');
    if (shouldThrowOnPause) {
      throw const SocketException('RPC network failure');
    }
    pausedIds.add(id);
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
    throw UnimplementedError('fetchTorrent not stubbed for $id');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FuzzFakeTorrent extends Torrent {
  final List<String> filePriorityCalls = [];
  int? sequentialFromPiece;

  FuzzFakeTorrent({
    required super.id,
    super.name = 'Fuzz Torrent',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // 1. Peer Port Range & Fallback Validation
  // =========================================================================
  group('Adversarial 1: Peer Port Range & Fallback Validation', () {
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

    testWidgets('Initial port <= 0 defaults text field to 51413',
        (tester) async {
      final invalidInitValues = [0, -1, -500, -65535];
      for (final val in invalidInitValues) {
        await tester.pumpWidget(
          buildDialog(
            currentValue: val,
            onSave: (_) {},
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('51413'), findsOneWidget);
      }
    });

    testWidgets('Accepts lower bound port 1', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(1));
    });

    testWidgets('Accepts upper bound port 65535', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65535');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(65535));
    });

    testWidgets('Rejects port 0', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('Rejects port 65536', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65536');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('Rejects port 70000', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '70000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('Rejects massive overflow integers and empty strings',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '99999999999999999999999999999999');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);

      await tester.enterText(textField, '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a number'), findsOneWidget);
    });

    testWidgets('Filters non-digit characters via input formatter',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      // Pure non-digits are filtered to empty string
      await tester.enterText(textField, 'abc!@#');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a number'), findsOneWidget);
    });

    testWidgets('Dialog can be cancelled without calling onSave',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        buildDialog(
          currentValue: 51413,
          onSave: (p) => savedPort = p,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '8080');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });
  });

  // =========================================================================
  // 2. BEP 12 Multi-Tracker Tiers Fuzz & Adversarial Tests
  // =========================================================================
  group('Adversarial 2: BEP 12 Multi-Tracker Tiers', () {
    test(
        'CRLF vs LF vs CR mixed line breaks with trailing and leading whitespace',
        () {
      const text = '\r\n\n  \r\n'
          '  http://tier1-a.org/announce  \r\n'
          'udp://tier1-b.org:6969/announce\n'
          '\r\n'
          '   \t   \r\n'
          'http://tier2-a.org/announce\r\n'
          '\r\n'
          'http://tier3-a.org/announce\n'
          '   ';

      final tiers = TorrentCreatorService.parseTrackerTiers(text);

      expect(tiers.length, equals(3));
      expect(
        tiers[0],
        equals([
          'http://tier1-a.org/announce',
          'udp://tier1-b.org:6969/announce',
        ]),
      );
      expect(tiers[1], equals(['http://tier2-a.org/announce']));
      expect(tiers[2], equals(['http://tier3-a.org/announce']));
    });

    test('Fuzz parser with randomized empty lines and tabs', () {
      final random = Random(42);
      for (var i = 0; i < 50; i++) {
        final tierCount = random.nextInt(5) + 1;
        final expectedTiers = <List<String>>[];
        final buffer = StringBuffer();

        for (var t = 0; t < tierCount; t++) {
          final trackersInTier = random.nextInt(4) + 1;
          final tierList = <String>[];
          for (var k = 0; k < trackersInTier; k++) {
            final url = 'http://tracker-$t-$k.com/announce';
            tierList.add(url);
            buffer.writeln('  $url  ');
          }
          expectedTiers.add(tierList);

          // Add 1 to 4 random blank lines between tiers
          final blankLines = random.nextInt(4) + 1;
          for (var b = 0; b < blankLines; b++) {
            buffer.writeln(random.nextBool() ? '   ' : '\t\t');
          }
        }

        final parsed =
            TorrentCreatorService.parseTrackerTiers(buffer.toString());
        expect(parsed, equals(expectedTiers));
      }
    });

    test(
        'Single-tier with single tracker: create .torrent produces announce without announce-list',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('fuzz_single_tracker_');
      try {
        final testFile = File('${tempDir.path}/test.bin');
        testFile.writeAsBytesSync(Uint8List(512));

        final outPath = await TorrentCreatorService.create(
          inputPath: testFile.path,
          outputDirectory: tempDir.path,
          trackers: [
            ['http://solo-tracker.org/announce'],
          ],
        );

        final bytes = File(outPath).readAsBytesSync();
        final meta = Bencode.decodeTorrent(bytes);

        expect(meta.announce, equals('http://solo-tracker.org/announce'));
        expect(meta.announceList, isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'Multi-tier multi-tracker: create .torrent produces BEP 12 announce and announce-list',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('fuzz_multi_tracker_');
      try {
        final testFile = File('${tempDir.path}/test.bin');
        testFile.writeAsBytesSync(Uint8List(1024));

        final outPath = await TorrentCreatorService.create(
          inputPath: testFile.path,
          outputDirectory: tempDir.path,
          trackers: [
            ['http://tier0-a.org/announce', 'http://tier0-b.org/announce'],
            ['http://tier1-a.org/announce'],
          ],
        );

        final bytes = File(outPath).readAsBytesSync();
        final meta = Bencode.decodeTorrent(bytes);

        expect(meta.announce, equals('http://tier0-a.org/announce'));
        expect(
          meta.announceList,
          equals([
            ['http://tier0-a.org/announce', 'http://tier0-b.org/announce'],
            ['http://tier1-a.org/announce'],
          ]),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  // =========================================================================
  // 3. Seed Ratio Calculation & Auto-Stop Stress Tests
  // =========================================================================
  group('Adversarial 3: Seed Ratio Calculation & Auto-Stop', () {
    late FuzzMockEngine mockEngine;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      SeedRatioService.instance.resetForTest();
      mockEngine = FuzzMockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
    });

    tearDown(() {
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test('SeedRatioService.calculateRatio mathematical boundary testing', () {
      // 1. All zero
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 1,
            downloadedEver: 0,
            uploadedEver: 0,
            size: 0,
          ),
        ),
        equals(0.0),
      );

      // 2. 0 downloadedEver, uploadedEver > 0, size > 0 (initial seeder)
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 2,
            downloadedEver: 0,
            uploadedEver: 2500,
            size: 1000,
          ),
        ),
        equals(2.5),
      );

      // 3. 0 downloadedEver, 0 size, uploadedEver > 0
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 3,
            downloadedEver: 0,
            uploadedEver: 5000,
            size: 0,
          ),
        ),
        equals(0.0),
      );

      // 4. downloadedEver > 0 overrides size even if size is different
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 4,
            downloadedEver: 200,
            uploadedEver: 600,
            size: 10000,
          ),
        ),
        equals(3.0),
      );

      // 5. Negative fields return 0.0 safely
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 5,
            downloadedEver: -100,
            uploadedEver: 500,
            size: -100,
          ),
        ),
        equals(0.0),
      );

      // 6. Huge values (terabytes/petabytes)
      expect(
        SeedRatioService.calculateRatio(
          FuzzFakeTorrent(
            id: 6,
            downloadedEver: 1000000000000000,
            uploadedEver: 3500000000000000,
            size: 1000000000000000,
          ),
        ),
        equals(3.5),
      );
    });

    test('checkAndStop auto-pauses seeding torrents exceeding or meeting goal',
        () async {
      final service = SeedRatioService.instance;
      await service.setGoal(101, 2.0); // Exact match
      await service.setGoal(102, 2.0); // Exceeded
      await service.setGoal(103, 2.0); // Below
      await service.setGoal(104, 2.0); // Non-seeding (downloading)
      await service.setGoal(105, 2.0); // Non-seeding (checking)
      await service.setGoal(106, 2.0); // Seeding but in ignoredIds

      final torrents = [
        FuzzFakeTorrent(
          id: 101,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 2000,
        ),
        FuzzFakeTorrent(
          id: 102,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 2500,
        ),
        FuzzFakeTorrent(
          id: 103,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 1500,
        ),
        FuzzFakeTorrent(
          id: 104,
          status: TorrentStatus.downloading,
          downloadedEver: 1000,
          uploadedEver: 5000,
        ),
        FuzzFakeTorrent(
          id: 105,
          status: TorrentStatus.checking,
          downloadedEver: 1000,
          uploadedEver: 5000,
        ),
        FuzzFakeTorrent(
          id: 106,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 3000,
        ),
      ];

      await service.checkAndStop(torrents, {106});

      expect(mockEngine.pausedIds, containsAll([101, 102]));
      expect(mockEngine.pausedIds, isNot(contains(103)));
      expect(mockEngine.pausedIds, isNot(contains(104)));
      expect(mockEngine.pausedIds, isNot(contains(105)));
      expect(mockEngine.pausedIds, isNot(contains(106)));
    });

    test('checkAndStop gracefully continues when engine.pauseTorrent throws',
        () async {
      mockEngine.shouldThrowOnPause = true;
      final service = SeedRatioService.instance;
      await service.setGoal(201, 1.0);

      final torrent = FuzzFakeTorrent(
        id: 201,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      // Should not throw or crash
      await service.checkAndStop([torrent]);
      expect(mockEngine.callLog, contains('pauseTorrent(201)'));
    });

    test('Corrupted or invalid JSON storage is recovered gracefully', () async {
      SharedPreferences.setMockInitialValues({
        'gravity_torrent_seed_ratio_goals': 'NOT_A_VALID_JSON_STRING',
      });
      final service = SeedRatioService.instance;
      service.resetForTest();

      await service.load();
      expect(service.hasGoal(1), isFalse);

      // Can set and persist new goals
      await service.setGoal(1, 1.5);
      expect(service.getGoal(1), equals(1.5));
    });
  });

  // =========================================================================
  // 4. Search Engine Parser Fuzzing, ReDoS Safety & Multi-Format Parsing
  // =========================================================================
  group('Adversarial 4: Search Engine Parser', () {
    test('Stage 1 JSON Fuzzing: arrays, objects, missing fields, type coercion',
        () {
      final jsonFuzzPayloads = [
        // 1. Array of mixed objects and invalid items
        '''
        [
          {"title": "Valid Torrent", "magnetLink": "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "size": "1048576", "seeders": "50", "leechers": "5"},
          {"name": "No Magnet With Hash", "info_hash": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "size": 2048, "seeds": 10, "peers": 2},
          {"title": "No Magnet or Hash", "size": 100},
          null,
          123,
          "random string"
        ]
        ''',
        // 2. Object with 'results' key
        '''
        {
          "results": [
            {"filename": "Object Wrapped", "magnet_link": "magnet:?xt=urn:btih:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "sizeBytes": 5242880, "seed": 100, "leech": 20}
          ]
        }
        ''',
        // 3. Object with 'items' key
        '''
        {
          "items": [
            {"release_name": "Items Wrapped", "magnetUrl": "magnet:?xt=urn:btih:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "length": 100000, "seeders": 5, "leechers": 0}
          ]
        }
        ''',
      ];

      for (final payload in jsonFuzzPayloads) {
        final results = SearchService.instance
            .parseResultsForTesting('JSON_Provider', payload);
        expect(results, isNotEmpty);
        for (final r in results) {
          expect(r.magnetLink, startsWith('magnet:?xt=urn:btih:'));
          expect(r.size, isNonNegative);
          expect(r.seeders, isNonNegative);
          expect(r.leechers, isNonNegative);
        }
      }
    });

    test(
        'Stage 2 XML/Torznab Fuzzing: enclosures, torznab attrs, malformed tags',
        () {
      const xmlPayload = '''
      <?xml version="1.0" encoding="utf-8" ?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
          <title>Test Torznab</title>
          <item>
            <title>&lt;b&gt;Ubuntu 24.04&lt;/b&gt; &amp; Debian 12</title>
            <link>https://indexer.com/details/1</link>
            <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:1111111111111111111111111111111111111111&amp;dn=Ubuntu" />
            <torznab:attr name="seeders" value="120" />
            <torznab:attr name="peers" value="15" />
            <torznab:attr name="size" value="4500000000" />
          </item>
          <item>
            <title>Fedora Workstation</title>
            <enclosure url="https://indexer.com/download/fedora.torrent" length="2500000000" type="application/x-bittorrent" />
            <torznab:attr name="infohash" value="2222222222222222222222222222222222222222" />
            <torznab:attr name="seeders" value="80" />
            <torznab:attr name="peers" value="10" />
          </item>
        </channel>
      </rss>
      ''';

      final results = SearchService.instance
          .parseResultsForTesting('Torznab_Provider', xmlPayload);
      expect(results.length, equals(2));

      expect(results[0].title, equals('Ubuntu 24.04 & Debian 12'));
      expect(
        results[0].magnetLink,
        contains('1111111111111111111111111111111111111111'),
      );
      expect(results[0].seeders, equals(120));
      expect(results[0].leechers, equals(15));
      expect(results[0].size, equals(4500000000));

      expect(results[1].title, equals('Fedora Workstation'));
      expect(
        results[1].magnetLink,
        contains('2222222222222222222222222222222222222222'),
      );
      expect(
        results[1].torrentUrl,
        equals('https://indexer.com/download/fedora.torrent'),
      );
    });

    test('Stage 3 HTML Tables: TPB, 1337x, RARBG with diverse size units', () {
      const htmlTPB = '''
      <table>
        <tr class="header"><th>Name</th><th>Size</th><th>Seeds</th><th>Leech</th></tr>
        <tr>
          <td>
            <a href="/torrent/123/Arch" class="detLink">Arch Linux 2026</a>
            <a href="magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=Arch"><img src="icon.png"/></a>
          </td>
          <td>Uploaded 01-01 2026, Size 1.25 GiB, ULed by user</td>
          <td align="right">250</td>
          <td align="right">20</td>
        </tr>
        <tr>
          <td>
            <a href="/torrent/456/FreeBSD" class="detLink">FreeBSD 14.1</a>
            <a href="/torrent/4444444444444444444444444444444444444444">Details</a>
          </td>
          <td>Size 850.5 MB</td>
          <td align="right"><font color="green">100</font></td>
          <td align="right"><font color="red">10</font></td>
        </tr>
      </table>
      ''';

      final results =
          SearchService.instance.parseResultsForTesting('TPB_Tracker', htmlTPB);
      expect(results.length, equals(2));

      expect(results[0].title, equals('Arch Linux 2026'));
      expect(
        results[0].magnetLink,
        contains('3333333333333333333333333333333333333333'),
      );
      expect(results[0].seeders, equals(250));
      expect(results[0].leechers, equals(20));
      expect(results[0].size, equals((1.25 * 1024 * 1024 * 1024).round()));

      expect(results[1].title, equals('FreeBSD 14.1'));
      expect(
        results[1].magnetLink,
        contains('4444444444444444444444444444444444444444'),
      );
      expect(results[1].seeders, equals(100));
      expect(results[1].leechers, equals(10));
      expect(results[1].size, equals((850.5 * 1024 * 1024).round()));
    });

    test('Stage 4 HTML Cards & Stage 5 Magnet Fallback Extraction', () {
      const cardHtml = '''
      <div class="container">
        <div class="torrent-item card">
          <h4><a class="title" href="/view/1">Card Layout Linux Mint</a></h4>
          <a href="magnet:?xt=urn:btih:5555555555555555555555555555555555555555&dn=LinuxMint">Magnet</a>
          <span class="size">2.8 GB</span>
          <span class="seeds">400</span>
          <span class="leech">50</span>
        </div>
      </div>
      ''';

      final cardResults =
          SearchService.instance.parseResultsForTesting('CardEngine', cardHtml);
      expect(cardResults.length, equals(1));
      expect(cardResults.first.title, equals('Card Layout Linux Mint'));
      expect(cardResults.first.seeders, equals(400));
      expect(cardResults.first.leechers, equals(50));
      expect(
        cardResults.first.magnetLink,
        contains('5555555555555555555555555555555555555555'),
      );

      const fallbackHtml = '''
      <p>Here is an unstructured paragraph with a link:
        <a href="magnet:?xt=urn:btih:6666666666666666666666666666666666666666&dn=RawFallbackFile">Download File</a>
      </p>
      ''';

      final fallbackResults = SearchService.instance
          .parseResultsForTesting('FallbackEngine', fallbackHtml);
      expect(fallbackResults.length, equals(1));
      expect(fallbackResults.first.title, equals('RawFallbackFile'));
      expect(
        fallbackResults.first.magnetLink,
        contains('6666666666666666666666666666666666666666'),
      );
    });

    test(
        'HTML Entity Decoding: numeric decimal, hex, and standard named entities',
        () {
      const html = '''
      <table>
        <tr>
          <td><a class="detLink">&#8220;Ubuntu&#8221; &amp; &#x44;&#x65;&#x62;&#x69;&#x61;&#x6e; &apos;Server&apos; &lt;v1.0&gt;</a></td>
          <td><a href="magnet:?xt=urn:btih:7777777777777777777777777777777777777777">Magnet</a></td>
          <td>1 GB</td>
        </tr>
      </table>
      ''';

      final results =
          SearchService.instance.parseResultsForTesting('Entities', html);
      expect(results.length, equals(1));
      expect(
        results.first.title,
        equals('“Ubuntu” & Debian \'Server\' <v1.0>'),
      );
    });

    test(
        'ReDoS safety benchmark on 500KB deeply nested and adversarial payload: completes < 1s',
        () {
      final buffer = StringBuffer();
      buffer.write('<table>');
      for (var i = 0; i < 500; i++) {
        buffer.write('<tr><td><a class="detLink">Adversarial Title $i</a>');
        buffer.write(
          '<div><span><span><span>depth</span></span></span></div>' * 10,
        );
        buffer.write(
          '</td><td><a href="magnet:?xt=urn:btih:8888888888888888888888888888888888888888&dn=Title+$i">DL</a></td>',
        );
        buffer.write(
          '<td>500 MB</td><td class="seeds">10</td><td class="leech">2</td></tr>',
        );
      }
      buffer.write('</table>');

      final payload = buffer.toString();
      final stopwatch = Stopwatch()..start();
      final results =
          SearchService.instance.parseResultsForTesting('StressTest', payload);
      stopwatch.stop();

      expect(results.length, equals(500));
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(1000),
        reason: 'Parsing 500 rows must finish in under 1 second without ReDoS',
      );
    });
  });

  // =========================================================================
  // 5. Moov Priority Booster Concurrency, Boundaries & Non-Clobbering
  // =========================================================================
  group('Adversarial 5: Moov Priority Booster', () {
    late FuzzMockEngine mockEngine;

    setUp(() {
      mockEngine = FuzzMockEngine();
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
        'Boundary Clamping: negative beginPiece, endPiece > pieceCount, 0 pieceSize',
        () async {
      // 1. pieceSize <= 0
      final zeroPieceSizeTorrent = FuzzFakeTorrent(
        id: 301,
        pieceCount: 10,
        pieceSize: 0,
        files: [
          torrent_file.File(
            name: 'zero_size.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 0,
            endPiece: 5,
          ),
        ],
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: zeroPieceSizeTorrent,
        file: zeroPieceSizeTorrent.files.first,
      );
      // Sequential download mode was requested, but piece boost aborted safely
      expect(
        mockEngine.callLog,
        contains('setTorrentSequentialDownload(301, true)'),
      );
      expect(zeroPieceSizeTorrent.filePriorityCalls, isEmpty);

      // 2. beginPiece < 0
      final negativeBeginTorrent = FuzzFakeTorrent(
        id: 302,
        pieceCount: 10,
        pieceSize: 16384,
        files: [
          torrent_file.File(
            name: 'negative.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: -1,
            endPiece: 5,
          ),
        ],
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: negativeBeginTorrent,
        file: negativeBeginTorrent.files.first,
      );
      expect(negativeBeginTorrent.filePriorityCalls, isEmpty);

      // 3. endPiece > pieceCount (clamping test)
      final outOfBoundsTorrent = FuzzFakeTorrent(
        id: 303,
        pieceCount: 10,
        pieceSize: 16384,
        files: [
          torrent_file.File(
            name: 'clamped.mp4',
            length: 163840,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 2,
            endPiece: 999, // way beyond pieceCount
          ),
        ],
      );

      mockEngine.onFetchTorrent = (id) => outOfBoundsTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: outOfBoundsTorrent,
        file: outOfBoundsTorrent.files.first,
      );

      expect(outOfBoundsTorrent.sequentialFromPiece, equals(2));
      expect(outOfBoundsTorrent.filePriorityCalls, contains('high: [0]'));
    });

    test(
        'Concurrency Stress: 10 concurrent boost calls on the same torrent ref-count correctly',
        () async {
      final files = List.generate(
        10,
        (i) => torrent_file.File(
          name: 'track_$i.mp4',
          length: 16384,
          bytesCompleted: 16384,
          wanted: true,
          beginPiece: i * 2,
          endPiece: i * 2 + 1,
        ),
      );

      final torrent = FuzzFakeTorrent(
        id: 304,
        pieceCount: 25,
        pieceSize: 16384,
        pieces: List.filled(25, true), // all pieces completed
        files: files,
        speedLimitDownEnabled: true,
        speedLimitDown: 500,
      );

      final liveTorrent = FuzzFakeTorrent(
        id: 304,
        pieceCount: 25,
        pieceSize: 16384,
        pieces: List.filled(25, true),
        files: files,
        speedLimitDownEnabled: false,
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => liveTorrent;

      // Concurrently launch 10 boosts
      await Future.wait(
        files.map(
          (f) => MoovPriorityBooster.boostForStreaming(
            torrent: torrent,
            file: f,
          ),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Speed limit disabled during initial boost
      expect(
        mockEngine.callLog
            .where((c) => c.contains('setTorrentSpeedLimit(304, dl: 0')),
        isNotEmpty,
      );

      // Speed limit restored exactly once when the last of the 10 finishes
      expect(
        mockEngine.callLog
            .where((c) => c.contains('setTorrentSpeedLimit(304, dl: 500')),
        hasLength(1),
      );

      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(304),
        isFalse,
      );
    });

    test(
        'Live Torrent State: user manual speed limit during buffering is preserved',
        () async {
      final torrent = FuzzFakeTorrent(
        id: 305,
        pieceCount: 10,
        pieceSize: 16384,
        pieces: List.filled(10, true),
        files: [
          torrent_file.File(
            name: 'movie.mp4',
            length: 163840,
            bytesCompleted: 163840,
            wanted: true,
            beginPiece: 0,
            endPiece: 9,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 1000,
      );

      // User modified and turned ON a custom limit of 300 while movie was buffering
      final userModifiedLiveTorrent = FuzzFakeTorrent(
        id: 305,
        pieceCount: 10,
        pieceSize: 16384,
        pieces: List.filled(10, true),
        files: torrent.files,
        speedLimitDownEnabled: true, // re-enabled by user
        speedLimitDown: 300,
      );

      mockEngine.onFetchTorrent = (id) => userModifiedLiveTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent,
        file: torrent.files.first,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Must not clobber user setting
      expect(
        mockEngine.callLog
            .where((c) => c.contains('setTorrentSpeedLimit(305, dl: 1000')),
        isEmpty,
      );
    });
  });
}
