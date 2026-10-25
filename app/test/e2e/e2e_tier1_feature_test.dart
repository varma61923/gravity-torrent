import 'dart:async';
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
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/session_get_request.dart';
import 'package:gravity_torrent/engine/transmission/models/session_get_response.dart';
import 'package:gravity_torrent/engine/transmission/models/session_set_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart'
    as transmission_torrent;
import 'package:gravity_torrent/engine/transmission/models/torrent_action_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_add_request.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
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
// Test Helpers & Mock Engine
// ===========================================================================

class E2ETestMockEngine implements Engine {
  final List<int> pausedIds = [];
  final List<int> resumedIds = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> speedLimitsDown = {};
  final Map<int, List<int>> highPriorityFiles = {};
  Torrent Function(int id)? onFetchTorrent;

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
    if (onFetchTorrent != null) {
      return onFetchTorrent!(id);
    }
    return E2ETestFakeTorrent(
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

class E2ETestFakeTorrent extends Torrent {
  final E2ETestMockEngine? engineRef;

  E2ETestFakeTorrent({
    required super.id,
    super.name = 'E2E Test Torrent',
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

  late E2ETestMockEngine mockEngine;
  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();
    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();

    mockEngine = E2ETestMockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;

    tempDir = await Directory.systemTemp.createTemp('gravity_e2e_tier1_');
  });

  tearDown(() async {
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // =========================================================================
  // F1: Bencode Encoding & Decoding (BEP 0003)
  // =========================================================================
  group('Tier 1 - F1: Bencode Encoding & Decoding (BEP 0003)', () {
    test('F1.1: Integer roundtrip for 0, positive, large, and negative values',
        () {
      final testIntegers = [0, 42, 1048576, -1, -99999, 9007199254740991];
      for (final val in testIntegers) {
        final encoded = Bencode.encode(val);
        final decoded = Bencode.decode(encoded);
        expect(decoded, equals(val));
      }
    });

    test('F1.2: String & Binary byte-string roundtrip with UTF-8 and raw bytes',
        () {
      const strVal = 'Gravity Torrent 🚀 — Cross-Platform P2P';
      final encodedStr = Bencode.encode(strVal);
      final decodedStr = Bencode.decode(encodedStr);
      expect(decodedStr is Uint8List, isTrue);
      expect(utf8.decode(decodedStr as Uint8List), equals(strVal));

      final rawBinary =
          Uint8List.fromList([0x00, 0xFF, 0x80, 0x7F, 0x1A, 0x2B]);
      final encodedBin = Bencode.encode(rawBinary);
      final decodedBin = Bencode.decode(encodedBin);
      expect(decodedBin, equals(rawBinary));
    });

    test('F1.3: Nested heterogeneous list encoding and decoding', () {
      final list = [
        123,
        'bittorrent',
        [456, 'sublist'],
        {'nested_key': 789},
      ];
      final encoded = Bencode.encode(list);
      final decoded = Bencode.decode(encoded) as List<dynamic>;

      expect(decoded.length, equals(4));
      expect(decoded[0], equals(123));
      expect(utf8.decode(decoded[1] as Uint8List), equals('bittorrent'));
      expect((decoded[2] as List<dynamic>)[0], equals(456));
      final mapEntry = decoded[3] as Map<String, dynamic>;
      expect(mapEntry['nested_key'], equals(789));
    });

    test('F1.4: Strict lexicographical byte-order sorting in dictionary keys',
        () {
      final unorderedMap = {
        'zebra': 100,
        'apple': 200,
        'Banana': 300, // ASCII 'B' (0x42) < 'a' (0x61)
        'apple_pie': 400,
      };
      final encoded = Bencode.encode(unorderedMap);
      final encodedString = String.fromCharCodes(encoded);

      // Verify canonical key sequence: "Banana" -> "apple" -> "apple_pie" -> "zebra"
      expect(
        encodedString,
        equals('d6:Bananai300e5:applei200e9:apple_piei400e5:zebrai100ee'),
      );

      final decoded = Bencode.decode(encoded) as Map<String, dynamic>;
      expect(decoded['zebra'], equals(100));
      expect(decoded['apple'], equals(200));
      expect(decoded['Banana'], equals(300));
      expect(decoded['apple_pie'], equals(400));
    });

    test(
        'F1.5: Metainfo decodeTorrent structure with infoHash and hex computation',
        () {
      final dummyPieces = Uint8List(40); // 2 pieces * 20 bytes
      for (int i = 0; i < 40; i++) {
        dummyPieces[i] = i % 256;
      }

      final infoDict = {
        'length': 32768,
        'name': 'single_file.iso',
        'piece length': 16384,
        'pieces': dummyPieces,
      };

      final rootDict = {
        'announce': 'http://tracker.example.com/announce',
        'comment': 'Test Torrent Creation',
        'info': infoDict,
      };

      final encoded = Bencode.encode(rootDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.name, equals('single_file.iso'));
      expect(metadata.totalSize, equals(32768));
      expect(metadata.pieceLength, equals(16384));
      expect(metadata.pieceCount, equals(2));
      expect(metadata.isMultiFile, isFalse);
      expect(metadata.files.length, equals(1));
      expect(metadata.files.first.path, equals('single_file.iso'));

      // InfoHash verification
      final expectedDigest = sha1.convert(Bencode.encode(infoDict));
      expect(
        metadata.infoHash,
        equals(Uint8List.fromList(expectedDigest.bytes)),
      );
      expect(
        metadata.infoHashHex,
        equals(expectedDigest.toString().toLowerCase()),
      );
    });
  });

  // =========================================================================
  // F2: Metainfo Pre-Add Inspection
  // =========================================================================
  group('Tier 1 - F2: Metainfo Pre-Add Inspection', () {
    test('F2.1: Single-file metadata inspection and predicted size', () {
      final pieces = Uint8List(20);
      final meta = {
        'info': {
          'length': 1048576,
          'name': 'ubuntu-24.04-live-server.iso',
          'piece length': 524288,
          'pieces': pieces,
        },
      };
      final decoded = Bencode.decodeTorrent(Bencode.encode(meta));
      expect(decoded.name, equals('ubuntu-24.04-live-server.iso'));
      expect(decoded.totalSize, equals(1048576));
      expect(decoded.pieceCount, equals(1));
      expect(decoded.files.first.length, equals(1048576));
    });

    test(
        'F2.2: Multi-file hierarchical tree pre-add inspection and size summation',
        () {
      final pieces = Uint8List(60); // 3 pieces
      final meta = {
        'info': {
          'name': 'Album_Release',
          'piece length': 262144,
          'pieces': pieces,
          'files': [
            {
              'length': 200000,
              'path': ['disc1', 'track01.flac'],
            },
            {
              'length': 300000,
              'path': ['disc1', 'track02.flac'],
            },
            {
              'length': 10000,
              'path': ['artwork', 'cover.jpg'],
            },
          ],
        },
      };
      final decoded = Bencode.decodeTorrent(Bencode.encode(meta));
      expect(decoded.isMultiFile, isTrue);
      expect(decoded.name, equals('Album_Release'));
      expect(decoded.totalSize, equals(510000));
      expect(decoded.files.length, equals(3));
      expect(decoded.files[0].path, equals(p.join('disc1', 'track01.flac')));
      expect(decoded.files[1].path, equals(p.join('disc1', 'track02.flac')));
      expect(decoded.files[2].path, equals(p.join('artwork', 'cover.jpg')));
    });

    test('F2.3: Piece hash extraction for individual piece verification', () {
      final pieces = Uint8List(40);
      pieces[0] = 0xAA;
      pieces[19] = 0xBB;
      pieces[20] = 0xCC;
      pieces[39] = 0xDD;

      final meta = {
        'info': {
          'length': 32768,
          'name': 'test.bin',
          'piece length': 16384,
          'pieces': pieces,
        },
      };
      final decoded = Bencode.decodeTorrent(Bencode.encode(meta));
      final piece0 = decoded.getPieceHash(0);
      final piece1 = decoded.getPieceHash(1);

      expect(piece0.length, equals(20));
      expect(piece0[0], equals(0xAA));
      expect(piece0[19], equals(0xBB));
      expect(piece1[0], equals(0xCC));
      expect(piece1[19], equals(0xDD));
    });

    test('F2.4: Free space quota validation via QuotaService', () async {
      await QuotaService.instance.load();
      await QuotaService.instance.setEnabled(false);
      expect(await QuotaService.instance.canAddTorrent(), isTrue);

      await QuotaService.instance.setEnabled(true);
      await QuotaService.instance.setQuota(1000000000);
      expect(await QuotaService.instance.canAddTorrent(), isTrue);
    });

    test('F2.5: BEP 27 private flag detection in metainfo inspection', () {
      final pieces = Uint8List(20);
      final privateMeta = {
        'info': {
          'length': 1000,
          'name': 'private_tracker.dat',
          'piece length': 1000,
          'pieces': pieces,
          'private': 1,
        },
      };
      final decoded = Bencode.decodeTorrent(Bencode.encode(privateMeta));
      expect(decoded.isPrivate, isTrue);
    });
  });

  // =========================================================================
  // F3: Transmission Model & Bitfield Unpacking
  // =========================================================================
  group('Tier 1 - F3: Transmission Model & Bitfield Unpacking', () {
    test('F3.1: Large swarm pieceCount scaling > 1,000,000 without clamping',
        () {
      final model = transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 42,
        'name': 'Large Swarm',
        'pieceCount': 2000000,
        'pieceSize': 16384,
        'totalSize': 32768000000,
        'status': 4,
        'pieces': '',
      });
      expect(model.pieceCount, equals(2000000));
    });

    test('F3.2: Base64 bitfield exact unpacking for byte alignment', () {
      final bytes = Uint8List.fromList([0xA0]);
      final bitfield = convertBitfieldToBoolList(bytes, 8);

      expect(bitfield.length, equals(8));
      expect(bitfield[0], isTrue);
      expect(bitfield[1], isFalse);
      expect(bitfield[2], isTrue);
      expect(bitfield[3], isFalse);
      expect(bitfield[4], isFalse);
      expect(bitfield[5], isFalse);
      expect(bitfield[6], isFalse);
      expect(bitfield[7], isFalse);
    });

    test('F3.3: Partial byte bitfield remainder unpacking', () {
      final bytes = Uint8List.fromList([0xFF, 0xF8]);
      final bitfield = convertBitfieldToBoolList(bytes, 13);

      expect(bitfield.length, equals(13));
      for (int i = 0; i < 13; i++) {
        expect(bitfield[i], isTrue);
      }
    });

    test('F3.4: Torrent model calculated getters and properties', () {
      final pieces = [true, true, false, false];
      final torrent = E2ETestFakeTorrent(
        id: 1,
        pieceCount: 4,
        pieceSize: 1000,
        size: 4000,
        pieces: pieces,
        downloadedEver: 2000,
        uploadedEver: 4000,
      );

      expect(torrent.pieces.where((p) => p).length, equals(2));
      expect(torrent.size, equals(4000));
      expect(torrent.downloadedEver, equals(2000));
      expect(torrent.uploadedEver, equals(4000));
    });

    test('F3.5: Large bitfield unpacking with 10,000 bits', () {
      const totalBits = 10000;
      const totalBytes = (totalBits + 7) ~/ 8;
      final rawBytes = Uint8List(totalBytes);
      for (int i = 0; i < totalBytes; i++) {
        rawBytes[i] = i % 2 == 0 ? 0xAA : 0x55;
      }
      final bitfield = convertBitfieldToBoolList(rawBytes, totalBits);

      expect(bitfield.length, equals(totalBits));
      expect(bitfield[0], isTrue);
      expect(bitfield[1], isFalse);
      expect(bitfield[8], isFalse);
      expect(bitfield[9], isTrue);
    });
  });

  // =========================================================================
  // F4: Static Analysis & Lint Cleanliness
  // =========================================================================
  group('Tier 1 - F4: Static Analysis & Lint Cleanliness (Type Models)', () {
    test(
        'F4.1: Strongly typed Torrent model JSON serialization & deserialization',
        () {
      final rawJson = {
        'id': 101,
        'name': 'Typed Torrent',
        'status': 6, // Seeding
        'percentDone': 1.0,
        'totalSize': 1048576,
        'downloadedEver': 1048576,
        'uploadedEver': 2097152,
        'pieceCount': 64,
        'pieceSize': 16384,
        'pieces': '',
        'rateDownload': 0,
        'rateUpload': 512000,
      };

      final parsed =
          transmission_torrent.TransmissionTorrentModel.fromJson(rawJson);
      expect(parsed.id, equals(101));
      expect(parsed.name, equals('Typed Torrent'));
      expect(parsed.status, equals(TorrentStatus.seeding));
      expect(parsed.percentDone, equals(1.0));
      expect(parsed.totalSize, equals(1048576));
    });

    test('F4.2: SessionSetRequest typed serialization', () {
      final req = SessionSetRequest(
        arguments: SessionSetRequestArguments(
          peerPort: 51413,
          downloadDir: '/downloads',
          speedLimitDown: 5000,
          speedLimitDownEnabled: true,
          speedLimitUp: 2500,
          speedLimitUpEnabled: true,
        ),
      );

      final jsonMap = req.toJson();
      expect(jsonMap['method'], equals('session-set'));
      final args = jsonMap['arguments'] as Map<String, dynamic>;
      expect(args['peer-port'], equals(51413));
      expect(args['download-dir'], equals('/downloads'));
      expect(args['speed-limit-down'], equals(5000));
      expect(args['speed-limit-down-enabled'], isTrue);
    });

    test('F4.3: SessionGetRequest and SessionGetResponse type contracts', () {
      final getReq = SessionGetRequest(
        arguments: SessionGetRequestArguments(
          fields: [SessionField.peerPort, SessionField.downloadDir],
        ),
      );
      final jsonReq = getReq.toJson();
      expect(jsonReq['method'], equals('session-get'));
      expect(
        (jsonReq['arguments'] as Map<String, dynamic>)['fields'],
        contains('peer-port'),
      );

      final respJson = {
        'arguments': {
          'peer-port': 51413,
          'download-dir': '/var/torrents',
          'version': '4.0.0',
        },
        'result': 'success',
      };
      final resp = SessionGetResponse.fromJson(respJson);
      expect(resp.arguments.peerPort, equals(51413));
      expect(resp.arguments.downloadDir, equals('/var/torrents'));
    });

    test('F4.4: TorrentActionRequest type safety across start, stop, verify',
        () {
      final startReq = TorrentActionRequest(
        action: TorrentAction.start,
        arguments: TorrentActionRequestArguments(ids: [1, 2, 3]),
      );
      expect(startReq.toJson()['method'], equals('torrent-start'));
      expect(
        (startReq.toJson()['arguments'] as Map<String, dynamic>)['ids'],
        equals([1, 2, 3]),
      );

      final stopReq = TorrentActionRequest(
        action: TorrentAction.stop,
        arguments: TorrentActionRequestArguments(ids: [4]),
      );
      expect(stopReq.toJson()['method'], equals('torrent-stop'));
    });

    test(
        'F4.5: TorrentAddRequest typed parameters with metainfo and download-dir',
        () {
      final addReq = TorrentAddRequest(
        arguments: TorrentAddRequestArguments(
          metainfo: 'ZDEwOmFubm91bmNl...',
          downloadDir: '/custom/storage',
        ),
      );
      final jsonMap = addReq.toJson();
      expect(jsonMap['method'], equals('torrent-add'));
      final args = jsonMap['arguments'] as Map<String, dynamic>;
      expect(args['metainfo'], equals('ZDEwOmFubm91bmNl...'));
      expect(args['download-dir'], equals('/custom/storage'));
    });
  });

  // =========================================================================
  // F5: Blocklist & SSRF Protections
  // =========================================================================
  group('Tier 1 - F5: Blocklist & SSRF Protections', () {
    test('F5.1: RFC 1918 Private IPv4 address classification', () {
      final privateIps = [
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.1',
        '192.168.254.254',
      ];
      for (final ipStr in privateIps) {
        final addr = InternetAddress(ipStr);
        expect(IpAddressScope.classify(addr), equals(AddressScope.private));
        expect(IpAddressScope.isPubliclyRoutable(addr), isFalse);
        expect(IpAddressScope.isPrivate(addr), isTrue);
      }
    });

    test('F5.2: Loopback and Link-Local address classification', () {
      final loopbacks = ['127.0.0.1', '127.0.0.254', '::1'];
      for (final ipStr in loopbacks) {
        final addr = InternetAddress(ipStr);
        expect(IpAddressScope.classify(addr), equals(AddressScope.loopback));
        expect(IpAddressScope.isPubliclyRoutable(addr), isFalse);
      }

      final linkLocals = ['169.254.1.1', 'fe80::1'];
      for (final ipStr in linkLocals) {
        final addr = InternetAddress(ipStr);
        expect(IpAddressScope.classify(addr), equals(AddressScope.linkLocal));
        expect(IpAddressScope.isPubliclyRoutable(addr), isFalse);
      }
    });

    test('F5.3: CGNAT and IPv6 Unique Local (ULA) classification', () {
      final cgnat = InternetAddress('100.64.0.1');
      expect(IpAddressScope.classify(cgnat), equals(AddressScope.cgnat));
      expect(IpAddressScope.isPubliclyRoutable(cgnat), isFalse);

      final ula = InternetAddress('fd00::1');
      expect(IpAddressScope.classify(ula), equals(AddressScope.uniqueLocal));
      expect(IpAddressScope.isPubliclyRoutable(ula), isFalse);
    });

    test('F5.4: Public routable IP addresses classification', () {
      final publicIps = [
        '8.8.8.8',
        '1.1.1.1',
        '93.184.216.34',
        '2606:4700:4700::1111',
      ];
      for (final ipStr in publicIps) {
        final addr = InternetAddress(ipStr);
        expect(IpAddressScope.classify(addr), equals(AddressScope.global));
        expect(IpAddressScope.isPubliclyRoutable(addr), isTrue);
        expect(IpAddressScope.isPrivate(addr), isFalse);
      }
    });

    test('F5.5: BlocklistService URL SSRF safety validation', () async {
      final isPublicValid = await BlocklistService.isValidBlocklistUrl(
        'https://raw.githubusercontent.com/Naunter/BT_BlockList/master/bt_blocklist.txt',
        lookup: (_) async => [InternetAddress('185.199.108.133')],
      );
      expect(isPublicValid, isTrue);

      final isPrivateValid = await BlocklistService.isValidBlocklistUrl(
        'http://192.168.1.1/internal_blocklist.txt',
      );
      expect(isPrivateValid, isFalse);

      final isLoopbackValid = await BlocklistService.isValidBlocklistUrl(
        'http://127.0.0.1:8080/blocklist.txt',
      );
      expect(isLoopbackValid, isFalse);
    });
  });

  // =========================================================================
  // F6: Settings & Port Validation
  // =========================================================================
  group('Tier 1 - F6: Settings & Port Validation (1..65535, fallback 51413)',
      () {
    testWidgets('F6.1: Valid port 8080 acceptance and onSave invocation',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 8080,
              onSave: (p) => savedPort = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(TextButton, 'Save');
      expect(saveButton, findsOneWidget);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(savedPort, equals(8080));
    });

    testWidgets('F6.2: Lower bound port 1 valid acceptance', (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 1,
              onSave: (p) => savedPort = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(1));
    });

    testWidgets('F6.3: Upper bound port 65535 valid acceptance',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 65535,
              onSave: (p) => savedPort = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(65535));
    });

