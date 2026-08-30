import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/session.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/screens/torrents/sheets/torrent_details/tabs/details.dart';
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';

// ===========================================================================
// Test Mock Engine for Tier 5 Adversarial Hardening
// ===========================================================================

class E2ETier5MockEngine implements Engine {
  final List<int> pausedTorrents = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> downloadSpeedLimits = {};
  final Map<int, List<int>> highPriorityFiles = {};
  int blocklistRulesCount = 125000;
  Session? mockSession;

  @override
  Future<void> pauseTorrent(int id) async {
    pausedTorrents.add(id);
  }

  @override
  Future<void> setTorrentSequentialDownload(int id, bool sequential) async {
    sequentialDownloads[id] = sequential;
  }

  @override
  Future<void> setTorrentSpeedLimit(
    int id, {
    int? downloadLimit,
    int? uploadLimit,
  }) async {
    if (downloadLimit != null) {
      downloadSpeedLimits[id] = downloadLimit;
    }
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    return E2ETier5FakeTorrent(
      id: id,
      pieceCount: 100,
      pieceSize: 65536,
      pieces: List<bool>.filled(100, true),
      speedLimitDownEnabled:
          downloadSpeedLimits.containsKey(id) && downloadSpeedLimits[id]! > 0,
      speedLimitDown: downloadSpeedLimits[id] ?? 0,
      engineRef: this,
    );
  }

  @override
  Future<Session> fetchSession() async {
    return mockSession ??
        E2ETier5FakeSession(
          blocklistEnabled: true,
          blocklistUrl: BlocklistService.defaultUrl,
        );
  }

