import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/session_get_request.dart';
import 'package:gravity_torrent/engine/transmission/models/session_set_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart'
    as transmission_torrent;
import 'package:gravity_torrent/engine/transmission/models/torrent_action_request.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
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
// Mock Engine for Boundary Testing
// ===========================================================================

class E2EBoundaryMockEngine implements Engine {
  final List<int> pausedIds = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> speedLimitsDown = {};
  final Map<int, List<int>> highPriorityFiles = {};

  @override
  Future<void> pauseTorrent(int id) async {
    pausedIds.add(id);
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
    return E2EBoundaryFakeTorrent(
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

class E2EBoundaryFakeTorrent extends Torrent {
  final E2EBoundaryMockEngine? engineRef;

  E2EBoundaryFakeTorrent({
    required super.id,
    super.name = 'Boundary Test Torrent',
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

  late E2EBoundaryMockEngine mockEngine;
  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();
    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();

    mockEngine = E2EBoundaryMockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;

    tempDir = await Directory.systemTemp.createTemp('gravity_e2e_tier2_');
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
  // F1: Bencode Boundaries & Malformed Streams
  // =========================================================================
  group('Tier 2 - F1: Bencode Boundaries & Malformed Streams', () {
    test('F1.B1: Leading zeros rejection in integers (i03e, i-0e, i-03e)', () {
      final invalidInts = ['i03e', 'i-0e', 'i-03e', 'i00e'];
      for (final encoded in invalidInts) {
        expect(
          () => Bencode.decode(Uint8List.fromList(utf8.encode(encoded))),
          throwsA(isA<FormatException>()),
          reason: 'Bencode should reject non-canonical integer $encoded',
        );
      }
    });

    test('F1.B2: Non-digit characters and multiple negative signs in integer',
        () {
      final invalidInts = ['i12a3e', 'i--5e', 'ie', 'i+42e', 'i 5e'];
      for (final encoded in invalidInts) {
        expect(
          () => Bencode.decode(Uint8List.fromList(utf8.encode(encoded))),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('F1.B3: Truncated streams handling across all bencode types', () {
      final truncated = [
        'i42', // Missing 'e'
        '4:spa', // Incomplete string
        'l4:spami42e', // Incomplete list
        'd3:keyi1e', // Incomplete dict
      ];
      for (final t in truncated) {
        expect(
          () => Bencode.decode(Uint8List.fromList(utf8.encode(t))),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('F1.B4: Dictionary out-of-order keys rejection in strict mode', () {
      // "zoo" precedes "app", which violates byte-order rule
      const outOfOrder = 'd3:zooi1e3:appi2ee';
      expect(
        () => Bencode.decode(
          Uint8List.fromList(utf8.encode(outOfOrder)),
          strictKeyOrder: true,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('F1.B5: Recursion nesting depth limit rejection (> 512 levels)', () {
      final builder = BytesBuilder();
      const depth = 600;
      for (int i = 0; i < depth; i++) {
        builder.addByte(0x6C); // 'l'
      }
      builder.add(utf8.encode('i1e'));
      for (int i = 0; i < depth; i++) {
        builder.addByte(0x65); // 'e'
      }

      final payload = builder.toBytes();
      expect(
        () => Bencode.decode(payload, maxDepth: 512),
        throwsA(isA<FormatException>()),
      );
    });

    test('F1.B6: Duplicate dictionary keys rejection', () {
      const dupKeys = 'd3:keyi1e3:keyi2ee';
      expect(
        () => Bencode.decode(Uint8List.fromList(utf8.encode(dupKeys))),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // =========================================================================
  // F2: Metainfo Boundary Cases
  // =========================================================================
  group('Tier 2 - F2: Metainfo Boundary Cases', () {
    test('F2.B1: Zero-length file in multi-file torrent', () {
      final pieces = Uint8List(20);
      final meta = {
        'info': {
          'name': 'Project_With_Empty_Files',
          'piece length': 16384,
          'pieces': pieces,
          'files': [
            {
              'length': 0,
              'path': ['__init__.py'],
            },
            {
              'length': 1024,
              'path': ['main.py'],
            },
          ],
        },
      };

      final decoded = Bencode.decodeTorrent(Bencode.encode(meta));
      expect(decoded.totalSize, equals(1024));
      expect(decoded.files.first.length, equals(0));
      expect(decoded.files.first.path, equals('__init__.py'));
    });

    test(
        'F2.B2: Pieces byte length not a multiple of 20 throws FormatException',
        () {
      final invalidPieces = Uint8List(25); // 25 is not a multiple of 20
      final meta = {
        'info': {
          'length': 1000,
          'name': 'invalid_pieces.dat',
          'piece length': 1000,
          'pieces': invalidPieces,
        },
      };

      expect(
        () => Bencode.decodeTorrent(Bencode.encode(meta)),
        throwsA(isA<FormatException>()),
      );
    });

    test('F2.B3: Missing or non-positive piece length throws FormatException',
        () {
      final pieces = Uint8List(20);
      final zeroPieceLength = {
        'info': {
          'length': 1000,
          'name': 'zero_piecelen.dat',
          'piece length': 0,
          'pieces': pieces,
        },
      };

      expect(
        () => Bencode.decodeTorrent(Bencode.encode(zeroPieceLength)),
        throwsA(isA<FormatException>()),
      );
    });

    test(
        'F2.B4: Missing info dict or root non-dictionary throws FormatException',
        () {
      final notADict = Bencode.encode([1, 2, 3]);
      expect(
        () => Bencode.decodeTorrent(notADict),
        throwsA(isA<FormatException>()),
      );

      final missingInfo = Bencode.encode({'announce': 'http://tracker.org'});
      expect(
        () => Bencode.decodeTorrent(missingInfo),
        throwsA(isA<FormatException>()),
      );
    });

    test('F2.B5: getPieceHash out-of-bounds index throws RangeError', () {
      final pieces = Uint8List(40); // 2 pieces
      final meta = {
        'info': {
          'length': 2000,
          'name': 'bounds.dat',
          'piece length': 1000,
          'pieces': pieces,
        },
      };

      final decoded = Bencode.decodeTorrent(Bencode.encode(meta));
      expect(() => decoded.getPieceHash(-1), throwsA(isA<RangeError>()));
      expect(() => decoded.getPieceHash(2), throwsA(isA<RangeError>()));
      expect(() => decoded.getPieceHash(100), throwsA(isA<RangeError>()));
    });
  });

  // =========================================================================
  // F3: Transmission Model & Bitfields Boundaries
  // =========================================================================
  group('Tier 2 - F3: Transmission Model & Bitfields Boundaries', () {
    test('F3.B1: Zero piece count and negative piece count bitfield conversion',
        () {
      final raw = Uint8List.fromList([0xFF]);
      expect(convertBitfieldToBoolList(raw, 0), isEmpty);
      expect(convertBitfieldToBoolList(Uint8List(0), 0), isEmpty);
    });

    test(
        'F3.B2: Bitfield with extra unused bits in last byte truncates correctly',
        () {
      // 9 pieces: 2 bytes. Byte 0 = 0xFF (8 bits true), Byte 1 = 0x80 (1 bit true, 7 unused)
      final bytes = Uint8List.fromList([0xFF, 0x80]);
      final bitfield = convertBitfieldToBoolList(bytes, 9);

      expect(bitfield.length, equals(9));
      for (int i = 0; i < 9; i++) {
        expect(bitfield[i], isTrue);
      }
    });

    test('F3.B3: Single piece boundary bitfield (pieceCount = 1)', () {
      final trueByte = Uint8List.fromList([0x80]); // bit 0 true
      final falseByte = Uint8List.fromList([0x00]); // bit 0 false

      final bitfieldTrue = convertBitfieldToBoolList(trueByte, 1);
      final bitfieldFalse = convertBitfieldToBoolList(falseByte, 1);

      expect(bitfieldTrue.length, equals(1));
      expect(bitfieldTrue[0], isTrue);
      expect(bitfieldFalse.length, equals(1));
      expect(bitfieldFalse[0], isFalse);
    });

    test(
        'F3.B4: Empty or corrupted pieces string in TransmissionTorrentModel defaults safely',
        () {
      final model = transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 50,
        'name': 'Corrupted Bitfield',
        'pieceCount': 10,
        'pieces': 'NOT_BASE64_###',
      });

      expect(model.pieces.length, equals(10));
      expect(model.pieces.every((p) => !p), isTrue);
    });

    test('F3.B5: Massive piece count scale (5,000,000 pieces)', () {
      final model = transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 51,
        'name': 'Ultra Huge Swarm',
        'pieceCount': 5000000,
        'pieces': '',
      });

      expect(model.pieceCount, equals(5000000));
    });
  });

  // =========================================================================
  // F4: Static Analysis & Type Boundary Cases
  // =========================================================================
  group('Tier 2 - F4: Static Analysis & Type Boundary Cases', () {
    test('F4.B1: TorrentActionRequest with null ids serializes safely', () {
      final actionReq = TorrentActionRequest(
        action: TorrentAction.startNow,
        arguments: TorrentActionRequestArguments(ids: null),
      );
      final json = actionReq.toJson();
      expect(json['method'], equals('torrent-start-now'));
      expect(
        (json['arguments'] as Map<String, dynamic>).containsKey('ids'),
        isFalse,
      );
    });

    test('F4.B2: SessionSetRequest boundary limits (port 65535, speed limit 0)',
        () {
      final req = SessionSetRequest(
        arguments: SessionSetRequestArguments(
          peerPort: 65535,
          speedLimitDown: 0,
          speedLimitDownEnabled: false,
        ),
      );
      final json = req.toJson();
      final args = json['arguments'] as Map<String, dynamic>;
      expect(args['peer-port'], equals(65535));
      expect(args['speed-limit-down'], equals(0));
      expect(args['speed-limit-down-enabled'], isFalse);
    });

    test(
        'F4.B3: TransmissionTorrentModel with unknown status index falls back to stopped',
        () {
      final model = transmission_torrent.TransmissionTorrentModel.fromJson({
        'id': 60,
        'status': 999, // Unknown status
      });
      expect(model.status, equals(TorrentStatus.stopped));
    });

    test('F4.B4: TransmissionTorrentFile null and missing JSON defaults safely',
        () {
      final file = transmission_torrent.TransmissionTorrentFile.fromJson({});
      expect(file.name, equals(''));
      expect(file.length, equals(0));
      expect(file.bytesCompleted, equals(0));
      expect(file.beginPiece, equals(0));
      expect(file.endPiece, equals(0));
    });

    test('F4.B5: SessionGetRequest with multiple enum fields maps correctly',
        () {
      final req = SessionGetRequest(
        arguments: SessionGetRequestArguments(
          fields: [
            SessionField.downloadDir,
            SessionField.downloadQueueEnabled,
            SessionField.downloadQueueSize,
            SessionField.uploadQueueEnabled,
            SessionField.uploadQueueSize,
            SessionField.peerPort,
            SessionField.blocklistEnabled,
          ],
        ),
      );
      final fields = (req.toJson()['arguments']
          as Map<String, dynamic>)['fields'] as List<dynamic>;
      expect(fields, contains('download-dir'));
      expect(fields, contains('download-queue-enabled'));
      expect(fields, contains('blocklist-enabled'));
    });
  });

  // =========================================================================
  // F5: Blocklist & SSRF Boundary Cases
  // =========================================================================
  group('Tier 2 - F5: Blocklist & SSRF Boundary Cases', () {
    test('F5.B1: Malformed IPv4 shorthand/hex/octal representations rejected',
        () {
      final obfuscated = [
        '0x7f.0.0.1',
        '0177.0.0.1',
        '127.1',
        '10.1',
        '192.168.1',
        '256.0.0.1',
      ];
      for (final host in obfuscated) {
        expect(
          IpAddressScope.isPubliclyRoutableHostSync(host),
          isFalse,
          reason:
              'Host $host should be rejected as non-routable / malformed IPv4',
        );
      }
    });

    test('F5.B2: Localhost variants and dot endings rejected', () {
      final localhostHosts = [
        'localhost',
        'localhost.',
        'foo.localhost',
        'sub.domain.localhost',
        'printer.local',
        'device.LOCAL.',
      ];
      for (final host in localhostHosts) {
        expect(
          IpAddressScope.isPubliclyRoutableHostSync(host),
          isFalse,
          reason: 'Host $host should not be treated as publicly routable',
        );
      }
    });

    test(
        'F5.B3: IPv6 documentation prefix 2001:db8:: classified as documentation',
        () {
      final docIp = InternetAddress('2001:db8::1');
      expect(
        IpAddressScope.classify(docIp),
        equals(AddressScope.documentation),
      );
      expect(IpAddressScope.isPubliclyRoutable(docIp), isFalse);
    });

    test('F5.B4: DNS resolution timeout fails closed in isPubliclyRoutableHost',
        () async {
      final isSafe = await IpAddressScope.isPubliclyRoutableHost(
        'slow-dns-attacker.com',
        lookup: (_) async {
          await Future.delayed(const Duration(seconds: 2));
          return [InternetAddress('8.8.8.8')];
        },
        timeout: const Duration(milliseconds: 50),
      );
      expect(isSafe, isFalse);
    });

    test('F5.B5: Empty and invalid URL schemes in BlocklistService', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(''),
        isTrue,
      ); // Empty allowed
      expect(await BlocklistService.isValidBlocklistUrl('   '), isTrue);
      expect(
        await BlocklistService.isValidBlocklistUrl('file:///etc/passwd'),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'ftp://example.com/list.txt',
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl('javascript:alert(1)'),
        isFalse,
      );
    });
  });

  // =========================================================================
  // F6: Settings & Port Validation Boundaries
  // =========================================================================
  group('Tier 2 - F6: Settings & Port Validation Boundaries', () {
    testWidgets('F6.B1: Port 0 rejection displays invalidNumber error',
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
      await tester.enterText(textField, '0');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });

    testWidgets('F6.B2: Port 65536 rejection displays invalidNumber error',
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
      await tester.enterText(textField, '65536');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });

    testWidgets(
        'F6.B3: Empty string port validation displays emptyNumber error',
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
      await tester.enterText(textField, '');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });

    testWidgets('F6.B4: Non-numeric and negative inputs rejected',
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
      await tester.enterText(textField, '-500');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      // DigitsOnly formatter prevents negative signs or validator stops save
      expect(savedPort, isNot(equals(-500)));
    });

    testWidgets('F6.B5: Massive overflow string safely rejected',
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
      await tester.enterText(textField, '99999999999999999999999999');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });
  });

  // =========================================================================
  // F7: Multi-Tracker Tiers Boundary Cases
  // =========================================================================
  group('Tier 2 - F7: Multi-Tracker Tiers Boundary Cases', () {
    test('F7.B1: Empty and whitespace-only tracker text returns empty list',
        () {
      expect(TorrentCreatorService.parseTrackerTiers(''), isEmpty);
      expect(TorrentCreatorService.parseTrackerTiers('   \n\t  \n  '), isEmpty);
    });

    test(
        'F7.B2: Multiple consecutive blank lines between tiers do not create empty tiers',
        () {
      const input = '''
http://t1.org/announce



http://t2.org/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(2));
      expect(tiers[0], equals(['http://t1.org/announce']));
      expect(tiers[1], equals(['http://t2.org/announce']));
    });

    test('F7.B3: Leading and trailing blank lines ignored cleanly', () {
      const input = '''


http://t1.org/announce


''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(1));
      expect(tiers[0], equals(['http://t1.org/announce']));
    });

    test('F7.B4: Windows CRLF (\\r\\n) line endings supported seamlessly', () {
      const input =
          'http://t1.org/announce\r\nhttp://t2.org/announce\r\n\r\nudp://t3.org/announce\r\n';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(2));
      expect(tiers[0].length, equals(2));
      expect(tiers[1].length, equals(1));
    });

    test(
        'F7.B5: Tracker lines with leading and trailing whitespace are trimmed',
        () {
      const input = '''
  http://t1.org/announce  
\t  http://t2.org/announce \t
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers.length, equals(1));
      expect(
        tiers[0],
        equals(['http://t1.org/announce', 'http://t2.org/announce']),
      );
    });
  });

  // =========================================================================
  // F8: Seed Ratio Boundary Cases
  // =========================================================================
  group('Tier 2 - F8: Seed Ratio Boundary Cases', () {
    test(
        'F8.B1: Zero downloaded and zero size ratio division by zero protection',
        () {
      final t = E2EBoundaryFakeTorrent(
        id: 70,
        downloadedEver: 0,
        uploadedEver: 1000000,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test('F8.B2: Floating point precision boundary comparison against goal',
        () async {
      await SeedRatioService.instance.setGoal(71, 2.0);

      final tUnder = E2EBoundaryFakeTorrent(
        id: 71,
        status: TorrentStatus.seeding,
        downloadedEver: 1000000,
        uploadedEver: 1999999, // ratio 1.999999 < 2.0
      );

      await SeedRatioService.instance.checkAndStop([tUnder]);
      expect(mockEngine.pausedIds, isNot(contains(71)));

      final tExact = E2EBoundaryFakeTorrent(
        id: 71,
        status: TorrentStatus.seeding,
        downloadedEver: 1000000,
        uploadedEver: 2000000, // ratio 2.0 == 2.0
      );

      await SeedRatioService.instance.checkAndStop([tExact]);
      expect(mockEngine.pausedIds, contains(71));
    });

    test('F8.B3: Massive upload value (int64 scale) ratio calculation', () {
      final t = E2EBoundaryFakeTorrent(
        id: 72,
        downloadedEver: 1000000000000,
        uploadedEver: 5000000000000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(5.0));
    });

    test(
        'F8.B4: Non-seeding torrent statuses (downloading, stopped) not auto-paused',
        () async {
      await SeedRatioService.instance.setGoal(73, 1.0);

      final tDownloading = E2EBoundaryFakeTorrent(
        id: 73,
        status: TorrentStatus.downloading,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      final tStopped = E2EBoundaryFakeTorrent(
        id: 73,
        status: TorrentStatus.stopped,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      await SeedRatioService.instance.checkAndStop([tDownloading, tStopped]);
      expect(mockEngine.pausedIds, isNot(contains(73)));
    });

    test('F8.B5: Corrupted JSON storage recovery in SeedRatioService',
        () async {
      await SharedPrefsStorage.setString(
        'gravity_torrent_seed_ratio_goals',
        'INVALID_JSON_CONTENT{{{',
      );
      // load() should not throw
      await SeedRatioService.instance.load();
      expect(SeedRatioService.instance.getGoal(1), isNull);
    });
  });

  // =========================================================================
  // F9: Search Engine Parsing Boundary Cases & ReDoS Safety
  // =========================================================================
  group('Tier 2 - F9: Search Engine Parsing Boundary Cases & ReDoS Safety', () {
    test('F9.B1: Empty or malformed HTML/XML/JSON input returns empty list',
        () {
      expect(SearchService.instance.parseResultsForTesting('Src', ''), isEmpty);
      expect(
        SearchService.instance.parseResultsForTesting('Src', '   '),
        isEmpty,
      );
      expect(
        SearchService.instance.parseResultsForTesting(
          'Src',
          '<html><body>Nothing here</body></html>',
        ),
        isEmpty,
      );
    });

    test('F9.B2: ReDoS safety on massive unclosed HTML tags executes rapidly',
        () {
      final buffer = StringBuffer();
      buffer.write('<table>');
      for (int i = 0; i < 500; i++) {
        buffer.write(
          '<tr><td><a href="magnet:?xt=urn:btih:00112233445566778899aabbccddeeff00112233',
        );
        buffer.write(' some extra text without closing quote ... ');
      }
      buffer.write('</table>');

      final stopwatch = Stopwatch()..start();
      final results = SearchService.instance
          .parseResultsForTesting('StressSrc', buffer.toString());
      stopwatch.stop();

      expect(results, isNotNull);
      expect(stopwatch.elapsedMilliseconds, lessThan(1500));
    });

    test('F9.B3: Varied size unit parsing (B, KB, MB, GB, TB, PB)', () {
      const html = '''
<table>
  <tr><td><a class="detLink" href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111">B_Test</a></td><td>512 B</td><td>10</td><td>1</td></tr>
  <tr><td><a class="detLink" href="magnet:?xt=urn:btih:2222222222222222222222222222222222222222">KB_Test</a></td><td>100 KB</td><td>10</td><td>1</td></tr>
  <tr><td><a class="detLink" href="magnet:?xt=urn:btih:3333333333333333333333333333333333333333">MB_Test</a></td><td>50.5 MB</td><td>10</td><td>1</td></tr>
  <tr><td><a class="detLink" href="magnet:?xt=urn:btih:4444444444444444444444444444444444444444">GB_Test</a></td><td>2.0 GB</td><td>10</td><td>1</td></tr>
  <tr><td><a class="detLink" href="magnet:?xt=urn:btih:5555555555555555555555555555555555555555">TB_Test</a></td><td>1.0 TB</td><td>10</td><td>1</td></tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('SizeSrc', html);
      expect(results.length, equals(5));
      expect(results[0].size, equals(512));
      expect(results[1].size, equals(100 * 1024));
      expect(results[2].size, equals((50.5 * 1024 * 1024).round()));
      expect(results[3].size, equals(2 * 1024 * 1024 * 1024));
      expect(results[4].size, equals(1024 * 1024 * 1024 * 1024));
    });

    test('F9.B4: Missing or negative seeders/leechers defaults to 0', () {
      final jsonResponse = jsonEncode([
        {
          'title': 'Zero Peer ISO',
          'magnetLink':
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          'size': 1000,
          'seeders': -5,
          'leechers': null,
        }
      ]);

      final results =
          SearchService.instance.parseResultsForTesting('Src', jsonResponse);
      expect(results.first.leechers, equals(0));
    });

    test(
        'F9.B5: URL encoded title and special characters preserved in magnet parsing',
        () {
      const html = '''
<table>
  <tr>
    <td><a class="detLink" href="magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd&dn=Special%20%5B2026%5D%20%26%20More">Special [2026] &amp; More</a></td>
    <td class="size">1 GB</td>
    <td class="seeds">50</td>
    <td class="leeches">5</td>
  </tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('SpecialSrc', html);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Special [2026] & More'));
    });
  });

  // =========================================================================
  // F10: Streaming Server & Moov Booster Boundaries
  // =========================================================================
  group('Tier 2 - F10: Streaming Server & Moov Booster Boundaries', () {
    test(
        'F10.B1: 416 Range Not Satisfiable for out-of-bounds start (bytes=15000-20000 on 10000B)',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_oob.mp4'));
      await sampleVideo.writeAsBytes(List.filled(10000, 0x01));

      final torrentFile = torrent_file.File(
        name: 'video_oob.mp4',
        length: 10000,
        bytesCompleted: 10000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2EBoundaryFakeTorrent(
        id: 301,
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
      final uri = Uri.parse('$address/video_oob.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=15000-20000');
      final response = await request.close();

      expect(
        response.statusCode,
        equals(HttpStatus.requestedRangeNotSatisfiable),
      );
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        equals('bytes */10000'),
      );
      await response.drain();

      client.close();
      await server.stop();
    });

    test(
        'F10.B2: 416 Range Not Satisfiable for inverted range (bytes=5000-4000)',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_inv.mp4'));
      await sampleVideo.writeAsBytes(List.filled(10000, 0x02));

      final torrentFile = torrent_file.File(
        name: 'video_inv.mp4',
        length: 10000,
        bytesCompleted: 10000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2EBoundaryFakeTorrent(
        id: 302,
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
      final uri = Uri.parse('$address/video_inv.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-4000');
      final response = await request.close();

      expect(
        response.statusCode,
        equals(HttpStatus.requestedRangeNotSatisfiable),
      );
      await response.drain();

      client.close();
      await server.stop();
    });

    test(
        'F10.B3: Malformed Range header (bytes=abc-def) returns 400 Bad Request',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_mal.mp4'));
      await sampleVideo.writeAsBytes(List.filled(5000, 0x03));

      final torrentFile = torrent_file.File(
        name: 'video_mal.mp4',
        length: 5000,
        bytesCompleted: 5000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2EBoundaryFakeTorrent(
        id: 303,
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
      final uri = Uri.parse('$address/video_mal.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=abc-def');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.badRequest));
      await response.drain();

      client.close();
      await server.stop();
    });

    test('F10.B4: Multi-range request rejection (bytes=0-100, 200-300)',
        () async {
      final sampleVideo = File(p.join(tempDir.path, 'video_multi.mp4'));
      await sampleVideo.writeAsBytes(List.filled(5000, 0x04));

      final torrentFile = torrent_file.File(
        name: 'video_multi.mp4',
        length: 5000,
        bytesCompleted: 5000,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );

      final fakeTorrent = E2EBoundaryFakeTorrent(
        id: 304,
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
      final uri = Uri.parse('$address/video_multi.mp4');

      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-100, 200-300');
      final response = await request.close();

      expect(response.statusCode, equals(HttpStatus.badRequest));
      await response.drain();

      client.close();
      await server.stop();
    });

    test(
        'F10.B5: MoovPriorityBooster clamped boundary pieces for startPiece < 0 and endPiece > pieceCount',
        () async {
      final outOfBoundsFile = torrent_file.File(
        name: 'clamped.mp4',
        length: 1000000,
        bytesCompleted: 0,
        wanted: true,
        beginPiece: 0,
        endPiece: 9999, // Far beyond pieceCount
      );

      final fakeTorrent = E2EBoundaryFakeTorrent(
        id: 305,
        pieceCount: 10,
        pieceSize: 100000,
        files: [outOfBoundsFile],
        engineRef: mockEngine,
      );

      // Should not throw RangeError and should clamp safely
      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: outOfBoundsFile,
      );

      expect(mockEngine.sequentialDownloads[305], isTrue);
    });
  });

  // =========================================================================
  // F11: Auto-Extract & Zip-Slip Boundaries
  // =========================================================================
  group('Tier 2 - F11: Auto-Extract & Zip-Slip Boundaries', () {
    test(
        'F11.B1: Zip-slip with deep relative paths (../../../../etc/passwd) prevented',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final zipFile = File(p.join(tempDir.path, 'deep_slip.zip'));
      final archive = Archive();
      final textContent = utf8.encode('Malicious Content');
      archive.addFile(
        ArchiveFile(
          '../../../../etc/evil_conf.conf',
          textContent.length,
          textContent,
        ),
      );
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion('deep_slip', zipFile.path);

      final escapeCheck = File('/etc/evil_conf.conf');
      expect(escapeCheck.existsSync(), isFalse);
    });

    test('F11.B2: Zip-slip with absolute paths sanitized inside destination',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final zipFile = File(p.join(tempDir.path, 'abs_slip.zip'));
      final archive = Archive();
      final textContent = utf8.encode('Root File Attempt');
      archive.addFile(
        ArchiveFile(
          '/usr/local/bin/malicious_bin',
          textContent.length,
          textContent,
        ),
      );
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion('abs_slip', zipFile.path);

      final escapeCheck = File('/usr/local/bin/malicious_bin');
      expect(escapeCheck.existsSync(), isFalse);
    });

    test(
        'F11.B3: Torrent name with directory traversal and backslashes sanitized',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final zipFile = File(p.join(tempDir.path, 'backslash.zip'));
      final archive = Archive();
      final textContent = utf8.encode('Backslash attack');
      archive.addFile(ArchiveFile('safe.txt', textContent.length, textContent));
      final zipData = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipData);

      await autoExtract.handleTorrentCompletion(
        r'..\..\windows_system32',
        zipFile.path,
      );

      final parentEscape =
          Directory(p.join(tempDir.parent.path, 'windows_system32'));
      expect(parentEscape.existsSync(), isFalse);
    });

    test(
        'F11.B4: Corrupted or truncated archive stream logs error gracefully without hanging',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(true);
      autoExtract.setDestinationFolder(tempDir.path);

      final truncatedZip = File(p.join(tempDir.path, 'truncated.zip'));
      await truncatedZip
          .writeAsBytes([0x50, 0x4B, 0x03, 0x04, 0x00]); // Partial header

      // Should complete without hanging or uncaught exceptions
      await autoExtract.handleTorrentCompletion('truncated', truncatedZip.path);
    });

    test('F11.B5: AutoExtractService operations when disabled are safe no-ops',
        () async {
      final autoExtract = AutoExtractService.instance;
      autoExtract.setAutoExtractEnabled(false);

      final zipFile = File(p.join(tempDir.path, 'noop.zip'));
      await zipFile.writeAsBytes([0x00]);

      await autoExtract.handleTorrentCompletion('noop', zipFile.path);
      expect(Directory(p.join(tempDir.path, 'noop')).existsSync(), isFalse);
    });
  });
}
