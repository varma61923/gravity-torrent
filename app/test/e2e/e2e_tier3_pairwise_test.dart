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
import 'package:gravity_torrent/services/analytics_service.dart';
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/quota_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/bitfield.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:gravity_torrent/utils/streaming_server.dart';

// ===========================================================================
// Mock Engine for Pairwise Combinatorial Testing
// ===========================================================================

class E2EPairwiseMockEngine implements Engine {
  final List<int> pausedIds = [];
  final List<int> resumedIds = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> speedLimitsDown = {};
  final Map<int, List<int>> highPriorityFiles = {};
  final Map<int, E2EPairwiseFakeTorrent> activeTorrents = {};

  @override
  Future<void> pauseTorrent(int id) async {
    pausedIds.add(id);
  }

  @override
  Future<void> resumeTorrent(int id) async {
    resumedIds.add(id);
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
    if (activeTorrents.containsKey(id)) {
      return activeTorrents[id]!;
    }
    return E2EPairwiseFakeTorrent(
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

class E2EPairwiseFakeTorrent extends Torrent {
  final E2EPairwiseMockEngine? engineRef;

  E2EPairwiseFakeTorrent({
    required super.id,
    super.name = 'Pairwise Test Torrent',
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

  late E2EPairwiseMockEngine mockEngine;
  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();
    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();

    mockEngine = E2EPairwiseMockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;

    tempDir = await Directory.systemTemp.createTemp('gravity_e2e_tier3_');
  });

  tearDown(() async {
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Tier 3 — Cross-Feature Pairwise Combinatorial Tests', () {
    test(
        'Pairwise 1: Bencode Metainfo Generation ↔ Pre-Add Inspection ↔ Transmission Model Sync',
        () async {
      // 1. Create a multi-file directory structure
      final payloadDir = Directory(p.join(tempDir.path, 'MediaBundle'));
      await payloadDir.create(recursive: true);

      final file1 = File(p.join(payloadDir.path, 'track1.mp3'));
      await file1.writeAsBytes(List.filled(10000, 0x11));

      final subDir = Directory(p.join(payloadDir.path, 'artwork'));
      await subDir.create(recursive: true);
      final file2 = File(p.join(subDir.path, 'cover.png'));
      await file2.writeAsBytes(List.filled(5000, 0x22));

      // 2. Generate .torrent metainfo
      final outTorrentPath = await TorrentCreatorService.create(
        inputPath: payloadDir.path,
        outputDirectory: tempDir.path,
        pieceLength: 4096,
        comment: 'Pairwise 1 Metainfo',
      );

      final torrentBytes = await File(outTorrentPath).readAsBytes();

      // 3. Pre-add inspection via Bencode.decodeTorrent
      final metadata = Bencode.decodeTorrent(torrentBytes);
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.name, equals('MediaBundle'));
      expect(metadata.totalSize, equals(15000));
      expect(metadata.pieceLength, equals(4096));
      expect(metadata.pieceCount, equals((15000 / 4096).ceil()));
      expect(metadata.files.length, equals(2));

      // 4. Transmission Model Sync
      final transmissionModel =
          transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 1001,
        'name': metadata.name,
        'totalSize': metadata.totalSize,
        'pieceCount': metadata.pieceCount,
        'pieceSize': metadata.pieceLength,
        'status': 4, // Downloading
        'percentDone': 0.0,
      });

      expect(transmissionModel.name, equals(metadata.name));
      expect(transmissionModel.totalSize, equals(metadata.totalSize));
      expect(transmissionModel.pieceCount, equals(metadata.pieceCount));
      expect(transmissionModel.pieceSize, equals(metadata.pieceLength));
    });

    test(
        'Pairwise 2: BEP 12 Multi-Tracker Tiers ↔ BEP 27 Private Flag ↔ Torrent Creation & Inspection',
        () async {
      final sampleFile = File(p.join(tempDir.path, 'secure_dataset.csv'));
      await sampleFile
          .writeAsString('id,name,value\n1,alpha,100\n2,beta,200\n');

      const trackerText = '''
http://tracker.private-corp.org:8080/announce
http://backup-tracker.private-corp.org:8080/announce

udp://fallback-tracker.private-corp.org:1337/announce
''';

      final tiers = TorrentCreatorService.parseTrackerTiers(trackerText);
      expect(tiers.length, equals(2));
      expect(tiers[0].length, equals(2));
      expect(tiers[1].length, equals(1));

      final outTorrentPath = await TorrentCreatorService.create(
        inputPath: sampleFile.path,
        outputDirectory: tempDir.path,
        trackers: tiers,
        isPrivate: true,
      );

      final torrentBytes = await File(outTorrentPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentBytes);

      expect(metadata.isPrivate, isTrue);
      expect(
        metadata.announce,
        equals('http://tracker.private-corp.org:8080/announce'),
      );
      expect(metadata.announceList.length, equals(2));
      expect(
        metadata.announceList[0],
        equals([
          'http://tracker.private-corp.org:8080/announce',
          'http://backup-tracker.private-corp.org:8080/announce',
        ]),
      );
      expect(
        metadata.announceList[1],
        equals(['udp://fallback-tracker.private-corp.org:1337/announce']),
      );
    });

    test(
        'Pairwise 3: Quota Service Monthly Cap ↔ Add Torrent Pre-Inspection Gate',
        () async {
      await QuotaService.instance.load();
      await QuotaService.instance.setEnabled(true);
      await QuotaService.instance.setQuota(1000000000); // 1 GB cap

      // Initially usage is 0 -> OK
      expect(QuotaService.instance.status, equals(QuotaStatus.ok));
      expect(await QuotaService.instance.canAddTorrent(), isTrue);

      // Establish analytics session baseline
      await AnalyticsService.instance.recordTotals(
        downloadedBytes: 0,
        uploadedBytes: 0,
      );

      // Add analytics snapshot reaching 850 MB (85% -> Warning)
      await AnalyticsService.instance.recordTotals(
        downloadedBytes: 850000000,
        uploadedBytes: 0,
      );

      expect(QuotaService.instance.status, equals(QuotaStatus.warning));
      expect(await QuotaService.instance.canAddTorrent(), isTrue);

      // Add more traffic reaching 1.2 GB (120% -> Exceeded)
      await AnalyticsService.instance.recordTotals(
        downloadedBytes: 1200000000,
        uploadedBytes: 0,
      );

      expect(QuotaService.instance.status, equals(QuotaStatus.exceeded));
      expect(await QuotaService.instance.canAddTorrent(), isFalse);

      // Disabling quota allows adding torrents again
      await QuotaService.instance.setEnabled(false);
      expect(await QuotaService.instance.canAddTorrent(), isTrue);
    });

    test(
        'Pairwise 4: Large Swarm Bitfield Unpacking ↔ Model Scaling ↔ Moov Booster Piece Indexing',
        () async {
      const pieceCount = 100000;
      const pieceSize = 16384;

      // 1. Unpack bitfield of 100,000 pieces (all true)
      final rawBytes = Uint8List((pieceCount + 7) ~/ 8);
      rawBytes.fillRange(0, rawBytes.length, 0xFF);
      final bitfield = convertBitfieldToBoolList(rawBytes, pieceCount);
      expect(bitfield.length, equals(pieceCount));

      // 2. File in second half of the torrent [pieces 50,000 .. 70,000]
      final largeFile = torrent_file.File(
        name: '4k_feature_film.mkv',
        length: 20000 * pieceSize,
        bytesCompleted: 20000 * pieceSize,
        wanted: true,
        beginPiece: 50000,
        endPiece: 70000,
      );

      final fakeTorrent = E2EPairwiseFakeTorrent(
        id: 4001,
        pieceCount: pieceCount,
        pieceSize: pieceSize,
        size: pieceCount * pieceSize,
        pieces: bitfield,
        files: [largeFile],
        speedLimitDownEnabled: true,
        speedLimitDown: 2000,
        engineRef: mockEngine,
      );

      mockEngine.activeTorrents[4001] = fakeTorrent;

      // 3. Boost for streaming
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: largeFile,
      );

      expect(mockEngine.sequentialDownloads[4001], isTrue);
      expect(mockEngine.sequentialStartPieces[4001], equals(50000));
      expect(mockEngine.highPriorityFiles[4001], contains(0));
      expect(
        mockEngine.speedLimitsDown[4001],
        equals(0),
      ); // Unlimited during buffering
    });

    test(
        'Pairwise 5: Search Results Parsing ↔ Magnet URI Extraction ↔ SSRF Host Validation',
        () async {
      const searchHtml = '''
<table>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=SafeRelease&tr=http%3A%2F%2Ftracker.safe-public.org%3A8080%2Fannounce">Safe Release</a></td>
    <td class="size">700 MB</td>
    <td class="seeds">100</td>
    <td class="leeches">10</td>
  </tr>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=EvilRelease&tr=http%3A%2F%2F192.168.1.1%3A8080%2Fannounce">Evil Release</a></td>
    <td class="size">1.2 GB</td>
    <td class="seeds">50</td>
    <td class="leeches">5</td>
  </tr>
</table>
''';

      final results = SearchService.instance
          .parseResultsForTesting('TestProvider', searchHtml);
      expect(results.length, equals(2));

      final safeResult = results[0];
      final evilResult = results[1];

      // Parse trackers from magnet links
      final safeUri = Uri.parse(safeResult.magnetLink);
      final safeTrackers = safeUri.queryParametersAll['tr'] ?? [];
      final safeTrackerHost = Uri.parse(safeTrackers.first).host;
      expect(
        IpAddressScope.isPubliclyRoutableHostSync(safeTrackerHost),
        isTrue,
      );

      final evilUri = Uri.parse(evilResult.magnetLink);
      final evilTrackers = evilUri.queryParametersAll['tr'] ?? [];
      final evilTrackerHost = Uri.parse(evilTrackers.first).host;
      expect(
        IpAddressScope.isPubliclyRoutableHostSync(evilTrackerHost),
        isFalse,
      );
    });

    test(
        'Pairwise 6: HTTP Streaming Range Seeking ↔ Moov Priority Booster ↔ Speed Limit Restoration',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'feature_stream.mp4'));
      final videoData = List<int>.generate(20000, (i) => i % 256);
      await sampleVideo.writeAsBytes(videoData);