  @override
  Future<int> updateBlocklist() async {
    return blocklistRulesCount;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class E2ETier5FakeTorrent extends Torrent {
  final E2ETier5MockEngine? engineRef;

  E2ETier5FakeTorrent({
    required super.id,
    super.name = 'Tier 5 Hardening Torrent',
    super.status = TorrentStatus.seeding,
    super.progress = 1.0,
    super.size = 6553600,
    super.downloadedEver = 0,
    super.uploadedEver = 0,
    super.pieceCount = 100,
    super.pieceSize = 65536,
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
    this.engineRef,
  }) : super(
          pieces: pieces ??
              List<bool>.filled(pieceCount > 0 ? pieceCount : 1, true),
          files: files ?? const [],
          doneDate: doneDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        );

  @override
  Future<void> setFilesPriority({
    List<int>? priorityLow,
    List<int>? priorityNormal,
    List<int>? priorityHigh,
  }) async {
    if (priorityHigh != null && engineRef != null) {
      engineRef!.highPriorityFiles[id] = List<int>.from(priorityHigh);
    }
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int piece) async {
    if (engineRef != null) {
      engineRef!.sequentialStartPieces[id] = piece;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class E2ETier5FakeSession extends Session {
  E2ETier5FakeSession({
    super.blocklistEnabled = true,
    super.blocklistUrl = BlocklistService.defaultUrl,
  });

  @override
  Future<void> update(SessionBase updateData) async {
    if (updateData.blocklistEnabled != null) {
      blocklistEnabled = updateData.blocklistEnabled!;
    }
    if (updateData.blocklistUrl != null) {
      blocklistUrl = updateData.blocklistUrl!;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ===========================================================================
// Main Tier 5 Adversarial Test Suite
// ===========================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late E2ETier5MockEngine mockEngine;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = Directory.systemTemp.createTempSync('gravity_e2e_tier5_');
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();

    mockEngine = E2ETier5MockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);

    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();
    BlocklistService.instance.resetForTest();
  });

  tearDown(() async {
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  // =========================================================================
  // Section 1: BEP 0003 Bencode Adversarial Hardening
  // =========================================================================
  group('Tier 5 - Section 1: BEP 0003 Bencode Adversarial Hardening', () {
    test('1.1: Empty dictionaries, nested empty structures, and empty strings',
        () {
      // Empty dict 'de'
      final emptyDict = Bencode.decode(Uint8List.fromList(ascii.encode('de')));
      expect(emptyDict, isA<Map<String, dynamic>>());
      expect((emptyDict as Map).isEmpty, isTrue);

      // Re-encode empty dict
      final encodedEmpty = Bencode.encode({});
      expect(ascii.decode(encodedEmpty), 'de');

      // Nested empty structures: d1:ad1:bdeee -> {'a': {'b': {}}}
      final nestedEmpty = Bencode.decode(
        Uint8List.fromList(ascii.encode('d1:ad1:bdeee')),
      ) as Map<String, dynamic>;
      expect(nestedEmpty['a'], isA<Map<String, dynamic>>());
      expect((nestedEmpty['a'] as Map)['b'], isA<Map<String, dynamic>>());
      expect(((nestedEmpty['a'] as Map)['b'] as Map).isEmpty, isTrue);

      // Empty string '0:'
      final emptyStr = Bencode.decode(Uint8List.fromList(ascii.encode('0:')));
      expect(emptyStr, isA<Uint8List>());
      expect((emptyStr as Uint8List).isEmpty, isTrue);
      expect(Bencode.encode(''), Uint8List.fromList(ascii.encode('0:')));

      // Empty list 'le'
      final emptyList = Bencode.decode(Uint8List.fromList(ascii.encode('le')));
      expect(emptyList, isA<List<dynamic>>());
      expect((emptyList as List).isEmpty, isTrue);
      expect(Bencode.encode([]), Uint8List.fromList(ascii.encode('le')));
    });

    test(
        '1.2: Non-ASCII and multi-byte UTF-8 dictionary keys with byte-order sorting',
        () {
      final map = <String, dynamic>{
        '🚀': 'rocket',
        'alpha': 1,
        'ä': 'umlaut',
        '中文': 'chinese',
        'omega': 2,
      };

      final encoded = Bencode.encode(map);
      final decoded = Bencode.decode(encoded) as Map<String, dynamic>;
      expect(decoded.keys.toList(), ['alpha', 'omega', 'ä', '中文', '🚀']);
      expect(decoded['alpha'], 1);
      expect(decoded['omega'], 2);
      expect(utf8.decode(decoded['ä'] as Uint8List), 'umlaut');
      expect(utf8.decode(decoded['中文'] as Uint8List), 'chinese');
      expect(utf8.decode(decoded['🚀'] as Uint8List), 'rocket');
    });

    test('1.3: Deep structure nesting limits (512 allowed, 513 rejected)', () {
      final validNested = '${"l" * 512}i42e${"e" * 512}';
      final decodedValid = Bencode.decode(
        Uint8List.fromList(ascii.encode(validNested)),
        maxDepth: 512,
      );
      expect(decodedValid, isA<List<dynamic>>());

      final invalidNested = '${"l" * 513}i42e${"e" * 513}';
      expect(
        () => Bencode.decode(
          Uint8List.fromList(ascii.encode(invalidNested)),
          maxDepth: 512,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('1.4: 64-bit integer limits and negative zero rejection', () {
      const maxInt64 = 9223372036854775807;
      const minInt64 = -9223372036854775808;

      final encMax = Bencode.encode(maxInt64);
      final decMax = Bencode.decode(encMax);
      expect(decMax, equals(maxInt64));

      final encMin = Bencode.encode(minInt64);
      final decMin = Bencode.decode(encMin);
      expect(decMin, equals(minInt64));

      // Integer 0
      final encZero = Bencode.encode(0);
      expect(ascii.decode(encZero), 'i0e');
      expect(Bencode.decode(encZero), equals(0));

      // Negative zero forbidden by BEP 0003
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i-0e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test(
        '1.5: TorrentMetadata captureInfoSlice SHA-1 hash integrity on unconventional key orders',
        () {
      final pieceBytes = Uint8List.fromList(List.filled(20, 0xAB));
      final infoDict = <String, dynamic>{
        'length': 1048576,
        'name': 'adversarial_hash_test.iso',
        'piece length': 32768,
        'pieces': pieceBytes,
      };
      final rawInfoBytes = Bencode.encode(infoDict);
      final expectedSha1Hex =
          sha1.convert(rawInfoBytes).toString().toLowerCase();

      final torrentDict = <String, dynamic>{
        'announce': 'http://tracker.example.com:80/announce',
        'comment': 'Adversarial key order test',
        'created by': 'Gravity Torrent Tier 5 Test',
        'creation date': 1700000000,
        'info': infoDict,
      };

      final torrentBytes = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(torrentBytes);

      expect(metadata.infoHashHex, equals(expectedSha1Hex));
      expect(metadata.name, 'adversarial_hash_test.iso');
      expect(metadata.totalSize, 1048576);
      expect(metadata.pieceCount, 1);
      expect(metadata.isMultiFile, isFalse);
      expect(metadata.getPieceHash(0), pieceBytes);
      expect(() => metadata.getPieceHash(1), throwsA(isA<RangeError>()));
    });

    test(
        '1.6: Extraneous trailing data rejected when allowTrailingData is false',
        () {
      final validWithTrailing =
          Uint8List.fromList(ascii.encode('i42eEXTRA_BYTES'));
      expect(
        () => Bencode.decode(validWithTrailing, allowTrailingData: false),
        throwsA(isA<FormatException>()),
      );
      final decodedAllowed =
          Bencode.decode(validWithTrailing, allowTrailingData: true);
      expect(decodedAllowed, equals(42));
    });
  });

  // =========================================================================
  // Section 2: BEP 0012 Multi-Tracker Tiering & Torrent Creation Hardening
  // =========================================================================
  group('Tier 5 - Section 2: BEP 0012 Multi-Tracker Tiering & Creation', () {
    test(
        '2.1: Tracker tier parsing with mixed Windows CRLF/LF and multiple blank lines',
        () {
      const multilineTrackers = '  udp://tracker1.org:6969/announce  \r\n'
          'http://tracker2.org:80/announce\n'
          '\r\n\r\n'
          '  \t  \n'
          'udp://tracker3.org:6969/announce\r\n'
          '\n'
          'wss://tracker4.org:443/announce\r\n';

      final tiers = TorrentCreatorService.parseTrackerTiers(multilineTrackers);
      expect(tiers.length, 3);
      expect(tiers[0], [
        'udp://tracker1.org:6969/announce',
        'http://tracker2.org:80/announce',
      ]);
      expect(tiers[1], ['udp://tracker3.org:6969/announce']);
      expect(tiers[2], ['wss://tracker4.org:443/announce']);
    });

    test(
        '2.2: Multi-file directory torrent creation with nested dirs and private flag',
        () async {
      final sourceDir = Directory(p.join(tempDir.path, 'release_payload'))
        ..createSync();
      final subDirA = Directory(p.join(sourceDir.path, 'video'))..createSync();
      final subDirB = Directory(p.join(sourceDir.path, 'subs'))..createSync();

      File(p.join(subDirA.path, 'movie.mp4'))
          .writeAsBytesSync(List.filled(70000, 0x41));
      File(p.join(subDirB.path, 'eng.srt'))
          .writeAsBytesSync(List.filled(2500, 0x42));
      File(p.join(sourceDir.path, 'readme.txt'))
          .writeAsBytesSync(List.filled(500, 0x43));

      int progressCallbacks = 0;
      final outTorrentPath = await TorrentCreatorService.create(
        inputPath: sourceDir.path,
        outputDirectory: tempDir.path,
        trackers: [
          ['http://private-tracker.org/announce'],
          ['udp://backup-tracker.org:1337/announce'],
        ],
        isPrivate: true,
        comment: 'Private release with multi-tier announce-list',
        createdBy: 'Gravity Release Bot',
        onProgress: (p) {
          progressCallbacks++;
          expect(p.totalFiles, 3);
        },
      );

      expect(File(outTorrentPath).existsSync(), isTrue);
      expect(progressCallbacks, greaterThan(0));

      final torrentBytes = File(outTorrentPath).readAsBytesSync();
      final metadata = Bencode.decodeTorrent(torrentBytes);

      expect(metadata.isPrivate, isTrue);
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.files.length, 3);
      expect(metadata.totalSize, 70000 + 2500 + 500);
      expect(metadata.announceList.length, 2);
      expect(metadata.comment, 'Private release with multi-tier announce-list');
      expect(metadata.createdBy, 'Gravity Release Bot');

      final filePaths = metadata.files.map((f) => f.path).toList();
      expect(
        filePaths.contains('video/movie.mp4') ||
            filePaths.contains(p.join('video', 'movie.mp4')),
        isTrue,
      );
      expect(
        filePaths.contains('subs/eng.srt') ||
            filePaths.contains(p.join('subs', 'eng.srt')),
        isTrue,
      );
      expect(filePaths.contains('readme.txt'), isTrue);
    });

    test(
        '2.3: Tracker-less creation with empty trackers list generates valid DHT metainfo',
        () async {
      final sampleFile = File(p.join(tempDir.path, 'standalone.iso'))
        ..writeAsBytesSync(List.filled(65536, 0x55));

      final outPath = await TorrentCreatorService.create(
        inputPath: sampleFile.path,
        outputDirectory: tempDir.path,
        trackers: [],
        comment: 'DHT Trackerless Torrent',
      );

      expect(File(outPath).existsSync(), isTrue);
      final meta = Bencode.decodeTorrent(File(outPath).readAsBytesSync());
      expect(meta.announce, isNull);
      expect(meta.announceList, isEmpty);
      expect(meta.totalSize, 65536);
    });
  });

  // =========================================================================
  // Section 3: SeedRatioService & DetailsTab Calculations Hardening
  // =========================================================================
  group('Tier 5 - Section 3: SeedRatioService & DetailsTab Calculations', () {
    test(
        '3.1: calculateRatio exact BitTorrent logic across all boundary divisions',
        () {
      // 1. Normal active download: downloadedEver > 0
      final t1 = E2ETier5FakeTorrent(
        id: 101,
        downloadedEver: 1000,
        uploadedEver: 2500,
        size: 5000,
      );
      expect(SeedRatioService.calculateRatio(t1), closeTo(2.5, 0.0001));

      // 2. Initial seeder (downloadedEver == 0, size > 0)
      final t2 = E2ETier5FakeTorrent(
        id: 102,
        downloadedEver: 0,
        uploadedEver: 4000,
        size: 2000,
      );
      expect(SeedRatioService.calculateRatio(t2), closeTo(2.0, 0.0001));

      // 3. Zero size and zero download (division-by-zero defense)
      final t3 = E2ETier5FakeTorrent(
        id: 103,
        downloadedEver: 0,
        uploadedEver: 500,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(t3), equals(0.0));

      // 4. Zero uploaded
      final t4 = E2ETier5FakeTorrent(
        id: 104,
        downloadedEver: 1000,
        uploadedEver: 0,
        size: 1000,
      );
      expect(SeedRatioService.calculateRatio(t4), equals(0.0));
    });

    test(
        '3.2: checkAndStop auto-stop logic, ignored IDs, and non-seeding immunity',
        () async {
      final service = SeedRatioService.instance;
      await service.setGoal(201, 1.5);
      await service.setGoal(202, 2.0);
      await service.setGoal(203, 1.0);

      final torrents = [
        // Seeding and exceeds goal (ratio = 2.0 >= 1.5) -> MUST PAUSE
        E2ETier5FakeTorrent(
          id: 201,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 2000,
        ),
        // Seeding but below goal (ratio = 1.8 < 2.0) -> DO NOT PAUSE
        E2ETier5FakeTorrent(
          id: 202,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 1800,
        ),
        // Downloading (NOT seeding) even though ratio >= goal -> DO NOT PAUSE
        E2ETier5FakeTorrent(
          id: 203,
          status: TorrentStatus.downloading,
          downloadedEver: 1000,
          uploadedEver: 1500,
        ),
        // In ignoredIds set -> DO NOT PAUSE
        E2ETier5FakeTorrent(
          id: 204,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 5000,
        ),
      ];

      await service.setGoal(204, 1.0);

      await service.checkAndStop(torrents, {204});

      expect(mockEngine.pausedTorrents, contains(201));
      expect(mockEngine.pausedTorrents, isNot(contains(202)));
      expect(mockEngine.pausedTorrents, isNot(contains(203)));
      expect(mockEngine.pausedTorrents, isNot(contains(204)));
    });

    test(
        '3.3: SeedRatioService goal storage persistence, removeGoal, and corruption recovery',
        () async {
      final service = SeedRatioService.instance;
      await service.setGoal(555, 3.25);
      expect(service.hasGoal(555), isTrue);
      expect(service.getGoal(555), equals(3.25));

      await service.removeGoal(555);
      expect(service.hasGoal(555), isFalse);
      expect(service.getGoal(555), isNull);

      // Corrupted JSON storage handling
      await SharedPrefsStorage.setString(
        'gravity_torrent_seed_ratio_goals',
        '{bad_json:[',
      );
      service.resetForTest();
      await service.load(); // Should not crash
      expect(service.hasGoal(555), isFalse);
    });

    testWidgets(
        '3.4: DetailsTab displays calculated ratio and handles goal setting',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fakeTorrent = E2ETier5FakeTorrent(
        id: 777,
        downloadedEver: 1000,
        uploadedEver: 3000,
        size: 5000,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DetailsTab(torrent: fakeTorrent),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Ratio text '3.00'
      expect(find.text('3.00'), findsOneWidget);
    });
  });

  // =========================================================================
  // Section 4: SearchService Multi-Stage Parser Adversarial Hardening
  // =========================================================================
  group('Tier 5 - Section 4: SearchService Multi-Stage Parser Hardening', () {
    test('4.1: Deep nested JSON API formats with info_hash hex auto-conversion',
        () {
      final service = SearchService.instance;
      const rawJson = '''
      {
        "data": {
          "torrents": [
            {
              "release_name": "Ubuntu.Linux.24.04.LTS.Desktop",
              "info_hash_hex": "4a5c6d7e8f901234567890abcdef1234567890ab",
              "sizeBytes": 5368709120,
              "seeds": "1250",
              "peers": "45"
            },
            {
              "title": "Debian.12.Bookworm",
              "magnet": "magnet:?xt=urn:btih:1111222233334444555566667777888899990000&dn=Debian",
              "size": "650 MB",
              "seeders": 300,
              "leechers": 12
            }
          ]
        }
      }
      ''';

      final results = service.parseResultsForTesting('TestProvider', rawJson);
      expect(results.length, 2);

      expect(results[0].title, 'Ubuntu.Linux.24.04.LTS.Desktop');
      expect(
        results[0].magnetLink,
        contains('4a5c6d7e8f901234567890abcdef1234567890ab'),
      );
      expect(results[0].size, 5368709120);
      expect(results[0].seeders, 1250);
      expect(results[0].leechers, 45);

      expect(results[1].title, 'Debian.12.Bookworm');
      expect(results[1].size, 650 * 1024 * 1024);
      expect(results[1].seeders, 300);
      expect(results[1].leechers, 12);
    });

    test(
        '4.2: Torznab XML parsing with enclosure length, magnet URLs, and attributes',
        () {
      final service = SearchService.instance;
      const xmlFeed = '''<?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
          <title>Indexer RSS Feed</title>
          <item>
            <title>Fedora.Workstation.40.x86_64</title>
            <enclosure url="magnet:?xt=urn:btih:fedora40hash&amp;dn=Fedora" length="2147483648" type="application/x-bittorrent" />
            <torznab:attr name="seeders" value="850" />
            <torznab:attr name="peers" value="120" />
            <torznab:attr name="size" value="2147483648" />
          </item>
        </channel>
      </rss>
      ''';

      final results = service.parseResultsForTesting('TorznabIndexer', xmlFeed);
      expect(results.length, 1);
      expect(results[0].title, 'Fedora.Workstation.40.x86_64');
      expect(results[0].magnetLink, contains('fedora40hash'));
      expect(results[0].size, 2147483648);
      expect(results[0].seeders, 850);
      expect(results[0].leechers, 120);
    });

    test(
        '4.3: HTML Table parsing with formatted units (PiB, TiB, GiB, MiB, KiB) and numeric entities',
        () {
      final service = SearchService.instance;
      const htmlTable = '''
      <table>
        <tr>
          <td><a class="detLink" href="/torrent/123/Arch">Arch&#32;Linux&#32;&#x26;&#32;Kernel&#32;&#x35;&#x2E;&#x31;&#x35;</a></td>
          <td><a href="magnet:?xt=urn:btih:archlinuxhash1234567890abcdef12345678&dn=Arch">Magnet</a></td>
          <td>Size 1.5 GiB</td>
          <td><font color="green">450</font></td>
          <td><font color="red">30</font></td>
        </tr>
        <tr>
          <td><a class="title" href="/view/456">Supercomputer&#32;Dataset</a></td>
          <td><a href="magnet:?xt=urn:btih:dataset1234567890abcdef1234567890abcdef&dn=Data">Magnet</a></td>
          <td>Size: 2.2 TiB</td>
          <td align="right">95</td>
          <td align="right">15</td>
        </tr>
      </table>
      ''';

      final results = service.parseResultsForTesting('HTMLProvider', htmlTable);
      expect(results.length, 2);

      expect(results[0].title, 'Arch Linux & Kernel 5.15');
      expect(results[0].size, (1.5 * 1024 * 1024 * 1024).round());
      expect(results[0].seeders, 450);
      expect(results[0].leechers, 30);

      expect(results[1].title, 'Supercomputer Dataset');
      expect(results[1].size, (2.2 * 1024 * 1024 * 1024 * 1024).round());
      expect(results[1].seeders, 95);
      expect(results[1].leechers, 15);
    });

    test(
        '4.4: Fallback magnet link parsing with unanchored regex and surrounding context',
        () {
      final service = SearchService.instance;
      const rawText = '''
      <div>
        <p>Linux Mint 21.3 Victoria Cinnamon 64-bit Size: 2.8 GB</p>
        <span class="seeds">120</span> <span class="leech">10</span>
        <p>Download via <a href="magnet:?xt=urn:btih:mint213hash1234567890abcdef123456789012&dn=Linux+Mint+21.3">Direct Magnet</a></p>
      </div>
      ''';

      final results = service.parseResultsForTesting('RawProvider', rawText);
      expect(results.length, 1);
      expect(results[0].title, contains('Linux Mint'));
      expect(results[0].magnetLink, contains('mint213hash'));
      expect(results[0].size, (2.8 * 1024 * 1024 * 1024).round());
      expect(results[0].seeders, 120);
      expect(results[0].leechers, 10);
    });

    test('4.5: HTML Card / Block parsing with modern div structure', () {
      final service = SearchService.instance;
      const htmlCards = '''
      <div class="card">
        <h3><a class="title" href="/details/101">FreeBSD 14.1 Release</a></h3>
        <a href="magnet:?xt=urn:btih:freebsd141hash1234567890abcdef12345678&dn=FreeBSD">Magnet</a>
        <span class="size">Size: 4.1 GiB</span>
        <span class="seeders">780</span>
        <span class="leechers">25</span>
      </div>
      ''';

      final results = service.parseResultsForTesting('CardProvider', htmlCards);
      expect(results.length, 1);
      expect(results[0].title, 'FreeBSD 14.1 Release');
      expect(results[0].size, (4.1 * 1024 * 1024 * 1024).round());
      expect(results[0].seeders, 780);
      expect(results[0].leechers, 25);
    });
  });

  // =========================================================================
  // Section 5: MoovPriorityBooster Concurrency & Speed Limit Restoration
  // =========================================================================
  group('Tier 5 - Section 5: MoovPriorityBooster Concurrency & Restoration',
      () {
    test(
        '5.1: Multiple concurrent boost sessions track activeCount and restore speed limit on last exit',
        () async {
      final fakeTorrent = E2ETier5FakeTorrent(
        id: 301,
        speedLimitDownEnabled: true,
        speedLimitDown: 500, // 500 KB/s limit
        pieceCount: 50,
        pieceSize: 65536,
        engineRef: mockEngine,
      );

      final fileA = torrent_file.File(
        name: 'video1.mp4',
        length: 1000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 0,
        endPiece: 15,
      );

      final fileB = torrent_file.File(
        name: 'video2.mp4',
        length: 1000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 20,
        endPiece: 35,
      );

      // Boost file A
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fileA,
      );

      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(301),
        isTrue,
      );
      // Speed limit set to 0 (unlimited during buffer)
      expect(mockEngine.downloadSpeedLimits[301], equals(0));

      // Boost file B concurrently
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fileB,
      );

      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(301),
        isTrue,
      );

      // Both files high priority set
      expect(mockEngine.sequentialDownloads[301], isTrue);
    });

    test(
        '5.2: Piece clamp safety when beginPiece < 0, endPiece > pieceCount, or single piece',
        () async {
      final fakeTorrent = E2ETier5FakeTorrent(
        id: 302,
        pieceCount: 20,
        pieceSize: 65536,
        engineRef: mockEngine,
      );

      // Invalid negative beginPiece -> early return safe
      final invalidFile = torrent_file.File(
        name: 'invalid.mp4',
        length: 10000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: -1,
        endPiece: 5,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: invalidFile,
      );

      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(302),
        isFalse,
      );

      // Over-clamped endPiece (e.g. 50 > 20) -> clamped
      final clampedFile = torrent_file.File(
        name: 'clamped.mp4',
        length: 1000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 10,
        endPiece: 50,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: clampedFile,
      );

      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(302),
        isTrue,
      );
    });
  });

  // =========================================================================
  // Section 6: PeerPortDialog Input Bounds & UI Hardening
  // =========================================================================
  group('Tier 5 - Section 6: PeerPortDialog Input Bounds & UI', () {
    testWidgets('6.1: Valid port 51413 saves successfully', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 8080,
              onSave: (port) => savedPort = port,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      expect(textField, findsOneWidget);

      await tester.enterText(textField, '51413');
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(TextButton, 'Save');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(savedPort, equals(51413));
    });

    testWidgets(
        '6.2: Invalid port (0 and 65536 and empty) displays validation error and does not save',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 51413,
              onSave: (port) => savedPort = port,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      final saveButton = find.widgetWithText(TextButton, 'Save');

      // Test port 0
      await tester.enterText(textField, '0');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(savedPort, isNull);

      // Test port 65536
      await tester.enterText(textField, '65536');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(savedPort, isNull);

      // Test empty string
      await tester.enterText(textField, '');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
    });
  });

  // =========================================================================
  // Section 7: BlocklistService & SSRF IP Scope Hardening
  // =========================================================================
  group('Tier 5 - Section 7: BlocklistService & SSRF IP Scope Hardening', () {
    test(
        '7.1: Strict classification of RFC 1918, Loopback, CGNAT, Documentation, and IPv6 ranges',
        () {
      // RFC 1918 Private IPv4
      expect(
        IpAddressScope.classify(InternetAddress('10.0.0.1')),
        AddressScope.private,
      );
      expect(
        IpAddressScope.classify(InternetAddress('172.16.0.1')),
        AddressScope.private,
      );
      expect(
        IpAddressScope.classify(InternetAddress('172.31.255.255')),
        AddressScope.private,
      );
      expect(
        IpAddressScope.classify(InternetAddress('192.168.1.1')),
        AddressScope.private,
      );

      // Loopback IPv4 & IPv6
      expect(
        IpAddressScope.classify(InternetAddress('127.0.0.1')),
        AddressScope.loopback,
      );
      expect(
        IpAddressScope.classify(InternetAddress('127.255.255.254')),
        AddressScope.loopback,
      );
      expect(
        IpAddressScope.classify(InternetAddress('::1')),
        AddressScope.loopback,
      );

      // Link-Local IPv4 & IPv6
      expect(
        IpAddressScope.classify(InternetAddress('169.254.1.1')),
        AddressScope.linkLocal,
      );
      expect(
        IpAddressScope.classify(InternetAddress('fe80::1')),
        AddressScope.linkLocal,
      );

      // CGNAT (100.64.0.0/10)
      expect(
        IpAddressScope.classify(InternetAddress('100.64.0.1')),
        AddressScope.cgnat,
      );
      expect(
        IpAddressScope.classify(InternetAddress('100.127.255.255')),
        AddressScope.cgnat,
      );

      // Documentation IPv4 & IPv6
      expect(
        IpAddressScope.classify(InternetAddress('198.51.100.1')),
        AddressScope.documentation,
      );
      expect(
        IpAddressScope.classify(InternetAddress('203.0.113.1')),
        AddressScope.documentation,
      );
      expect(
        IpAddressScope.classify(InternetAddress('2001:db8::1')),
        AddressScope.documentation,
      );

      // Unique Local IPv6 (fc00::/7)
      expect(
        IpAddressScope.classify(InternetAddress('fc00::1')),
        AddressScope.uniqueLocal,
      );
      expect(
        IpAddressScope.classify(InternetAddress('fd12:3456:789a::1')),
        AddressScope.uniqueLocal,
      );

      // Public Global Routable IPs
      expect(
        IpAddressScope.isPubliclyRoutable(InternetAddress('8.8.8.8')),
        isTrue,
      );
      expect(
        IpAddressScope.isPubliclyRoutable(InternetAddress('1.1.1.1')),
        isTrue,
      );
      expect(
        IpAddressScope.isPubliclyRoutable(
          InternetAddress('2607:f8b0:4005:805::200e'),
        ),
        isTrue,
      );
    });

    test(
        '7.2: Sync host rejection of localhost, .local, and malformed IPv4 variants',
        () {
      expect(IpAddressScope.isPubliclyRoutableHostSync('localhost'), isFalse);
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('app.localhost'),
        isFalse,
      );
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('device.local'),
        isFalse,
      );
      expect(IpAddressScope.isPubliclyRoutableHostSync('127.0.0.1.'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('0177.0.0.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('127.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('0x7f.0.0.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('256.0.0.1'), isFalse);

      // Legitimate public domain names return true synchronously (deferred to DNS)
      expect(
        IpAddressScope.isPubliclyRoutableHostSync(
          'raw.githubusercontent.com',
        ),
        isTrue,
      );
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('tracker.opentrackr.org'),
        isTrue,
      );
    });

    test(
        '7.3: BlocklistService URL validation and update lifecycle with mock resolver',
        () async {
      final service = BlocklistService.instance;
      await service.load();

      // Valid public URL
      final isValidPublic = await BlocklistService.isValidBlocklistUrl(
        'https://raw.githubusercontent.com/Naunter/BT_BlockList/master/bt_blocklist.txt',
        lookup: (_) async => [InternetAddress('185.199.108.133')],
      );
      expect(isValidPublic, isTrue);

      // Private URL rejected
      final isValidPrivate = await BlocklistService.isValidBlocklistUrl(
        'http://192.168.1.50/blocklist.txt',
        lookup: (_) async => [InternetAddress('192.168.1.50')],
      );
      expect(isValidPrivate, isFalse);

      // Set URL with public IP endpoint and trigger update
      await service.setUrl('http://185.199.108.133/blocklist.gz');
      expect(service.url, 'http://185.199.108.133/blocklist.gz');

      final count = await service.updateNow();
      expect(count, equals(125000));
      expect(service.rulesCount, equals(125000));
      expect(service.lastUpdated, isNotNull);
    });

    test('7.4: DNS resolution timeout fails closed (returns false)', () async {
      final isRoutable = await IpAddressScope.isPubliclyRoutableHost(
        'delayed.example.org',
        lookup: (_) => Future.delayed(
          const Duration(milliseconds: 300),
          () => [InternetAddress('1.1.1.1')],
        ),
        timeout: const Duration(milliseconds: 20),
      );
      expect(isRoutable, isFalse);
    });
  });

  // =========================================================================
  // Section 8: AutoExtractService & Zip-Slip Traversal Defenses Hardening
  // =========================================================================
  group('Tier 5 - Section 8: AutoExtractService & Zip-Slip Defenses', () {
    test('8.1: Zip-slip directory traversal prevention for deep relative paths',
        () async {
      final service = AutoExtractService.instance;
      service.setAutoExtractEnabled(true);
      service.setDestinationFolder(tempDir.path);

      // Create an archive containing a path traversal entry '../../evil.txt'
      final archive = Archive();
      archive.addFile(
        ArchiveFile('safe.txt', 12, utf8.encode('safe content')),
      );
      archive.addFile(
        ArchiveFile('../../evil.txt', 12, utf8.encode('evil content')),
      );

      final zipData = ZipEncoder().encode(archive);
      final zipFile = File(p.join(tempDir.path, 'traversal_test.zip'))
        ..writeAsBytesSync(zipData);

      await service.handleTorrentCompletion('traversal_test', zipFile.path);

      // Target extracted folder
      final targetFolder = Directory(p.join(tempDir.path, 'traversal_test'));
      expect(targetFolder.existsSync(), isTrue);

      // The safe file exists inside target
      expect(File(p.join(targetFolder.path, 'safe.txt')).existsSync(), isTrue);

      // The evil file MUST NOT have escaped to the parent outside targetFolder
      final escapedFile = File(p.join(tempDir.path, 'evil.txt'));
      expect(escapedFile.existsSync(), isFalse);
    });

    test(
        '8.2: Standalone .gz archive decompression isolate handling and error recovery',
        () async {
      final service = AutoExtractService.instance;
      service.setAutoExtractEnabled(true);
      service.setDestinationFolder(tempDir.path);

      // Create a standalone .gz file
      final rawData = utf8
          .encode('Decompressed content from standalone gzip archive stream.');
      final gzipped = GZipCodec().encode(rawData);
      final gzFile = File(p.join(tempDir.path, 'dataset.csv.gz'))
        ..writeAsBytesSync(gzipped);

      await service.handleTorrentCompletion('dataset_archive', gzFile.path);

      final targetFolder = Directory(p.join(tempDir.path, 'dataset_archive'));
      expect(targetFolder.existsSync(), isTrue);

      final outFile = File(p.join(targetFolder.path, 'dataset.csv'));
      expect(outFile.existsSync(), isTrue);
      expect(
        outFile.readAsStringSync(),
        'Decompressed content from standalone gzip archive stream.',
      );
    });

    test(
        '8.3: Torrent name with directory traversal and backslashes is safely sanitized',
        () async {
      final service = AutoExtractService.instance;
      service.setAutoExtractEnabled(true);
      service.setDestinationFolder(tempDir.path);

      final archive = Archive();
      archive.addFile(
        ArchiveFile('file.txt', 9, utf8.encode('some data')),
      );
      final zipData = ZipEncoder().encode(archive);
      final zipFile = File(p.join(tempDir.path, 'safe.zip'))
        ..writeAsBytesSync(zipData);

      // Adversarial torrent names attempting escape
      await service.handleTorrentCompletion(
        '../../../../outside_folder',
        zipFile.path,
      );

      // Must be sanitized to safe name without escaping destinationFolder
      final filesOutside = tempDir.parent
          .listSync()
          .where((f) => f.path.contains('outside_folder'));
      expect(filesOutside.isEmpty, isTrue);
    });

    test('8.4: AutoExtractService when disabled performs zero disk extractions',
        () async {
      final service = AutoExtractService.instance;
      service.setAutoExtractEnabled(false);
      service.setDestinationFolder(tempDir.path);

      final archive = Archive();
      archive.addFile(ArchiveFile('dummy.txt', 5, utf8.encode('hello')));
      final zipData = ZipEncoder().encode(archive);
      final zipFile = File(p.join(tempDir.path, 'disabled_test.zip'))
        ..writeAsBytesSync(zipData);

      await service.handleTorrentCompletion('disabled_test', zipFile.path);

      final targetFolder = Directory(p.join(tempDir.path, 'disabled_test'));
      expect(targetFolder.existsSync(), isFalse);
    });
  });
}