    testWidgets('F6.4: Fallback default port 51413 when initial value is 0',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 0,
              onSave: (p) => savedPort = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      expect(textField, findsOneWidget);
      final text = (tester.widget(textField) as TextFormField).controller?.text;
      expect(text, equals('51413'));

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(51413));
    });

    testWidgets('F6.5: Input change to valid port within range saves correctly',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PeerPortDialog(
              currentValue: 51413,
              onSave: (p) => savedPort = p,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '6881');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(6881));
    });
  });

  // =========================================================================
  // F7: Multi-Tracker Tiers & Creation (BEP 12 & BEP 27)
  // =========================================================================
  group('Tier 1 - F7: Multi-Tracker Tiers & Creation (BEP 12, BEP 27)', () {
    test('F7.1: BEP 12 parse single tier with multiple tracker lines', () {
      const input = '''
http://tracker1.org:8080/announce
udp://tracker2.org:1337/announce
https://tracker3.org/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(1));
      expect(tiers.first.length, equals(3));
      expect(tiers.first[0], equals('http://tracker1.org:8080/announce'));
      expect(tiers.first[1], equals('udp://tracker2.org:1337/announce'));
      expect(tiers.first[2], equals('https://tracker3.org/announce'));
    });

    test('F7.2: BEP 12 parse multiple tiers separated by blank lines', () {
      const input = '''
http://tier1-tracker1.org/announce
http://tier1-tracker2.org/announce

udp://tier2-tracker1.org/announce

http://tier3-tracker1.org/announce
http://tier3-tracker2.org/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(3));
      expect(
        tiers[0],
        equals([
          'http://tier1-tracker1.org/announce',
          'http://tier1-tracker2.org/announce',
        ]),
      );
      expect(tiers[1], equals(['udp://tier2-tracker1.org/announce']));
      expect(
        tiers[2],
        equals([
          'http://tier3-tracker1.org/announce',
          'http://tier3-tracker2.org/announce',
        ]),
      );
    });

    test('F7.3: BEP 27 private flag in torrent creation', () async {
      final sampleFile = File(p.join(tempDir.path, 'private_test.bin'));
      await sampleFile.writeAsBytes(List.filled(1024, 0x55));

      final outPath = await TorrentCreatorService.create(
        inputPath: sampleFile.path,
        outputDirectory: tempDir.path,
        isPrivate: true,
      );

      final torrentBytes = await File(outPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentBytes);
      expect(metadata.isPrivate, isTrue);
      expect(metadata.name, equals('private_test.bin'));
    });

    test('F7.4: Public torrent creation without private flag', () async {
      final sampleFile = File(p.join(tempDir.path, 'public_test.bin'));
      await sampleFile.writeAsBytes(List.filled(1024, 0xAA));

      final outPath = await TorrentCreatorService.create(
        inputPath: sampleFile.path,
        outputDirectory: tempDir.path,
        isPrivate: false,
      );

      final torrentBytes = await File(outPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentBytes);
      expect(metadata.isPrivate, isFalse);
    });

    test('F7.5: Multi-tracker torrent file creation with announce-list',
        () async {
      final sampleFile = File(p.join(tempDir.path, 'multi_tracker.bin'));
      await sampleFile.writeAsBytes(List.filled(2048, 0x12));

      final trackers = [
        ['http://t1.org/announce', 'http://t2.org/announce'],
        ['udp://t3.org/announce'],
      ];

      final outPath = await TorrentCreatorService.create(
        inputPath: sampleFile.path,
        outputDirectory: tempDir.path,
        trackers: trackers,
      );

      final torrentBytes = await File(outPath).readAsBytes();
      final metadata = Bencode.decodeTorrent(torrentBytes);

      expect(metadata.announce, equals('http://t1.org/announce'));
      expect(metadata.announceList.length, equals(2));
      expect(
        metadata.announceList[0],
        equals(['http://t1.org/announce', 'http://t2.org/announce']),
      );
      expect(metadata.announceList[1], equals(['udp://t3.org/announce']));
    });
  });

  // =========================================================================
  // F8: Seed Ratio Automation
  // =========================================================================
  group('Tier 1 - F8: Seed Ratio Automation', () {
    test(
        'F8.1: Standard seed ratio calculation (uploadedEver / downloadedEver)',
        () {
      final t = E2ETestFakeTorrent(
        id: 1,
        downloadedEver: 1000,
        uploadedEver: 2500,
        size: 5000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(2.5));
    });

    test('F8.2: Initial seeder ratio fallback (uploadedEver / size)', () {
      final t = E2ETestFakeTorrent(
        id: 2,
        downloadedEver: 0,
        uploadedEver: 3000,
        size: 2000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(1.5));
    });

    test(
        'F8.3: Zero downloaded and zero size returns 0.0 without divide-by-zero',
        () {
      final t = E2ETestFakeTorrent(
        id: 3,
        downloadedEver: 0,
        uploadedEver: 0,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test(
        'F8.4: Auto-stop filter pauses seeding torrents exceeding personal goal',
        () async {
      await SeedRatioService.instance.setGoal(10, 2.0);

      final t10 = E2ETestFakeTorrent(
        id: 10,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2000, // ratio 2.0 >= 2.0
      );

      final t11 = E2ETestFakeTorrent(
        id: 11,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1500, // ratio 1.5 < 2.0
      );

      await SeedRatioService.instance.checkAndStop([t10, t11]);
      expect(mockEngine.pausedIds, contains(10));
      expect(mockEngine.pausedIds, isNot(contains(11)));
    });

    test(
        'F8.5: Ignored IDs filter excludes matching torrents from auto-stopping',
        () async {
      await SeedRatioService.instance.setGoal(20, 1.0);

      final t20 = E2ETestFakeTorrent(
        id: 20,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 3000, // ratio 3.0
      );

      await SeedRatioService.instance.checkAndStop([t20], {20});
      expect(mockEngine.pausedIds, isNot(contains(20)));
    });
  });

  // =========================================================================
  // F9: Search Engine Parsing
  // =========================================================================
  group('Tier 1 - F9: Search Engine Parsing (JSON, Torznab/XML, HTML)', () {
    test('F9.1: JSON search API response parsing', () {
      final jsonResponse = jsonEncode([
        {
          'title': 'Debian Linux ISO',
          'magnetLink':
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Debian',
          'size': 2147483648,
          'seeders': 150,
          'leechers': 25,
          'source': 'TestTracker',
        }
      ]);

      final results = SearchService.instance
          .parseResultsForTesting('TestTracker', jsonResponse);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Debian Linux ISO'));
      expect(results.first.size, equals(2147483648));
      expect(results.first.seeders, equals(150));
      expect(results.first.leechers, equals(25));
    });

    test('F9.2: XML / Torznab RSS feed parsing', () {
      const xmlResponse = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <item>
      <title>Arch Linux 2026.08</title>
      <link>magnet:?xt=urn:btih:1111222233334444555566667777888899990000&amp;dn=Arch</link>
      <size>1073741824</size>
      <torznab:attr name="seeders" value="300"/>
      <torznab:attr name="peers" value="350"/>
    </item>
  </channel>
</rss>''';

      final results = SearchService.instance
          .parseResultsForTesting('TorznabSource', xmlResponse);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Arch Linux 2026.08'));
      expect(results.first.seeders, equals(300));
      expect(results.first.size, equals(1073741824));
    });

    test('F9.3: HTML table format parsing with regex extraction', () {
      const htmlTable = '''
<table>
  <tr>
    <td class="name"><a class="detLink" href="magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12&dn=Ubuntu">Ubuntu 24.04 Server</a></td>
    <td class="size">1.5 GB</td>
    <td class="seeds">250</td>
    <td class="leeches">15</td>
  </tr>
</table>
''';
      final results = SearchService.instance
          .parseResultsForTesting('HtmlTableSource', htmlTable);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Ubuntu 24.04 Server'));
      expect(results.first.seeders, equals(250));
      expect(results.first.leechers, equals(15));
      expect(results.first.size, equals(1610612736)); // 1.5 * 1024^3
    });

    test('F9.4: HTML card format parsing with divs', () {
      const htmlCards = '''
<div class="torrent-card">
  <h3 class="torrent-title">Fedora Workstation 42</h3>
  <a href="magnet:?xt=urn:btih:feedfacefeedfacefeedfacefeedfacefeedface&dn=Fedora">Download</a>
  <span class="size">2.0 GB</span>
  <span class="seeders">80</span>
  <span class="leechers">5</span>
</div>
''';
      final results = SearchService.instance
          .parseResultsForTesting('HtmlCardSource', htmlCards);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Fedora Workstation 42'));
      expect(results.first.seeders, equals(80));
      expect(results.first.size, equals(2147483648));
    });

    test('F9.5: Fallback magnet link construction from info_hash link in table',
        () {
      const htmlWithHash = '''
<table>
  <tr>
    <td><a class="detLink" href="/torrent/0123456789abcdef0123456789abcdef01234567">Gentoo Minimal ISO</a></td>
    <td class="size">500 MB</td>
    <td class="seeds">40</td>
    <td class="leeches">2</td>
  </tr>
</table>
''';
      final results = SearchService.instance
          .parseResultsForTesting('HashSource', htmlWithHash);
      expect(results.length, equals(1));
      expect(
        results.first.magnetLink,
        contains('xt=urn:btih:0123456789abcdef0123456789abcdef01234567'),
      );
    });
  });

  // =========================================================================
  // F10: Streaming Server & Moov Booster
  // =========================================================================
  group('Tier 1 - F10: Streaming Server & Moov Booster', () {
    test('F10.1: RFC 9110 HTTP Range header seeking (206 Partial Content)',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'video.mp4'));
      final videoData = List<int>.generate(10000, (i) => i % 256);
      await sampleVideo.writeAsBytes(videoData);

      final torrentFile = torrent_file.File(
        name: 'video.mp4',
        length: 10000,
        bytesCompleted: 10000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2ETestFakeTorrent(
        id: 200,
        pieceCount: 1,
        pieceSize: 10000,
        pieces: [true],
        files: [torrentFile],
        engineRef: mockEngine,
      );

      final server = StreamingServer(
        filePath: sampleVideo.path,
        bufferSize: 1024,
        torrent: fakeTorrent,
        torrentFile: torrentFile,
      );

      unawaited(server.start());
      final address = await server.getAddress();
      final uri = Uri.parse('$address/video.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-999');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.partialContent));
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 0-999/10000'),
      );
      expect(response.contentLength, equals(1000));

      final responseBytes =
          await response.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(responseBytes, equals(videoData.sublist(0, 1000)));

      client.close();
      await server.stop();
    });

    test('F10.2: RFC 9110 open-ended Range request (bytes=5000-)', () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_open.mp4'));
      final videoData = List<int>.generate(8000, (i) => i % 256);
      await sampleVideo.writeAsBytes(videoData);

      final torrentFile = torrent_file.File(
        name: 'video_open.mp4',
        length: 8000,
        bytesCompleted: 8000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2ETestFakeTorrent(
        id: 201,
        pieceCount: 1,
        pieceSize: 8000,
        pieces: [true],
        files: [torrentFile],
        engineRef: mockEngine,
      );

      final server = StreamingServer(
        filePath: sampleVideo.path,
        bufferSize: 1024,
        torrent: fakeTorrent,
        torrentFile: torrentFile,
      );

      unawaited(server.start());
      final address = await server.getAddress();
      final uri = Uri.parse('$address/video_open.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.partialContent));
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 5000-7999/8000'),
      );
      expect(response.contentLength, equals(3000));

      final responseBytes =
          await response.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(responseBytes, equals(videoData.sublist(5000, 8000)));

      client.close();
      await server.stop();
    });

    test('F10.3: RFC 9110 suffix Range request (bytes=-1000)', () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_suffix.mp4'));
      final videoData = List<int>.generate(5000, (i) => i % 256);
      await sampleVideo.writeAsBytes(videoData);

      final torrentFile = torrent_file.File(
        name: 'video_suffix.mp4',
        length: 5000,
        bytesCompleted: 5000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2ETestFakeTorrent(
        id: 202,
        pieceCount: 1,
        pieceSize: 5000,
        pieces: [true],
        files: [torrentFile],
        engineRef: mockEngine,
      );

      final server = StreamingServer(
        filePath: sampleVideo.path,
        bufferSize: 1024,
        torrent: fakeTorrent,
        torrentFile: torrentFile,
      );

      unawaited(server.start());
      final address = await server.getAddress();
      final uri = Uri.parse('$address/video_suffix.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=-1000');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.partialContent));
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes 4000-4999/5000'),
      );
      expect(response.contentLength, equals(1000));

      final responseBytes =
          await response.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(responseBytes, equals(videoData.sublist(4000, 5000)));

      client.close();
      await server.stop();
    });

    test('F10.4: MoovPriorityBooster file piece priority boosting', () async {
      final videoFile = torrent_file.File(
        name: 'movie.mp4',
        length: 10000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 10,
        endPiece: 90,
      );

      final fakeTorrent = E2ETestFakeTorrent(
        id: 203,
        pieceCount: 100,
        pieceSize: 100000,
        files: [videoFile],
        speedLimitDownEnabled: true,
        speedLimitDown: 500,
        engineRef: mockEngine,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: videoFile,
      );

      expect(mockEngine.sequentialDownloads[203], isTrue);
      expect(mockEngine.sequentialStartPieces[203], equals(10));
      expect(mockEngine.highPriorityFiles[203], contains(0));
      expect(
        mockEngine.speedLimitsDown[203],
        equals(0),
      ); // Unlimited during buffering
    });

    test('F10.5: MoovPriorityBooster session tracking and active count',
        () async {
      final videoFile1 = torrent_file.File(
        name: 'clip1.mp4',
        length: 5000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 0,
        endPiece: 25,
      );

      final fakeTorrent = E2ETestFakeTorrent(
        id: 204,
        pieceCount: 50,
        pieceSize: 100000,
        files: [videoFile1],
        speedLimitDownEnabled: true,
        speedLimitDown: 750,
        engineRef: mockEngine,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: videoFile1,
      );
      expect(mockEngine.speedLimitsDown[204], equals(0));
      expect(
        MoovPriorityBooster.activeSessionsForTest.containsKey(204),
        isTrue,
      );
    });
  });

  // =========================================================================
  // F11: Archive Auto-Extract & Zip-Slip Protection
  // =========================================================================
  group('Tier 1 - F11: Archive Auto-Extract & Zip-Slip Protection', () {
    test('F11.1: Valid zip archive auto-extraction into target directory',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      // Create a test archive
      final zipFile = File(p.join(tempDir.path, 'release.zip'));
      final archive = Archive();
      final textContent = utf8.encode('Gravity Torrent Auto-Extract Payload');
      archive
          .addFile(ArchiveFile('readme.txt', textContent.length, textContent));
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion('release', zipFile.path);

      final extractedFile = File(p.join(tempDir.path, 'release', 'readme.txt'));
      expect(extractedFile.existsSync(), isTrue);
      expect(
        await extractedFile.readAsString(),
        equals('Gravity Torrent Auto-Extract Payload'),
      );
    });

    test(
        'F11.2: Path traversal zip-slip protection prevents escaping destination',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final zipFile = File(p.join(tempDir.path, 'attack.zip'));
      final archive = Archive();
      final textContent = utf8.encode('Innocent file');
      archive.addFile(
        ArchiveFile('innocent.txt', textContent.length, textContent),
      );
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion(
        '../../etc_shadow_attack',
        zipFile.path,
      );

      // Verify sanitized name does not escape tempDir
      final escapeTarget =
          Directory(p.join(tempDir.parent.path, 'etc_shadow_attack'));
      expect(escapeTarget.existsSync(), isFalse);
    });

    test('F11.3: Standalone GZip (.gz) file decompression', () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final rawData = utf8.encode('Compressed Raw GZip Stream Content');
      final gzBytes = GZipCodec().encode(rawData);
      final gzFile = File(p.join(tempDir.path, 'archive.gz'));
      await gzFile.writeAsBytes(gzBytes);

      await autoExtract.handleTorrentCompletion('archive', gzFile.path);

      final extracted = File(p.join(tempDir.path, 'archive', 'archive'));
      expect(extracted.existsSync(), isTrue);
      expect(
        await extracted.readAsString(),
        equals('Compressed Raw GZip Stream Content'),
      );
    });

    test(
        'F11.4: AutoExtractService destination folder configuration persistence',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder('/custom/extract/dir');

      expect(autoExtract.autoExtractEnabled, isTrue);
      expect(autoExtract.destinationFolder, equals('/custom/extract/dir'));
    });

    test('F11.5: Disabled auto-extract does not trigger extraction', () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(false);
      autoExtract.setDestinationFolder(tempDir.path);

      final zipFile = File(p.join(tempDir.path, 'disabled.zip'));
      final archive = Archive();
      final textContent = utf8.encode('dummy');
      archive
          .addFile(ArchiveFile('dummy.txt', textContent.length, textContent));
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion('disabled', zipFile.path);

      final targetFolder = Directory(p.join(tempDir.path, 'disabled'));
      expect(targetFolder.existsSync(), isFalse);
    });
  });
}