      final torrentFile = torrent_file.File(
        name: 'feature_stream.mp4',
        length: 20000,
        bytesCompleted: 20000,
        wanted: true,
        beginPiece: 0,
        endPiece: 1,
      );

      final fakeTorrent = E2EPairwiseFakeTorrent(
        id: 6001,
        pieceCount: 2,
        pieceSize: 10000,
        size: 20000,
        pieces: [true, true],
        files: [torrentFile],
        speedLimitDownEnabled: true,
        speedLimitDown: 1500,
        engineRef: mockEngine,
      );

      mockEngine.activeTorrents[6001] = fakeTorrent;

      // Start priority boost
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: torrentFile,
      );
      expect(mockEngine.speedLimitsDown[6001], equals(0));

      // Start streaming server
      final server = StreamingServer(
        filePath: sampleVideo.path,
        bufferSize: 1024,
        torrent: fakeTorrent,
        torrentFile: torrentFile,
      );

      unawaited(server.start());
      final address = await server.getAddress();
      final uri = Uri.parse('$address/feature_stream.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2048-4095');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.partialContent));
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 2048-4095/20000'),
      );
      expect(response.contentLength, equals(2048));

      final responseBytes =
          await response.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(responseBytes, equals(videoData.sublist(2048, 4096)));

      client.close();
      await server.stop();
    });

    test(
        'Pairwise 7: Torrent Completion Event ↔ AutoExtractService ↔ Directory Traversal / Zip-Slip Defense',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      // Create an archive containing a safe file and an adversarial path traversal file
      final zipFile = File(p.join(tempDir.path, 'bundle.zip'));
      final archive = Archive();
      final safeContent = utf8.encode('Safe Text');
      final evilContent = utf8.encode('Adversarial Text');

      archive.addFile(
        ArchiveFile('docs/manual.txt', safeContent.length, safeContent),
      );
      archive.addFile(
        ArchiveFile(
          '../../outside_sandbox.txt',
          evilContent.length,
          evilContent,
        ),
      );

      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion('bundle', zipFile.path);

      // Verify safe file is extracted inside destination directory
      final safeExtracted =
          File(p.join(tempDir.path, 'bundle', 'docs', 'manual.txt'));
      expect(safeExtracted.existsSync(), isTrue);

      // Verify path traversal file did not escape
      final escaped = File(p.join(tempDir.parent.path, 'outside_sandbox.txt'));
      expect(escaped.existsSync(), isFalse);
    });

    test(
        'Pairwise 8: Seed Ratio Service Calculation ↔ Global & Per-Torrent Goals ↔ Engine Pause Lifecycle',
        () async {
      await SeedRatioService.instance.setGoal(801, 1.5);
      await SeedRatioService.instance.setGoal(802, 2.0);

      final t801 = E2EPairwiseFakeTorrent(
        id: 801,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1600, // ratio 1.6 >= 1.5
      );

      final t802 = E2EPairwiseFakeTorrent(
        id: 802,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1800, // ratio 1.8 < 2.0
      );

      final t803 = E2EPairwiseFakeTorrent(
        id: 803,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 5000, // No goal set
      );

      await SeedRatioService.instance.checkAndStop([t801, t802, t803]);

      expect(mockEngine.pausedIds, contains(801));
      expect(mockEngine.pausedIds, isNot(contains(802)));
      expect(mockEngine.pausedIds, isNot(contains(803)));

      // Verify persistence
      SeedRatioService.instance.resetForTest();
      await SeedRatioService.instance.load();
      expect(SeedRatioService.instance.getGoal(801), equals(1.5));
      expect(SeedRatioService.instance.getGoal(802), equals(2.0));
      expect(SeedRatioService.instance.getGoal(803), isNull);
    });

    test(
        'Pairwise 9: Bencode Serializer ↔ Transmission RPC Session Configuration ↔ Peer Port Validation',
        () {
      const validPort = 51413;
      expect(validPort >= 1 && validPort <= 65535, isTrue);

      final sessionReq = SessionSetRequest(
        arguments: SessionSetRequestArguments(
          peerPort: validPort,
          downloadDir: '/var/lib/torrents',
          speedLimitDown: 10000,
          speedLimitDownEnabled: true,
        ),
      );

      final rpcJson = sessionReq.toJson();
      final args = rpcJson['arguments'] as Map<String, dynamic>;

      // Map JSON RPC dictionary into BEP 0003 bencode-compatible types (booleans as 0/1)
      final bencodeCompatibleMap = {
        'method': rpcJson['method'],
        'arguments': {
          'peer-port': args['peer-port'],
          'download-dir': args['download-dir'],
          'speed-limit-down': args['speed-limit-down'],
          'speed-limit-down-enabled':
              args['speed-limit-down-enabled'] == true ? 1 : 0,
        },
      };

      final bencoded = Bencode.encode(bencodeCompatibleMap);
      final decodedRpc = Bencode.decode(bencoded) as Map<String, dynamic>;

      expect(
        utf8.decode(decodedRpc['method'] as Uint8List),
        equals('session-set'),
      );
      final decodedArgs = decodedRpc['arguments'] as Map<String, dynamic>;
      expect(decodedArgs['peer-port'], equals(51413));
      expect(
        utf8.decode(decodedArgs['download-dir'] as Uint8List),
        equals('/var/lib/torrents'),
      );
      expect(decodedArgs['speed-limit-down'], equals(10000));
      expect(decodedArgs['speed-limit-down-enabled'], equals(1));
    });

    test(
        'Pairwise 10: Multi-File Torrent Metainfo ↔ Streaming Server File Offset ↔ Byte Seeking Consistency',
        () async {
      final file1 = torrent_file.File(
        name: 'bonus_intro.mp4',
        length: 5000,
        bytesCompleted: 5000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final file2 = torrent_file.File(
        name: 'main_feature.mp4',
        length: 10000,
        bytesCompleted: 10000,
        wanted: true,
        beginPiece: 1,
        endPiece: 1,
      );

      final multiFileTorrent = E2EPairwiseFakeTorrent(
        id: 9001,
        pieceCount: 2,
        pieceSize: 10000,
        size: 15000,
        pieces: [true, true],
        files: [file1, file2],
        engineRef: mockEngine,
      );

      mockEngine.activeTorrents[9001] = multiFileTorrent;

      final sampleVideo2 = File(p.join(tempDir.path, 'main_feature.mp4'));
      final video2Data = List<int>.generate(10000, (i) => (i + 50) % 256);
      await sampleVideo2.writeAsBytes(video2Data);

      final server = StreamingServer(
        filePath: sampleVideo2.path,
        bufferSize: 1024,
        torrent: multiFileTorrent,
        torrentFile: file2,
      );

      unawaited(server.start());
      final address = await server.getAddress();
      final uri = Uri.parse('$address/main_feature.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=500-1499');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.partialContent));
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 500-1499/10000'),
      );
      expect(response.contentLength, equals(1000));

      final responseBytes =
          await response.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(responseBytes, equals(video2Data.sublist(500, 1500)));

      client.close();
      await server.stop();
    });

    test(
        'Pairwise 11: Settings Port & RPC Session Set ↔ Blocklist SSRF URL Validation',
        () async {
      // 1. SessionSetRequest with peer-port boundary and download-dir
      final sessionSet = SessionSetRequest(
        arguments: SessionSetRequestArguments(
          peerPort: 6881,
          downloadDir: '/custom/downloads',
          speedLimitUpEnabled: true,
          speedLimitUp: 5000,
        ),
      );
      final jsonRpc = sessionSet.toJson();
      final args = jsonRpc['arguments'] as Map<String, dynamic>;
      expect(args['peer-port'], equals(6881));
      expect(args['download-dir'], equals('/custom/downloads'));
      expect(args['speed-limit-up'], equals(5000));
      expect(args['speed-limit-up-enabled'], isTrue);

      // 2. Encode Session config into Bencode dictionary and decode back
      final bencodeMap = {
        'method': jsonRpc['method'],
        'arguments': {
          'peer-port': args['peer-port'],
          'download-dir': args['download-dir'],
          'speed-limit-up': args['speed-limit-up'],
          'speed-limit-up-enabled': args['speed-limit-up-enabled'] == true ? 1 : 0,
        },
      };
      final bencoded = Bencode.encode(bencodeMap);
      final decoded = Bencode.decode(bencoded) as Map<String, dynamic>;
      final decodedArgs = decoded['arguments'] as Map<String, dynamic>;
      expect(decodedArgs['peer-port'], equals(6881));
      expect(
        utf8.decode(decodedArgs['download-dir'] as Uint8List),
        equals('/custom/downloads'),
      );

      // 3. Blocklist SSRF safety check on remote host vs private/loopback hosts
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('blocklist.example.org'),
        isTrue,
      );
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('127.0.0.1'),
        isFalse,
      );
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('192.168.1.100'),
        isFalse,
      );
      expect(
        IpAddressScope.isPubliclyRoutableHostSync('10.0.0.1'),
        isFalse,
      );

      // 4. BlocklistService SSRF handling
      expect(
        await BlocklistService.isValidBlocklistUrl('http://127.0.0.1:8080/bad_blocklist.txt'),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl('http://169.254.169.254/latest/meta-data'),
        isFalse,
      );
    });

    test(
        'Pairwise 12: Search Engine Parsing ↔ Bencode Torrent Metainfo ↔ AutoExtractService Zip-Slip Validation',
        () async {
      // 1. Parse search result HTML
      const searchHtml = '''
<table>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=Archived+Package+v1&tr=http%3A%2F%2Ftracker.public.org%2Fannounce">Archived Package v1</a></td>
    <td class="size">50.0 KB</td>
    <td class="seeds">100</td>
    <td class="leeches">5</td>
  </tr>
</table>
''';
      final searchResults = SearchService.instance
          .parseResultsForTesting('PublicProvider', searchHtml);
      expect(searchResults.length, equals(1));
      final result = searchResults.first;
      expect(result.title, equals('Archived Package v1'));
      expect(result.magnetLink, contains('fedcba9876543210fedcba9876543210fedcba98'));

      // 2. Create zip archive with safe file and zip-slip attempt
      final pkgDir = Directory(p.join(tempDir.path, 'pkg_source'))..createSync();
      final readme = File(p.join(pkgDir.path, 'README.txt'))..writeAsStringSync('Package content');

      final zipFile = File(p.join(tempDir.path, 'package.zip'));
      final archive = Archive();
      archive.addFile(ArchiveFile('README.txt', readme.lengthSync(), readme.readAsBytesSync()));
      // Malicious zip slip entry
      final maliciousData = utf8.encode('pwned');
      archive.addFile(ArchiveFile('../../../evil.txt', maliciousData.length, maliciousData));

      final zipBytes = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipBytes);

      // 3. Create bencoded torrent metainfo for the zip package
      final torrentPath = await TorrentCreatorService.create(
        inputPath: zipFile.path,
        outputDirectory: tempDir.path,
        pieceLength: 16384,
        comment: 'Archived Package v1 Metainfo',
      );
      final torrentBytes = await File(torrentPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentBytes);
      expect(metadata.name, equals('package.zip'));
      expect(metadata.totalSize, equals(zipBytes.length));

      // 4. AutoExtractService extraction with zip-slip containment
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      await autoExtract.handleTorrentCompletion(
        'Archived Package v1',
        zipFile.path,
      );

      // 5. Verify safe extraction inside extractDest / package subdir, and no escape
      final extractedReadme = File(p.join(tempDir.path, 'Archived Package v1', 'README.txt'));
      expect(extractedReadme.existsSync(), isTrue);
      expect(extractedReadme.readAsStringSync(), equals('Package content'));

      final escapedFile = File(p.join(tempDir.parent.path, 'evil.txt'));
      expect(escapedFile.existsSync(), isFalse);
    });
  });
}
