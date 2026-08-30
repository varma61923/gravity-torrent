import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Mock & Fake Objects for Adversarial Testing
// ---------------------------------------------------------------------------

class AdversarialMockEngine implements Engine {
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
    callLog.add('setTorrentSpeedLimit($id, dl: $downloadLimit, ul: $uploadLimit)');
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

class AdversarialFakeTorrent extends Torrent {
  final List<String> filePriorityCalls = [];
  int? sequentialFromPiece;

  AdversarialFakeTorrent({
    required super.id,
    super.name = 'Adversarial Torrent',
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

// ---------------------------------------------------------------------------
// Main Adversarial Test Suite
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // FOCUS AREA 1: Peer Port Validation Adversarial Testing
  // =========================================================================
  group('Adversarial Focus 1: Peer Port Validation', () {
    Widget buildPortWidget({
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

    testWidgets('rejects negative ports on input and falls back correctly on init',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: -65535,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      // Initial value when currentValue <= 0 defaults to 51413
      expect(find.text('51413'), findsOneWidget);

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a number'), findsOneWidget);
    });

    testWidgets('rejects alphabetic strings', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, 'abc');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
    });

    testWidgets('rejects port 0', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('rejects port 65536', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65536');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('accepts lower bound port 1', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(1));
    });

    testWidgets('accepts upper bound port 65535', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65535');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, equals(65535));
    });

    testWidgets('rejects massive overflow integers and empty string',
        (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildPortWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();
      final textField = find.byType(TextFormField);

      // 64-bit int overflow
      await tester.enterText(textField, '999999999999999999999999999999');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);

      // Empty string
      await tester.enterText(textField, '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedPort, isNull);
      expect(find.text('Please enter a number'), findsOneWidget);
    });
  });

  // =========================================================================
  // FOCUS AREA 2: BEP 12 Multi-Tracker Tiers Parsing & Creation
  // =========================================================================
  group('Adversarial Focus 2: BEP 12 Tracker Tiers', () {
    test('parses single line as 1 tier with 1 tracker', () {
      const input = 'http://tracker1.org/announce';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers, equals([['http://tracker1.org/announce']]));
    });

    test('parses consecutive lines as belonging to the same tier', () {
      const input = 'http://t1/announce\nhttp://t2/announce\nudp://t3:6969/announce';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers, equals([
        ['http://t1/announce', 'http://t2/announce', 'udp://t3:6969/announce'],
      ]),);
    });

    test('parses multiple tiers separated by blank lines', () {
      const input = 'http://tier0-1\nhttp://tier0-2\n\nhttp://tier1-1\n\nudp://tier2-1';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers, equals([
        ['http://tier0-1', 'http://tier0-2'],
        ['http://tier1-1'],
        ['udp://tier2-1'],
      ]),);
    });

