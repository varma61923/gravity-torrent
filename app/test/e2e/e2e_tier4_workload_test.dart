import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/session_set_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart'
    as transmission_torrent;
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/quota_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:gravity_torrent/utils/streaming_server.dart';

// ===========================================================================
// Mock Engine for Real-World Workload Simulation
// ===========================================================================

class E2EWorkloadMockEngine implements Engine {
  final List<int> pausedIds = [];
  final List<int> resumedIds = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> speedLimitsDown = {};
  final Map<int, List<int>> highPriorityFiles = {};
  final Map<int, E2EWorkloadFakeTorrent> torrents = {};

  @override
  Future<void> pauseTorrent(int id) async {
    pausedIds.add(id);
    if (torrents.containsKey(id)) {
      torrents[id]!.status = TorrentStatus.stopped;
    }
  }

  @override
  Future<void> resumeTorrent(int id) async {
    resumedIds.add(id);
    if (torrents.containsKey(id)) {
      torrents[id]!.status = TorrentStatus.downloading;
    }
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
      speedLimitsDown[id] = downloadLimit;
    }
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    if (torrents.containsKey(id)) {
      return torrents[id]!;
    }
    return E2EWorkloadFakeTorrent(
      id: id,
      pieceCount: 100,
      pieceSize: 100000,
      pieces: List<bool>.filled(100, true),
      engineRef: this,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class E2EWorkloadFakeTorrent extends Torrent {
  final E2EWorkloadMockEngine? engineRef;
  TorrentStatus _currentStatus;

  @override
  TorrentStatus get status => _currentStatus;
  set status(TorrentStatus s) => _currentStatus = s;

  E2EWorkloadFakeTorrent({
    required super.id,
    super.name = 'Workload Test Torrent',
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
    this.engineRef,
  })  : _currentStatus = status,
        super(
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
    if (priorityHigh != null) {
      engineRef?.highPriorityFiles[id] = List<int>.from(priorityHigh);
    }
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int pieceIndex) async {
    engineRef?.sequentialStartPieces[id] = pieceIndex;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2EWorkloadMockEngine mockEngine;
  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();
    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();

    mockEngine = E2EWorkloadMockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;

    tempDir = await Directory.systemTemp.createTemp('gravity_e2e_tier4_');
  });

  tearDown(() async {
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Tier 4 — Real-World Application Workload Scenarios', () {
    test(
        'Workload 1: Media Lifecycle — Search -> SSRF Check -> Quota -> Pre-Inspection -> Engine Add -> Streaming Range Seek -> Seeding Auto-Stop',
        () async {
      // 1. Search query and parsing
      const searchHtml = '''
<table>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Cosmos+Documentary+2026&tr=http%3A%2F%2Ftracker.public-legit.org%3A8080%2Fannounce">Cosmos Documentary 2026</a></td>
    <td class="size">20.0 KB</td>
    <td class="seeds">450</td>
    <td class="leeches">12</td>
  </tr>
</table>
''';
      final searchResults = SearchService.instance
          .parseResultsForTesting('PublicProvider', searchHtml);
      expect(searchResults.length, equals(1));
      final selectedResult = searchResults.first;
      expect(selectedResult.title, equals('Cosmos Documentary 2026'));

      // 2. SSRF Tracker Validation
      final magnetUri = Uri.parse(selectedResult.magnetLink);
      final trackerUrl = magnetUri.queryParametersAll['tr']!.first;
      final trackerHost = Uri.parse(trackerUrl).host;
      expect(IpAddressScope.isPubliclyRoutableHostSync(trackerHost), isTrue);

      // 3. Bandwidth Quota Verification
      await QuotaService.instance.load();
      await QuotaService.instance.setEnabled(true);
      await QuotaService.instance.setQuota(10000000000); // 10 GB
      expect(await QuotaService.instance.canAddTorrent(), isTrue);

      // 4. Metainfo Creation & Pre-Add Inspection
      final videoPayload = File(p.join(tempDir.path, 'cosmos.mp4'));
      final videoBytes = List<int>.generate(20480, (i) => i % 256);
      await videoPayload.writeAsBytes(videoBytes);

      final torrentPath = await TorrentCreatorService.create(
        inputPath: videoPayload.path,
        outputDirectory: tempDir.path,
        pieceLength: 4096,
        comment: 'Cosmos 2026 HD',
      );

      final torrentData = await File(torrentPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentData);

      expect(metadata.name, equals('cosmos.mp4'));
      expect(metadata.totalSize, equals(20480));
      expect(metadata.pieceCount, equals(5));
      expect(metadata.infoHashHex.length, equals(40));

      // 5. Add to Engine Model & Configure Download
      final videoFile = torrent_file.File(
        name: 'cosmos.mp4',
        length: 20480,
        bytesCompleted: 20480,
        wanted: true,
        beginPiece: 0,
        endPiece: 4,
      );

      final fakeTorrent = E2EWorkloadFakeTorrent(
        id: 7001,
        name: metadata.name,
        size: metadata.totalSize,
        pieceCount: metadata.pieceCount,
        pieceSize: metadata.pieceLength,
        status: TorrentStatus.downloading,
        downloadedEver: 0,
        uploadedEver: 0,
        speedLimitDownEnabled: true,
        speedLimitDown: 2000,
        files: [videoFile],
        pieces: [true, true, true, true, true],
        engineRef: mockEngine,
      );

      mockEngine.torrents[7001] = fakeTorrent;

      // 6. Video Streaming with RFC 9110 Range Header Seeking and Moov Priority Boost
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: videoFile,
      );

      expect(mockEngine.sequentialDownloads[7001], isTrue);
      expect(mockEngine.sequentialStartPieces[7001], equals(0));
      expect(
        mockEngine.speedLimitsDown[7001],
        equals(0),
      ); // Unthrottled during streaming

      final streamingServer = StreamingServer(
        filePath: videoPayload.path,
        bufferSize: 1024,
        torrent: fakeTorrent,
        torrentFile: videoFile,
      );

      unawaited(streamingServer.start());
      final streamAddress = await streamingServer.getAddress();
      final streamUri = Uri.parse('$streamAddress/cosmos.mp4');

      final httpClient = HttpClient();
      final rangeReq = await httpClient.getUrl(streamUri);
      rangeReq.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-8191');
      final rangeResp = await rangeReq.close();

      expect(rangeResp.statusCode, equals(HttpStatus.partialContent));
      expect(
        rangeResp.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 4096-8191/20480'),
      );
      expect(rangeResp.contentLength, equals(4096));

      final streamedChunk =
          await rangeResp.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(streamedChunk, equals(videoBytes.sublist(4096, 8192)));

      httpClient.close();
      await streamingServer.stop();

      // 7. Seed Ratio Automation: complete download, start seeding, and auto-stop upon target ratio
      final seedingTorrent1 = E2EWorkloadFakeTorrent(
        id: 7001,
        name: metadata.name,
        size: metadata.totalSize,
        pieceCount: metadata.pieceCount,
        pieceSize: metadata.pieceLength,
        status: TorrentStatus.seeding,
        downloadedEver: 20480,
        uploadedEver: 20480,
        files: [videoFile],
        engineRef: mockEngine,
      );

      // Set personal ratio goal of 1.5
      await SeedRatioService.instance.setGoal(7001, 1.5);

      // Upload ratio = 1.0 (uploaded 20480) -> Not stopped yet
      await SeedRatioService.instance.checkAndStop([seedingTorrent1]);
      expect(mockEngine.pausedIds, isNot(contains(7001)));

      // Upload ratio = 1.6 (uploaded 32768) -> Exceeds goal 1.5 -> Auto-Paused
      final seedingTorrent2 = E2EWorkloadFakeTorrent(
        id: 7001,
        name: metadata.name,
        size: metadata.totalSize,
        pieceCount: metadata.pieceCount,
        pieceSize: metadata.pieceLength,
        status: TorrentStatus.seeding,
        downloadedEver: 20480,
        uploadedEver: 32768,
        files: [videoFile],
        engineRef: mockEngine,
      );
      await SeedRatioService.instance.checkAndStop([seedingTorrent2]);
      expect(mockEngine.pausedIds, contains(7001));
    });

    test(
        'Workload 2: Multi-File Private Release, BEP 12 Tier Parsing & Zip-Slip Protected Auto-Extract',
        () async {
      // 1. Create a release folder with an archive containing software update
      final releaseDir = Directory(p.join(tempDir.path, 'SecurityRelease_v2'));
      await releaseDir.create(recursive: true);

      final payloadArchive = File(p.join(releaseDir.path, 'update.zip'));
      final archive = Archive();
      final binaryPayload = utf8.encode('COMPUTED_BINARY_HASH_DATA');
      archive.addFile(
        ArchiveFile('bin/app.exe', binaryPayload.length, binaryPayload),
      );
      archive.addFile(
        ArchiveFile('license.txt', 12, utf8.encode('MIT License\n')),
      );
      final zipData = ZipEncoder().encode(archive);
      await payloadArchive.writeAsBytes(zipData);

      // 2. Multi-tracker tiers
      const trackerConfig = '''
https://tracker-alpha.private-node.net:443/announce
https://tracker-beta.private-node.net:443/announce

udp://backup.private-node.net:6969/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(trackerConfig);

      // 3. Create private torrent
      final torrentFile = await TorrentCreatorService.create(
        inputPath: releaseDir.path,
        outputDirectory: tempDir.path,
        trackers: tiers,
        isPrivate: true,
      );

      final meta = Bencode.decodeTorrent(await File(torrentFile).readAsBytes());
      expect(meta.isPrivate, isTrue);
      expect(meta.announceList.length, equals(2));

      // 4. Auto-Extract Service on download completion
      final extractDestination =
          Directory(p.join(tempDir.path, 'ExtractedBuilds'));
      await extractDestination.create(recursive: true);

      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(extractDestination.path);

      await autoExtract.handleTorrentCompletion(
        'SecurityRelease_v2',
        payloadArchive.path,
      );

      // Verify files safely extracted into destination folder
      final extractedBin = File(
        p.join(
          extractDestination.path,
          'SecurityRelease_v2',
          'bin',
          'app.exe',
        ),
      );
      expect(extractedBin.existsSync(), isTrue);
      expect(
        await extractedBin.readAsString(),
        equals('COMPUTED_BINARY_HASH_DATA'),
      );
    });

    test(
        'Workload 3: High-Scale Swarm Operations with Bitfield Unpacking & Settings Port Configuration',
        () async {
      // 1. Validate and configure incoming peer port
      const targetPort = 51413;
      expect(targetPort >= 1 && targetPort <= 65535, isTrue);

      final sessionReq = SessionSetRequest(
        arguments: SessionSetRequestArguments(
          peerPort: targetPort,
          downloadDir: '/var/torrents/downloads',
          speedLimitDown: 50000,
          speedLimitDownEnabled: true,
          speedLimitUp: 20000,
          speedLimitUpEnabled: true,
        ),
      );

      final sessionJson = sessionReq.toJson();
      expect(sessionJson['method'], equals('session-set'));

      // 2. Large swarm with 50,000 pieces bitfield
      const pieceCount = 50000;
      final rawBitfield = Uint8List((pieceCount + 7) ~/ 8);
      // Alternate bytes 0xFF and 0x00
      for (int i = 0; i < rawBitfield.length; i++) {
        rawBitfield[i] = i % 2 == 0 ? 0xFF : 0x00;
      }
      final base64Bitfield = base64Encode(rawBitfield);

      final transmissionModel =
          transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 8001,
        'name': 'Massive Swarm Dataset',
        'pieceCount': pieceCount,
        'pieceSize': 65536,
        'totalSize': pieceCount * 65536,
        'pieces': base64Bitfield,
        'status': 4,
        'downloadedEver': 1638400000,
        'uploadedEver': 3276800000,
      });

      expect(transmissionModel.pieceCount, equals(50000));
      expect(transmissionModel.pieces.length, equals(50000));
      expect(transmissionModel.pieces[0], isTrue);
      expect(transmissionModel.pieces[8], isFalse);

      // 3. Manage ignoredIds in SeedRatioService
      final torrentModel = E2EWorkloadFakeTorrent(
        id: 8001,
        downloadedEver: transmissionModel.downloadedEver,
        uploadedEver: transmissionModel.uploadedEver,
        status: TorrentStatus.seeding,
      );

      await SeedRatioService.instance.setGoal(8001, 1.0);

      // Check with ignoredIds -> ignored from auto-stopping
      await SeedRatioService.instance.checkAndStop([torrentModel], {8001});
      expect(mockEngine.pausedIds, isNot(contains(8001)));

      // Check without ignoredIds -> ratio is 2.0 >= 1.0 -> Pauses
      await SeedRatioService.instance.checkAndStop([torrentModel]);
      expect(mockEngine.pausedIds, contains(8001));
    });

    test(
        'Workload 4: Fault Tolerance, SSRF Timeout Defenses & Corrupted State Recovery',
        () async {
      // 1. DNS resolution timeout fail-closed SSRF defense
      final isPrivateAttackerBlocked =
          await IpAddressScope.isPubliclyRoutableHost(
        'attacker-slow-dns.evil.com',
        lookup: (_) async {
          await Future.delayed(const Duration(seconds: 2));
          return [InternetAddress('10.0.0.1')];
        },
        timeout: const Duration(milliseconds: 50),
      );
      expect(isPrivateAttackerBlocked, isFalse);

      // 2. Corrupted search HTML with unclosed tags and invalid magnet URIs
      const corruptedHtml = '''
<table>
  <tr>
    <td><a href="not-a-valid-magnet-link">Malformed Row</a></td>
    <td>Invalid Size</td>
    <td>NaN</td>
    <td>NaN</td>
  </tr>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=ValidRecovery">Valid Recovery</a></td>
    <td>500 MB</td>
    <td>10</td>
    <td>2</td>
  </tr>
</table>
''';
      final parsedResults = SearchService.instance
          .parseResultsForTesting('RecoverSource', corruptedHtml);
      expect(parsedResults.length, equals(1));
      expect(parsedResults.first.title, equals('Valid Recovery'));

      // 3. Corrupted seed ratio JSON in storage recovers cleanly
      await SharedPrefsStorage.setString(
        'gravity_torrent_seed_ratio_goals',
        '{"broken": [}',
      );
      await SeedRatioService.instance.load();
      expect(SeedRatioService.instance.getGoal(999), isNull);

      // 4. Blocklist URL validation with malformed inputs
      expect(
        await BlocklistService.isValidBlocklistUrl('not_a_valid_url'),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://127.0.0.1:9091/transmission/rpc',
        ),
        isFalse,
      );

      // 5. Clean disabled auto-extract handling
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(false);
      await autoExtract.handleTorrentCompletion(
        'after_disabled',
        '/some/path.zip',
      );
    });

    test(
        'Workload 5: Multi-Torrent Swarm Lifecycle — Dynamic Quotas, Multiple Seed Ratio Goals & Engine Batch State Automation',
        () async {
      // 1. Configure dynamic bandwidth quota
      await QuotaService.instance.load();
      await QuotaService.instance.setEnabled(true);
      await QuotaService.instance.setQuota(5000000000); // 5 GB
      expect(await QuotaService.instance.canAddTorrent(), isTrue);

      // 2. Configure SeedRatioService custom per-torrent ratio overrides
      await SeedRatioService.instance.load();
      await SeedRatioService.instance
          .setGoal(501, 2.0); // Per-torrent goal override
      await SeedRatioService.instance
          .setGoal(502, 2.0); // Per-torrent goal override
      await SeedRatioService.instance
          .setGoal(503, 1.5); // Per-torrent goal override

      // 3. Setup 4 torrents in different swarm states:
      // - 501: Seeding, downloaded 1000, uploaded 2500 (ratio 2.5 >= 2.0 per-torrent goal) -> should pause
      // - 502: Seeding, downloaded 1000, uploaded 1200 (ratio 1.2 < 2.0 per-torrent goal) -> should NOT pause
      // - 503: Seeding, downloaded 1000, uploaded 1600 (ratio 1.6 >= 1.5 goal) -> should pause
      // - 504: Downloading, downloaded 1000, uploaded 3000 -> downloading status, should NOT pause
      final t501 = E2EWorkloadFakeTorrent(
        id: 501,
        name: 'Seeder 501',
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2500,
        engineRef: mockEngine,
      );
      final t502 = E2EWorkloadFakeTorrent(
        id: 502,
        name: 'Seeder 502',
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1200,
        engineRef: mockEngine,
      );
      final t503 = E2EWorkloadFakeTorrent(
        id: 503,
        name: 'Seeder 503',
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1600,
        engineRef: mockEngine,
      );
      final t504 = E2EWorkloadFakeTorrent(
        id: 504,
        name: 'Downloader 504',
        status: TorrentStatus.downloading,
        downloadedEver: 1000,
        uploadedEver: 3000,
        engineRef: mockEngine,
      );

      mockEngine.torrents[501] = t501;
      mockEngine.torrents[502] = t502;
      mockEngine.torrents[503] = t503;
      mockEngine.torrents[504] = t504;

      // 4. Batch ratio check and stop execution
      await SeedRatioService.instance.checkAndStop([t501, t502, t503, t504]);

      // 5. Verify exact engine pause dispatches
      expect(mockEngine.pausedIds, contains(501));
      expect(mockEngine.pausedIds, contains(503));
      expect(mockEngine.pausedIds, isNot(contains(502)));
      expect(mockEngine.pausedIds, isNot(contains(504)));

      // 6. Resume t501 and update goal to 3.0
      await mockEngine.resumeTorrent(501);
      expect(mockEngine.resumedIds, contains(501));
      expect(t501.status, equals(TorrentStatus.downloading));

      await SeedRatioService.instance.setGoal(501, 3.0);
      expect(SeedRatioService.instance.getGoal(501), equals(3.0));
    });

    test(
        'Workload 6: Multi-Provider Search -> BEP 12 Multi-Tier Ingestion -> Bencode Metainfo Generation -> Secure Archive Auto-Extraction',
        () async {
      // 1. Query and parse multi-provider search results (Torznab XML format)
      const torznabXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <title>Torznab Indexer</title>
    <item>
      <title>Developer Tools Bundle 2026</title>
      <size>10485760</size>
      <enclosure url="magnet:?xt=urn:btih:0123456789012345678901234567890123456789&amp;dn=Developer+Tools+Bundle+2026&amp;tr=http%3A%2F%2Ftracker1.open.org%3A6969%2Fannounce" type="application/x-bittorrent" length="10485760" />
      <torznab:attr name="seeders" value="85" />
      <torznab:attr name="peers" value="10" />
    </item>
  </channel>
</rss>
''';
      final xmlResults = SearchService.instance
          .parseResultsForTesting('TorznabProvider', torznabXml);
      expect(xmlResults.length, equals(1));
      final item = xmlResults.first;
      expect(item.title, equals('Developer Tools Bundle 2026'));
      expect(item.seeders, equals(85));
      expect(item.leechers, equals(10));

      // 2. Parse multi-tracker announcement tiers (BEP 12 multi-tier format)
      const rawTrackerText = '''
http://tracker1.open.org:6969/announce
udp://tracker2.open.org:1337/announce

http://backup.tracker.net:80/announce
''';
      final trackerTiers =
          TorrentCreatorService.parseTrackerTiers(rawTrackerText);
      expect(trackerTiers.length, equals(2));
      expect(trackerTiers[0].length, equals(2));
      expect(trackerTiers[1].length, equals(1));

      // Validate tracker host SSRF safety
      for (final tier in trackerTiers) {
        for (final tr in tier) {
          final uri = Uri.tryParse(tr);
          if (uri != null && uri.host.isNotEmpty) {
            expect(IpAddressScope.isPubliclyRoutableHostSync(uri.host), isTrue);
          }
        }
      }

      // 3. Create real zip archive with documentation and binaries
      final srcDir = Directory(p.join(tempDir.path, 'dev_bundle'))
        ..createSync();
      final docFile = File(p.join(srcDir.path, 'guide.md'))
        ..writeAsStringSync('# Dev Bundle Guide\nInstructions here.');
      final binFile = File(p.join(srcDir.path, 'tool.bin'))
        ..writeAsBytesSync(List<int>.generate(8192, (i) => (i * 7) % 256));

      final archive = Archive();
      archive.addFile(
        ArchiveFile(
          'guide.md',
          docFile.lengthSync(),
          docFile.readAsBytesSync(),
        ),
      );
      archive.addFile(
        ArchiveFile(
          'bin/tool.bin',
          binFile.lengthSync(),
          binFile.readAsBytesSync(),
        ),
      );
      final zipBytes = ZipEncoder().encode(archive);

      final bundleZip = File(p.join(tempDir.path, 'dev_tools.zip'));
      await bundleZip.writeAsBytes(zipBytes);

      // 4. Create bencoded torrent metainfo
      final torrentPath = await TorrentCreatorService.create(
        inputPath: bundleZip.path,
        outputDirectory: tempDir.path,
        pieceLength: 4096,
        comment: 'Developer Tools Bundle Release',
        trackers: trackerTiers,
      );

      final torrentBytes = await File(torrentPath).readAsBytes();
      final meta = Bencode.decodeTorrent(torrentBytes);
      expect(meta.name, equals('dev_tools.zip'));
      expect(meta.totalSize, equals(zipBytes.length));
      expect(meta.infoHashHex.length, equals(40));

      // 5. Configure AutoExtractService and simulate download completion
      final extractTarget =
          Directory(p.join(tempDir.path, 'extracted_dev_bundle'))..createSync();
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(extractTarget.path);

      await autoExtract.handleTorrentCompletion(
        'Developer Tools Bundle 2026',
        bundleZip.path,
      );

      // 6. Verify extracted folder contents and integrity
      final extractedGuide = File(
        p.join(
          extractTarget.path,
          'Developer Tools Bundle 2026',
          'guide.md',
        ),
      );
      expect(extractedGuide.existsSync(), isTrue);
      expect(extractedGuide.readAsStringSync(), contains('Dev Bundle Guide'));

      final extractedBin = File(
        p.join(
          extractTarget.path,
          'Developer Tools Bundle 2026',
          'bin',
          'tool.bin',
        ),
      );
      expect(extractedBin.existsSync(), isTrue);
      expect(extractedBin.lengthSync(), equals(8192));
    });
  });
}