    test('handles CRLF vs LF and mixed newline formats', () {
      const input = 'http://t1\r\nhttp://t2\r\n\r\nhttp://t3\nhttp://t4\r\n\nhttp://t5';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers, equals([
        ['http://t1', 'http://t2'],
        ['http://t3', 'http://t4'],
        ['http://t5'],
      ]),);
    });

    test('handles whitespace-only lines, tabs, and leading/trailing blank lines', () {
      const input = '\n\t  \r\n   \nhttp://t1\n   \t   \n\nhttp://t2\n\t\r\n';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);
      expect(tiers, equals([
        ['http://t1'],
        ['http://t2'],
      ]),);
    });

    test('returns empty list for empty or whitespace-only inputs', () {
      expect(TorrentCreatorService.parseTrackerTiers(''), isEmpty);
      expect(TorrentCreatorService.parseTrackerTiers('   \t\t\n  \r\n  '), isEmpty);
    });

    test('TorrentCreatorService.create encodes BEP 12 announce-list and backward compatible announce',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('adversarial_bep12_');
      try {
        final payload = File('${tempDir.path}/data.bin');
        payload.writeAsBytesSync(Uint8List.fromList(List.filled(1024, 99)));

        const multiline = '''
http://tier0.tracker.com/announce
http://tier0-backup.tracker.com/announce

http://tier1.tracker.com/announce
''';
        final parsed = TorrentCreatorService.parseTrackerTiers(multiline);
        final outPath = await TorrentCreatorService.create(
          inputPath: payload.path,
          outputDirectory: tempDir.path,
          trackers: parsed,
        );

        final torrentBytes = File(outPath).readAsBytesSync();
        final metadata = Bencode.decodeTorrent(torrentBytes);

        // BEP 12 backward compatible announce must equal first tracker of tier 0
        expect(metadata.announce, equals('http://tier0.tracker.com/announce'));

        // BEP 12 announce-list must contain tier arrays
        expect(metadata.announceList, equals([
          ['http://tier0.tracker.com/announce', 'http://tier0-backup.tracker.com/announce'],
          ['http://tier1.tracker.com/announce'],
        ]),);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  // =========================================================================
  // FOCUS AREA 3: Seed Ratio Calculation & Goal Enforcement
  // =========================================================================
  group('Adversarial Focus 3: Seed Ratio Service', () {
    late AdversarialMockEngine mockEngine;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      SeedRatioService.instance.resetForTest();
      mockEngine = AdversarialMockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
    });

    tearDown(() {
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test('calculateRatio: 0 size, 0 downloaded, 0 uploaded yields 0.0 safely', () {
      final t = AdversarialFakeTorrent(
        id: 1,
        downloadedEver: 0,
        uploadedEver: 0,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test('calculateRatio: 0 uploaded yields 0.0', () {
      final t = AdversarialFakeTorrent(
        id: 2,
        downloadedEver: 100000,
        uploadedEver: 0,
        size: 100000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test('calculateRatio: partial download with massive upload uses downloadedEver as denominator', () {
      final t = AdversarialFakeTorrent(
        id: 3,
        downloadedEver: 500,
        uploadedEver: 5000000,
        size: 10000000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(10000.0));
    });

    test('calculateRatio: full download uses uploadedEver / downloadedEver', () {
      final t = AdversarialFakeTorrent(
        id: 4,
        downloadedEver: 2000,
        uploadedEver: 4000,
        size: 2000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(2.0));
    });

    test('calculateRatio: initial seeder (downloadedEver == 0) falls back to size', () {
      final t = AdversarialFakeTorrent(
        id: 5,
        downloadedEver: 0,
        uploadedEver: 3000,
        size: 1000,
      );
      expect(SeedRatioService.calculateRatio(t), equals(3.0));
    });

    test('calculateRatio: initial seeder with 0 size returns 0.0 safely without divide-by-zero', () {
      final t = AdversarialFakeTorrent(
        id: 6,
        downloadedEver: 0,
        uploadedEver: 5000,
        size: 0,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test('calculateRatio: negative / corrupt integer values return 0.0 safely', () {
      final t = AdversarialFakeTorrent(
        id: 7,
        downloadedEver: -50,
        uploadedEver: 100,
        size: -200,
      );
      expect(SeedRatioService.calculateRatio(t), equals(0.0));
    });

    test('checkAndStop: pauses seeding torrent meeting or exceeding goal', () async {
      final service = SeedRatioService.instance;
      await service.setGoal(10, 1.5);

      final seedingTorrent = AdversarialFakeTorrent(
        id: 10,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 1500,
      );

      await service.checkAndStop([seedingTorrent]);
      expect(mockEngine.pausedIds, contains(10));
    });

    test('checkAndStop: does NOT pause non-seeding torrents (downloading, checking, paused)', () async {
      final service = SeedRatioService.instance;
      await service.setGoal(20, 1.0);

      final downloadingTorrent = AdversarialFakeTorrent(
        id: 20,
        status: TorrentStatus.downloading,
        downloadedEver: 1000,
        uploadedEver: 5000,
      );

      await service.checkAndStop([downloadingTorrent]);
      expect(mockEngine.pausedIds, isEmpty);
    });

    test('checkAndStop: respects ignoredIds set', () async {
      final service = SeedRatioService.instance;
      await service.setGoal(30, 1.0);

      final seedingTorrent = AdversarialFakeTorrent(
        id: 30,
        status: TorrentStatus.seeding,
        downloadedEver: 1000,
        uploadedEver: 2000,
      );

      await service.checkAndStop([seedingTorrent], {30});
      expect(mockEngine.pausedIds, isEmpty);
    });
  });

  // =========================================================================
  // FOCUS AREA 4: IP Address Classification & Blocklist SSRF Gate
  // =========================================================================
  group('Adversarial Focus 4: Blocklist & IP Address SSRF Protection', () {
    Future<List<InternetAddress>> adversarialLookup(String host) async {
      final clean = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
      final lower = clean.toLowerCase();

      if (lower == 'safe.tracker.com' || lower == 'public.org') {
        return [InternetAddress('93.184.216.34')];
      }
      if (lower == 'rebinding.attacker.com' || lower == 'ssrf.internal') {
        return [InternetAddress('127.0.0.1')];
      }
      if (lower == 'private-10.attacker.com') {
        return [InternetAddress('10.20.30.40')];
      }
      if (lower == 'ipv6-unique-local.attacker.com') {
        return [InternetAddress('fd12:3456:789a::1')];
      }
      if (lower == 'stalling.attacker.com') {
        throw TimeoutException('DNS Stall attack');
      }
      if (lower == 'unresolvable-domain.invalid') {
        throw const SocketException('Unresolvable');
      }
      throw const SocketException('Host not found');
    }

    test('IPv4 classification: private, loopback, CGNAT, multicast, reserved, documentation', () {
      // Loopback (127.0.0.0/8)
      expect(IpAddressScope.classify(InternetAddress('127.0.0.1')), equals(AddressScope.loopback));
      expect(IpAddressScope.classify(InternetAddress('127.255.255.254')), equals(AddressScope.loopback));

      // Private RFC 1918
      expect(IpAddressScope.classify(InternetAddress('10.0.0.1')), equals(AddressScope.private));
      expect(IpAddressScope.classify(InternetAddress('172.16.0.1')), equals(AddressScope.private));
      expect(IpAddressScope.classify(InternetAddress('172.31.255.255')), equals(AddressScope.private));
      expect(IpAddressScope.classify(InternetAddress('192.168.1.1')), equals(AddressScope.private));

      // Public 172.x outside 172.16/12
      expect(IpAddressScope.classify(InternetAddress('172.15.255.255')), equals(AddressScope.global));
      expect(IpAddressScope.classify(InternetAddress('172.32.0.1')), equals(AddressScope.global));

      // Link-local (169.254.0.0/16)
      expect(IpAddressScope.classify(InternetAddress('169.254.1.1')), equals(AddressScope.linkLocal));

      // CGNAT (100.64.0.0/10)
      expect(IpAddressScope.classify(InternetAddress('100.64.0.1')), equals(AddressScope.cgnat));
      expect(IpAddressScope.classify(InternetAddress('100.127.255.255')), equals(AddressScope.cgnat));

      // Multicast & Reserved
      expect(IpAddressScope.classify(InternetAddress('224.0.0.1')), equals(AddressScope.multicast));
      expect(IpAddressScope.classify(InternetAddress('240.0.0.1')), equals(AddressScope.reserved));
      expect(IpAddressScope.classify(InternetAddress('255.255.255.255')), equals(AddressScope.reserved));

      // Documentation (198.51.100.0/24, 203.0.113.0/24)
      expect(IpAddressScope.classify(InternetAddress('198.51.100.1')), equals(AddressScope.documentation));
      expect(IpAddressScope.classify(InternetAddress('203.0.113.1')), equals(AddressScope.documentation));
    });

    test('IPv6 classification: loopback, unique-local, link-local, documentation, global, IPv4-mapped', () {
      // Loopback
      expect(IpAddressScope.classify(InternetAddress('::1')), equals(AddressScope.loopback));

      // Unique-local (fc00::/7)
      expect(IpAddressScope.classify(InternetAddress('fc00::1')), equals(AddressScope.uniqueLocal));
      expect(IpAddressScope.classify(InternetAddress('fd00::1')), equals(AddressScope.uniqueLocal));

      // Link-local (fe80::/10)
      expect(IpAddressScope.classify(InternetAddress('fe80::1')), equals(AddressScope.linkLocal));

      // Multicast (ff00::/8)
      expect(IpAddressScope.classify(InternetAddress('ff02::1')), equals(AddressScope.multicast));

      // Documentation (2001:db8::/32)
      expect(IpAddressScope.classify(InternetAddress('2001:db8::1')), equals(AddressScope.documentation));

      // Global (2000::/3)
      expect(IpAddressScope.classify(InternetAddress('2001:4860:4860::8888')), equals(AddressScope.global));

      // IPv4-mapped IPv6 addresses (::ffff:10.0.0.1, ::ffff:127.0.0.1)
      expect(IpAddressScope.classify(InternetAddress('::ffff:10.0.0.1')), equals(AddressScope.private));
      expect(IpAddressScope.classify(InternetAddress('::ffff:127.0.0.1')), equals(AddressScope.loopback));
      expect(IpAddressScope.classify(InternetAddress('::ffff:8.8.8.8')), equals(AddressScope.global));
    });

    test('SSRF Protection: rejects shorthand, octal, hex IPs, DNS rebinding, and timeouts', () async {
      // Shorthand / octal / hex IPs
      expect(IpAddressScope.isPubliclyRoutableHostSync('127.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('0177.0.0.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('0x7f.0.0.1'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('localhost'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('app.localhost'), isFalse);
      expect(IpAddressScope.isPubliclyRoutableHostSync('server.local'), isFalse);

      // Async DNS resolution check with mock resolver
      expect(
        await IpAddressScope.isPubliclyRoutableHost(
          'rebinding.attacker.com',
          lookup: adversarialLookup,
        ),
        isFalse,
      );

      expect(
        await IpAddressScope.isPubliclyRoutableHost(
          'private-10.attacker.com',
          lookup: adversarialLookup,
        ),
        isFalse,
      );

      expect(
        await IpAddressScope.isPubliclyRoutableHost(
          'ipv6-unique-local.attacker.com',
          lookup: adversarialLookup,
        ),
        isFalse,
      );

      // Stalling server (DNS timeout) must fail-closed
      expect(
        await IpAddressScope.isPubliclyRoutableHost(
          'stalling.attacker.com',
          lookup: adversarialLookup,
        ),
        isFalse,
      );

      // Legitimate public domain
      expect(
        await IpAddressScope.isPubliclyRoutableHost(
          'safe.tracker.com',
          lookup: adversarialLookup,
        ),
        isTrue,
      );
    });

    test('BlocklistService URL validation rejects invalid schemes and userInfo', () async {
      expect(await BlocklistService.isValidBlocklistUrl(''), isTrue); // Empty is valid (disabled)
      expect(await BlocklistService.isValidBlocklistUrl('ftp://example.com/list.txt'), isFalse);
      expect(await BlocklistService.isValidBlocklistUrl('javascript:alert(1)'), isFalse);
      expect(await BlocklistService.isValidBlocklistUrl('http://user:pass@public.org/list.txt'), isFalse);
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://public.org/list.txt',
          lookup: adversarialLookup,
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // FOCUS AREA 5: Search Parser Adversarial Stress & ReDoS
  // =========================================================================
  group('Adversarial Focus 5: Search Parser Resilience', () {
    test('handles malformed, broken, and unclosed XML feeds without crashing', () {
      const brokenXmls = [
        '<rss><channel><item><title>Broken 1</item></channel></rss>',
        '<?xml version="1.0"?><rss><item><title>No link or magnet</title><size>1000</size></item></rss>',
        '<rss><channel><item><title>Invalid Magnet Format</title><link>magnet:invalid</link></item></channel></rss>',
        '<<<not valid xml at all>>>',
        '',
      ];

      for (final xml in brokenXmls) {
        final results = SearchService.instance.parseResultsForTesting('TestXML', xml);
        expect(results, isA<List<SearchResult>>());
      }
    });

    test('handles broken JSON and type mismatches gracefully', () {
      const brokenJsons = [
        '{"results": null}',
        '{"results": [1, 2, "three", true, null]}',
        '{"results": [{"title": 12345, "size": "NaN", "seeders": null, "info_hash": "abcdef0123456789abcdef0123456789abcdef01"}]}',
        '[{"name": {}, "size": -500, "magnet": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"}]',
        '{"invalid_json_body": [',
      ];

      for (final jsonStr in brokenJsons) {
        final results = SearchService.instance.parseResultsForTesting('TestJSON', jsonStr);
        expect(results, isA<List<SearchResult>>());
      }
    });

    test('parses 40-char info_hash in JSON, XML Torznab, and HTML table without magnet', () {
      // 1. JSON info_hash
      const jsonStr = '''
[
  {
    "title": "JSON Hash Torrent",
    "info_hash": "1111111111111111111111111111111111111111",
    "size": 5000000,
    "seeders": 10
  }
]
''';
      final jsonResults = SearchService.instance.parseResultsForTesting('API', jsonStr);
      expect(jsonResults.length, equals(1));
      expect(jsonResults.first.magnetLink, contains('1111111111111111111111111111111111111111'));
      expect(jsonResults.first.title, equals('JSON Hash Torrent'));

      // 2. Torznab XML infohash attribute
      const xmlStr = '''
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <item>
      <title>Torznab Hash Torrent</title>
      <torznab:attr name="infohash" value="2222222222222222222222222222222222222222" />
      <size>1000000</size>
    </item>
  </channel>
</rss>
''';
      final xmlResults = SearchService.instance.parseResultsForTesting('Torznab', xmlStr);
      expect(xmlResults.length, equals(1));
      expect(xmlResults.first.magnetLink, contains('2222222222222222222222222222222222222222'));

      // 3. HTML table row with hex hash in link
      const htmlTable = '''
<table>
  <tr>
    <td><a class="detLink" href="/torrent/3333333333333333333333333333333333333333">HTML Hash Torrent</a></td>
    <td>1.5 GB</td>
    <td><span class="seeds">50</span></td>
  </tr>
</table>
''';
      final htmlResults = SearchService.instance.parseResultsForTesting('HTML', htmlTable);
      expect(htmlResults.length, equals(1));
      expect(htmlResults.first.magnetLink, contains('3333333333333333333333333333333333333333'));
      expect(htmlResults.first.title, equals('HTML Hash Torrent'));
    });

    test('decodes all named, decimal, and hex HTML entities in titles', () {
      const html = '''
<table>
  <tr>
    <td><a class="detLink">&quot;Alpha &amp; Beta&quot; &#60;Test&#62; &#39;Single&#39; &#x41;&#x42;&#x43;</a></td>
    <td><a href="magnet:?xt=urn:btih:4444444444444444444444444444444444444444">DL</a></td>
    <td>500 MB</td>
  </tr>
</table>
''';
      final results = SearchService.instance.parseResultsForTesting('EntityTest', html);
      expect(results.length, equals(1));
      expect(results.first.title, equals('"Alpha & Beta" <Test> \'Single\' ABC'));
    });

    test('ReDoS & HTML Bomb stress testing: completes in linear time (< 500ms)', () {
      // 2000 nested spans and repetitive patterns
      final nestedBomb = '<table><tr><td><a class="detLink" href="#">Bomb Target</a>${'<span><span>nested</span></span>' * 2000}</td>'
          '<td><a href="magnet:?xt=urn:btih:5555555555555555555555555555555555555555&dn=Bomb+Target">Download</a></td>'
          '<td>100 MB</td></tr></table>';

      final sw = Stopwatch()..start();
      final results = SearchService.instance.parseResultsForTesting('ReDoSBomb', nestedBomb);
      sw.stop();

      expect(results.length, equals(1));
      expect(results.first.title, equals('Bomb Target'));
      expect(sw.elapsedMilliseconds, lessThan(500));
    });
  });

  // =========================================================================
  // FOCUS AREA 6: Moov Priority Booster Concurrency & Boundary Tests
  // =========================================================================
  group('Adversarial Focus 6: Moov Priority Booster', () {
    late AdversarialMockEngine mockEngine;

    setUp(() {
      mockEngine = AdversarialMockEngine();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
      getIt.registerSingleton<Engine>(mockEngine);
      app_main.engine = mockEngine;
      MoovPriorityBooster.resetForTest();
    });

    tearDown(() {
      MoovPriorityBooster.resetForTest();
      if (getIt.isRegistered<Engine>()) getIt.unregister<Engine>();
    });

    test('handles 0 piece count and 0 piece size gracefully without crashes', () async {
      final zeroTorrent = AdversarialFakeTorrent(
        id: 100,
        pieceCount: 0,
        pieceSize: 0,
        files: [
          torrent_file.File(
            name: 'zero.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 0,
            endPiece: 0,
          ),
        ],
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: zeroTorrent,
        file: zeroTorrent.files.first,
      );

      expect(mockEngine.callLog, contains('setTorrentSequentialDownload(100, true)'));
    });

    test('validates boundary clamping when beginPiece or endPiece exceed bounds', () async {
      final outOfBoundsTorrent = AdversarialFakeTorrent(
        id: 101,
        pieceCount: 20,
        pieceSize: 16384,
        files: [
          torrent_file.File(
            name: 'clamped.mp4',
            length: 327680,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 5,
            endPiece: 50, // exceeds pieceCount
          ),
        ],
      );

      mockEngine.onFetchTorrent = (id) => outOfBoundsTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: outOfBoundsTorrent,
        file: outOfBoundsTorrent.files.first,
      );

      expect(outOfBoundsTorrent.sequentialFromPiece, equals(5));
      expect(outOfBoundsTorrent.filePriorityCalls, equals(['high: [0]']));
    });

    test('concurrent boost tasks on different files of same torrent maintain ref count', () async {
      final multiFileTorrent = AdversarialFakeTorrent(
        id: 102,
        pieceCount: 50,
        pieceSize: 16384,
        pieces: List.filled(50, true), // all loaded immediately
        files: [
          torrent_file.File(
            name: 'file1.mp4',
            length: 163840,
            bytesCompleted: 163840,
            wanted: true,
            beginPiece: 0,
            endPiece: 10,
          ),
          torrent_file.File(
            name: 'file2.mp4',
            length: 163840,
            bytesCompleted: 163840,
            wanted: true,
            beginPiece: 11,
            endPiece: 20,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 500,
      );

      final liveTorrent = AdversarialFakeTorrent(
        id: 102,
        pieceCount: 50,
        pieceSize: 16384,
        pieces: List.filled(50, true),
        files: multiFileTorrent.files,
        speedLimitDownEnabled: false,
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => liveTorrent;

      // Launch two concurrent boosts
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

      // Speed limit disabled during active streaming buffering
      expect(
        mockEngine.callLog.where((c) => c.contains('setTorrentSpeedLimit(102, dl: 0')),
        isNotEmpty,
      );

      // Speed limit restored once when both complete
      expect(
        mockEngine.callLog.where((c) => c.contains('setTorrentSpeedLimit(102, dl: 500')),
        hasLength(1),
      );
    });

    test('user changing speed limits while buffering is preserved and NOT clobbered', () async {
      final torrent = AdversarialFakeTorrent(
        id: 103,
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: [
          torrent_file.File(
            name: 'user_mod.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 0,
            endPiece: 19,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 1000,
      );

      // While buffering, user explicitly modified the download limit to 200 (enabled = true)
      final userModifiedLiveTorrent = AdversarialFakeTorrent(
        id: 103,
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: torrent.files,
        speedLimitDownEnabled: true, // re-enabled by user!
        speedLimitDown: 200,
      );

      mockEngine.onFetchTorrent = (id) => userModifiedLiveTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent,
        file: torrent.files.first,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Must NOT overwrite user setting with stale 1000
      expect(
        mockEngine.callLog.where((c) => c.contains('setTorrentSpeedLimit(103, dl: 1000')),
        isEmpty,
      );
    });
  });
}

