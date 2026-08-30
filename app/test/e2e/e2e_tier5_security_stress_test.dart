import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';

// ===========================================================================
// Mock Engine & Torrent Models for Tier 5 Security Stress
// ===========================================================================

class E2ESecurityMockEngine implements Engine {
  final List<int> pausedTorrents = [];
  final Map<int, bool> sequentialDownloads = {};
  final Map<int, int> sequentialStartPieces = {};
  final Map<int, int> downloadSpeedLimits = {};
  final Map<int, List<int>> highPriorityFiles = {};
  bool throwOnSpeedLimit = false;
  bool throwOnSequential = false;

  @override
  Future<void> pauseTorrent(int id) async {
    pausedTorrents.add(id);
  }

  @override
  Future<void> setTorrentSequentialDownload(int id, bool sequential) async {
    if (throwOnSequential) {
      throw const SocketException('Simulated engine failure on sequential mode');
    }
    sequentialDownloads[id] = sequential;
  }

  @override
  Future<void> setTorrentSpeedLimit(
    int id, {
    int? downloadLimit,
    int? uploadLimit,
  }) async {
    if (throwOnSpeedLimit) {
      throw const SocketException('Simulated engine failure on speed limit');
    }
    if (downloadLimit != null) {
      downloadSpeedLimits[id] = downloadLimit;
    }
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    return E2ESecurityFakeTorrent(
      id: id,
      pieceCount: 100,
      pieceSize: 65536,
      pieces: List<bool>.filled(100, true),
      speedLimitDownEnabled: downloadSpeedLimits.containsKey(id) && downloadSpeedLimits[id]! > 0,
      speedLimitDown: downloadSpeedLimits[id] ?? 0,
      engineRef: this,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class E2ESecurityFakeTorrent extends Torrent {
  final E2ESecurityMockEngine? engineRef;
  final List<torrent_file.File> _filesList;

  E2ESecurityFakeTorrent({
    required super.id,
    super.name = 'Security Stress Torrent',
    super.status = TorrentStatus.seeding,
    super.progress = 1.0,
    super.size = 6553600,
    super.downloadedEver = 6553600,
    super.uploadedEver = 6553600,
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
  })  : _filesList = files ??
            [
              torrent_file.File(
                name: 'video.mp4',
                length: 6553600,
                bytesCompleted: 6553600,
                wanted: true,
                beginPiece: 0,
                endPiece: 99,
              ),
            ],
        super(
          pieces: pieces ?? List<bool>.filled(pieceCount > 0 ? pieceCount : 1, true),
          files: files ??
              [
                torrent_file.File(
                  name: 'video.mp4',
                  length: 6553600,
                  bytesCompleted: 6553600,
                  wanted: true,
                  beginPiece: 0,
                  endPiece: 99,
                ),
              ],
          doneDate: doneDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        );

  @override
  List<torrent_file.File> get files => _filesList;

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
  Future<void> setSequentialDownloadFromPiece(int pieceIndex) async {
    if (engineRef != null) {
      engineRef!.sequentialStartPieces[id] = pieceIndex;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ===========================================================================
// Main Tier 5 Security Stress Test Suite
// ===========================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2ESecurityMockEngine mockEngine;
  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SharedPrefsStorage.resetForTest();
    SeedRatioService.instance.resetForTest();
    SearchService.instance.resetForTest();
    MoovPriorityBooster.resetForTest();

    mockEngine = E2ESecurityMockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;

    tempDir = await Directory.systemTemp.createTemp('gravity_e2e_tier5_stress_');
  });

  tearDown(() async {
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  // =========================================================================
  // 1. SSRF Bypass Variations & IP Resolution Resilience
  // =========================================================================
  group('Tier 5 - Area 1: SSRF Bypass Variations & IP Classification Hardening', () {
    test('1.1: IPv4-mapped IPv6 address classification & SSRF defense', () {
      final v4MappedCases = <String, AddressScope>{
        '::ffff:127.0.0.1': AddressScope.loopback,
        '::ffff:10.0.0.1': AddressScope.private,
        '::ffff:172.16.0.1': AddressScope.private,
        '::ffff:192.168.1.1': AddressScope.private,
        '::ffff:169.254.169.254': AddressScope.linkLocal,
        '::ffff:100.64.0.1': AddressScope.cgnat,
        '::ffff:0.0.0.0': AddressScope.unspecified,
        '::ffff:255.255.255.255': AddressScope.reserved,
        '::ffff:198.51.100.1': AddressScope.documentation,
        '::ffff:203.0.113.1': AddressScope.documentation,
        '::ffff:8.8.8.8': AddressScope.global,
        '::ffff:1.1.1.1': AddressScope.global,
      };

      for (final entry in v4MappedCases.entries) {
        final address = InternetAddress(entry.key);
        final scope = IpAddressScope.classify(address);
        expect(
          scope,
          entry.value,
          reason: 'IPv4-mapped IPv6 ${entry.key} must classify as ${entry.value}',
        );

        final isPublic = IpAddressScope.isPubliclyRoutable(address);
        final expectedPublic = entry.value == AddressScope.global;
        expect(
          isPublic,
          expectedPublic,
          reason: 'isPubliclyRoutable for ${entry.key} should be $expectedPublic',
        );

        final isPrivate = IpAddressScope.isPrivate(address);
        final expectedPrivate = entry.value == AddressScope.loopback ||
            entry.value == AddressScope.private ||
            entry.value == AddressScope.linkLocal ||
            entry.value == AddressScope.cgnat ||
            entry.value == AddressScope.uniqueLocal;
        expect(
          isPrivate,
          expectedPrivate,
          reason: 'isPrivate for ${entry.key} should be $expectedPrivate',
        );
      }
    });

    test('1.2: IPv4-compatible IPv6 (deprecated ::/96) treated as reserved', () {
      final compatAddresses = ['::127.0.0.1', '::10.0.0.1', '::1.1.1.1'];
      for (final ipStr in compatAddresses) {
        final address = InternetAddress(ipStr);
        final isPublic = IpAddressScope.isPubliclyRoutable(address);
        expect(
          isPublic,
          isFalse,
          reason: 'Deprecated IPv4-compatible IPv6 $ipStr must not be publicly routable',
        );
      }
    });

    test('1.3: 0.0.0.0 / 8 and Unspecified IPv4 / IPv6 literals', () {
      final unspecifiedCases = [
        '0.0.0.0',
        '0.0.0.1',
        '0.1.2.3',
        '0.255.255.255',
        '::',
      ];
      for (final ipStr in unspecifiedCases) {
        final address = InternetAddress(ipStr);
        expect(
          IpAddressScope.classify(address),
          AddressScope.unspecified,
          reason: '$ipStr must classify as AddressScope.unspecified',
        );
        expect(
          IpAddressScope.isPubliclyRoutable(address),
          isFalse,
          reason: '$ipStr must not be publicly routable',
        );
      }
    });

    test('1.4: Octal, Hex, Dword, and Shorthand IPv4 Bypass Rejection in Sync Gate', () {
      final malformedOrBypassHosts = [
        '0177.0.0.1', // Octal 127
        '012.0.0.1', // Octal 10
        '0x7f.0.0.1', // Hex 127
        '0X7F.0.0.1', // Upper Hex
        '0x0a.0.0.1', // Hex 10
        '127.1', // Shorthand 2-part
        '127.0.1', // Shorthand 3-part
        '10.1', // Shorthand 2-part
        '192.168.1', // Shorthand 3-part
        '256.0.0.1', // Byte overflow
        'localhost', // Localhost
        'sub.localhost', // Localhost sub
        'printer.local', // mDNS local
      ];

      for (final host in malformedOrBypassHosts) {
        final routable = IpAddressScope.isPubliclyRoutableHostSync(host);
        expect(
          routable,
          isFalse,
          reason: 'Host "$host" must be rejected synchronously by isPubliclyRoutableHostSync',
        );
      }
    });

    test('1.5: Special & Reserved IPv4/IPv6 ranges classification', () {
      final specialRanges = <String, AddressScope>{
        '255.255.255.255': AddressScope.reserved,
        '240.0.0.1': AddressScope.reserved,
        '192.88.99.1': AddressScope.reserved,
        '198.18.0.1': AddressScope.reserved,
        '198.19.255.254': AddressScope.reserved,
        '198.51.100.1': AddressScope.documentation,
        '203.0.113.1': AddressScope.documentation,
        '2001:db8::1': AddressScope.documentation,
        'fc00::1': AddressScope.uniqueLocal,
        'fd12:3456:789a::1': AddressScope.uniqueLocal,
        'fe80::1': AddressScope.linkLocal,
        'ff02::1': AddressScope.multicast,
        'ff05::2': AddressScope.multicast,
      };

      for (final entry in specialRanges.entries) {
        final address = InternetAddress(entry.key);
        expect(
          IpAddressScope.classify(address),
          entry.value,
          reason: '${entry.key} must classify as ${entry.value}',
        );
        expect(
          IpAddressScope.isPubliclyRoutable(address),
          isFalse,
          reason: '${entry.key} must not be publicly routable',
        );
      }
    });

    test('1.6: DNS timeout fails closed & multi-homed mixed IP validation', () async {
      // Mock resolver that hangs past the timeout duration
      Future<List<InternetAddress>> hangingResolver(String host) async {
        await Future.delayed(const Duration(milliseconds: 500));
        return [InternetAddress('8.8.8.8')];
      }

      final timeoutResult = await IpAddressScope.isPubliclyRoutableHost(
        'slow-attacker-dns.com',
        lookup: hangingResolver,
        timeout: const Duration(milliseconds: 50),
      );
      expect(
        timeoutResult,
        isFalse,
        reason: 'DNS timeout must fail closed to prevent SSRF bypass',
      );

      // Multi-homed DNS returning 1 public IP and 1 internal IP
      Future<List<InternetAddress>> mixedResolver(String host) async {
        return [
          InternetAddress('93.184.216.34'), // public
          InternetAddress('127.0.0.1'), // loopback
        ];
      }

      final mixedResult = await IpAddressScope.isPubliclyRoutableHost(
        'dual-homed-target.com',
        lookup: mixedResolver,
      );
      expect(
        mixedResult,
        isFalse,
        reason: 'Host resolving to mixed public/internal IPs must fail validation',
      );
    });

    test('1.7: Adversarial Magnet URI and HTTP Link SSRF Validation', () async {
      // Internal metadata tracker
      const metadataMagnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http://169.254.169.254/announce';
      expect(
        await IpAddressScope.isPubliclyRoutableLink(metadataMagnet),
        isFalse,
        reason: 'Magnet with cloud metadata tracker must be rejected',
      );

      // IPv6 Loopback tracker
      const v6LoopbackMagnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http://[::1]:8080/announce';
      expect(
        await IpAddressScope.isPubliclyRoutableLink(v6LoopbackMagnet),
        isFalse,
        reason: 'Magnet with IPv6 loopback tracker must be rejected',
      );

      // Disallowed scheme in magnet tracker
      const gopherMagnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=gopher://internal-service/announce';
      expect(
        await IpAddressScope.isPubliclyRoutableLink(gopherMagnet),
        isFalse,
        reason: 'Magnet with non-HTTP/UDP/WS tracker scheme must be rejected',
      );

      // Valid public tracker magnet
      Future<List<InternetAddress>> publicLookup(String host) async {
        return [InternetAddress('185.193.125.139')];
      }

      const publicMagnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http://tracker.opentrackr.org:1337/announce';
      expect(
        await IpAddressScope.isPubliclyRoutableLink(
          publicMagnet,
          lookup: publicLookup,
        ),
        isTrue,
        reason: 'Valid public magnet must pass validation',
      );
    });
  });

  // =========================================================================
  // 2. Archive Auto-Extract Path Traversal, Zip-Slip & Stream Hardening
  // =========================================================================
  group('Tier 5 - Area 2: Archive Auto-Extract Path Traversal & Zip-Slip Hardening', () {
    test('2.1: Torrent name directory traversal attack vectors sanitized', () async {
      final extractService = AutoExtractService.instance;
      extractService.setAutoExtractEnabled(true);
      extractService.setDestinationFolder(tempDir.path);

      // Create a valid zip archive file
      final zipFile = File(p.join(tempDir.path, 'valid.zip'));
      final archive = Archive();
      archive.addFile(
        ArchiveFile('content.txt', 12, utf8.encode('Safe payload')),
      );
      final zipBytes = ZipEncoder().encode(archive);
      await zipFile.writeAsBytes(zipBytes);

      final traversalNames = [
        '../../../../../../etc/passwd',
        r'..\..\..\..\windows\system32\cmd.exe',
        'sub/../../escaped_name',
        '....//....//....//sneaky_folder',
        '/var/run/absolute_target',
      ];

      for (final evilName in traversalNames) {
        await extractService.handleTorrentCompletion(evilName, zipFile.path);

        // Ensure no files were extracted outside the tempDir base
        final parentDir = tempDir.parent;
        final escapedPasswd = File(p.join(parentDir.path, 'passwd'));
        final escapedCmd = File(p.join(parentDir.path, 'cmd.exe'));
        final escapedSecret = File(p.join(parentDir.path, 'escaped_name'));

        expect(escapedPasswd.existsSync(), isFalse);
        expect(escapedCmd.existsSync(), isFalse);
        expect(escapedSecret.existsSync(), isFalse);
      }
    });

    test('2.2: Zip-slip archive entries with relative & absolute paths rejected', () async {
      final extractService = AutoExtractService.instance;
      extractService.setAutoExtractEnabled(true);
      extractService.setDestinationFolder(tempDir.path);

      final evilZipFile = File(p.join(tempDir.path, 'zip_slip.zip'));
      final archive = Archive();
      archive.addFile(
        ArchiveFile(
          '../../outside_secret.txt',
          14,
          utf8.encode('Malicious slip'),
        ),
      );
      archive.addFile(
        ArchiveFile(
          r'..\..\windows_evil.exe',
          10,
          utf8.encode('Evil binary'),
        ),
      );
      archive.addFile(
        ArchiveFile(
          '/tmp/abs_secret.txt',
          10,
          utf8.encode('Abs escape'),
        ),
      );

      final zipBytes = ZipEncoder().encode(archive);
      await evilZipFile.writeAsBytes(zipBytes);

      await extractService.handleTorrentCompletion(
        'ZipSlipTest',
        evilZipFile.path,
      );

      final parentOfTemp = tempDir.parent;
      final escapedSecret1 = File(p.join(parentOfTemp.path, 'outside_secret.txt'));
      final escapedSecret2 = File(p.join(parentOfTemp.path, 'windows_evil.exe'));

      expect(escapedSecret1.existsSync(), isFalse);
      expect(escapedSecret2.existsSync(), isFalse);
    });

    test('2.3: Standalone Gzip / Bzip2 stream decompression & corrupted stream recovery', () async {
      final extractService = AutoExtractService.instance;
      extractService.setAutoExtractEnabled(true);
      extractService.setDestinationFolder(tempDir.path);

      // 1. Valid Gzip decompression
      final rawData = utf8.encode('High-entropy payload for decompression testing 2026');
      final gzippedData = const GZipEncoder().encode(rawData);
      final gzFile = File(p.join(tempDir.path, 'sample.txt.gz'));
      await gzFile.writeAsBytes(gzippedData);

      await extractService.handleTorrentCompletion('GzRelease', gzFile.path);

      final extractedGz = File(p.join(tempDir.path, 'GzRelease', 'sample.txt'));
      expect(extractedGz.existsSync(), isTrue);
      expect(extractedGz.readAsStringSync(), 'High-entropy payload for decompression testing 2026');

      // 2. Corrupted / truncated Gzip stream error handling
      final corruptGz = File(p.join(tempDir.path, 'corrupted.txt.gz'));
      await corruptGz.writeAsBytes([0x1F, 0x8B, 0xFF, 0xFF, 0x00]); // Corrupted header

      await extractService.handleTorrentCompletion('CorruptedRelease', corruptGz.path);

      final corruptOut = File(p.join(tempDir.path, 'CorruptedRelease', 'corrupted.txt'));
      expect(
        corruptOut.existsSync(),
        isFalse,
        reason: 'Corrupted decompression output must be cleaned up on failure',
      );
    });

    test('2.4: Concurrent extraction stress across multiple archives', () async {
      final extractService = AutoExtractService.instance;
      extractService.setAutoExtractEnabled(true);
      extractService.setDestinationFolder(tempDir.path);

      final futures = <Future<void>>[];
      for (int i = 0; i < 15; i++) {
        final archive = Archive();
        archive.addFile(
          ArchiveFile('data_$i.txt', 10, utf8.encode('Payload $i')),
        );
        final zipBytes = ZipEncoder().encode(archive);
        final file = File(p.join(tempDir.path, 'archive_$i.zip'));
        file.writeAsBytesSync(zipBytes);

        futures.add(
          extractService.handleTorrentCompletion('Release_$i', file.path),
        );
      }

      await Future.wait(futures);

      for (int i = 0; i < 15; i++) {
        final extractedFile = File(p.join(tempDir.path, 'Release_$i', 'data_$i.txt'));
        expect(
          extractedFile.existsSync(),
          isTrue,
          reason: 'Release_$i must be extracted successfully under concurrency',
        );
      }
    });

    test('2.5: AutoExtract disabled and disposed safety invariant', () async {
      final extractService = AutoExtractService.instance;
      extractService.setAutoExtractEnabled(false);

      final zipFile = File(p.join(tempDir.path, 'disabled.zip'));
      final archive = Archive();
      archive.addFile(ArchiveFile('disabled.txt', 4, utf8.encode('test')));
      zipFile.writeAsBytesSync(ZipEncoder().encode(archive));

      await extractService.handleTorrentCompletion('DisabledTorrent', zipFile.path);

      final outDir = Directory(p.join(tempDir.path, 'DisabledTorrent'));
      expect(outDir.existsSync(), isFalse, reason: 'Disabled auto-extract must perform no work');
    });
  });

  // =========================================================================
  // 3. ReDoS Stress Testing & Adversarial Search Results Parsing
  // =========================================================================
  group('Tier 5 - Area 3: ReDoS Stress Testing & Search Engine Parsing Hardening', () {
    test('3.1: ReDoS attack with 500 unclosed nested HTML tags executes in < 300ms', () {
      final searchService = SearchService.instance;

      // Construct a pathological ReDoS payload with 500 unclosed cards & anchors
      final buffer = StringBuffer();
      buffer.write('<html><body><div class="main-container">');
      for (int i = 0; i < 500; i++) {
        buffer.write('<div class="card item list-entry" data-id="$i">');
        buffer.write('<a class="title detLink" href="magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12&dn=Item$i">');
        buffer.write('<span>Unclosed item title $i');
      }
      buffer.write('</div></body></html>');

      final payload = buffer.toString();
      final stopwatch = Stopwatch()..start();
      final results = searchService.parseResultsForTesting('ReDoSTest', payload);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(300),
        reason: 'Parser must resist ReDoS catastrophic backtracking and complete in < 300ms',
      );
      expect(results, isA<List<SearchResult>>());
    });

    test('3.2: Pathological 500KB alternating title and unclosed tags payload', () {
      final searchService = SearchService.instance;

      final buffer = StringBuffer();
      for (int i = 0; i < 2000; i++) {
        buffer.write('<tr><td><a href="/torrent/0123456789abcdef0123456789abcdef01234567">Release $i');
        buffer.write('<span class="seeds">100</span><span class="leeches">50</span>');
        buffer.write('<td align="right">1.5 GB</td></tr>');
      }

      final payload = buffer.toString();
      final stopwatch = Stopwatch()..start();
      final results = searchService.parseResultsForTesting('TableStress', payload);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(400));
      expect(results.length, greaterThan(0));
    });

    test('3.3: HTML entity bomb & malformed unicode sequences normalization', () {
      final searchService = SearchService.instance;

      const html = '''
        <table>
          <tr>
            <td><a class="detLink" href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567">
              Ubuntu&#32;&#999999999;&#x1F4BF;&nbsp;&amp;&lt;Linux&gt;&#x2F;&#39;ISO&#39;
            </a></td>
            <td class="green">150</td>
            <td class="red">25</td>
            <td>4.2 GB</td>
          </tr>
        </table>
      ''';

      final results = searchService.parseResultsForTesting('EntityTest', html);
      expect(results.length, 1);
      final r = results.first;
      expect(r.title, contains('Ubuntu'));
      expect(r.title, contains('Linux'));
      expect(r.seeders, 150);
      expect(r.leechers, 25);
      expect(r.size, (4.2 * 1024 * 1024 * 1024).round());
    });

    test('3.4: Mixed 500 valid and 500 corrupted search entries parsing', () {
      final searchService = SearchService.instance;

      final buffer = StringBuffer();
      buffer.write('<table>');
      for (int i = 0; i < 1000; i++) {
        if (i % 2 == 0) {
          // Valid row
          buffer.write('''
            <tr>
              <td><a class="detLink" href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Valid_$i">Valid Release $i</a></td>
              <td class="green">50</td>
              <td class="red">10</td>
              <td>500 MB</td>
            </tr>
          ''');
        } else {
          // Corrupted / malformed row without magnet
          buffer.write('<tr><td><a>Invalid junk row without magnet $i</td></tr>');
        }
      }
      buffer.write('</table>');

      final results = searchService.parseResultsForTesting('MixedTest', buffer.toString());
      expect(results.length, 500, reason: 'Parser should extract exactly the 500 valid entries');
    });

    test('3.5: Extreme units and boundary counts in size/seed parsing', () {
      final searchService = SearchService.instance;

      final testCases = [
        ('1.5 PiB', (1.5 * 1024 * 1024 * 1024 * 1024 * 1024).round()),
        ('500 TiB', 500 * 1024 * 1024 * 1024 * 1024),
        ('200 GiB', 200 * 1024 * 1024 * 1024),
        ('50 MiB', 50 * 1024 * 1024),
        ('100 KiB', 100 * 1024),
        ('1024 B', 1024),
      ];

      for (final (unitStr, expectedBytes) in testCases) {
        final html = '''
          <div class="card">
            <a class="title" href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567">SizeTest</a>
            <span>Size: $unitStr</span>
            <span class="seeds">999999</span>
            <span class="leechers">-50</span>
          </div>
        ''';
        final results = searchService.parseResultsForTesting('UnitSource', html);
        expect(results.length, 1);
        expect(results.first.size, expectedBytes);
        expect(results.first.seeders, 999999);
        expect(results.first.leechers, 0, reason: 'Negative leechers should clamp to 0');
      }
    });
  });

  // =========================================================================
  // 4. Concurrent Moov Priority Boosting & Concurrency Stress
  // =========================================================================
  group('Tier 5 - Area 4: Concurrent Moov Priority Boosting & Concurrency Stress', () {
    test('4.1: High-concurrency rapid seek burst (50 concurrent calls on same torrent)', () async {
      final torrent = E2ESecurityFakeTorrent(
        id: 501,
        speedLimitDownEnabled: true,
        speedLimitDown: 5000,
        engineRef: mockEngine,
      );

      final futures = <Future<void>>[];
      for (int i = 0; i < 50; i++) {
        futures.add(
          MoovPriorityBooster.boostForStreaming(
            torrent: torrent,
            file: torrent.files.first,
          ),
        );
      }

      await Future.wait(futures);

      // Verify speed limit was set to 0 (unlimited) during buffering
      expect(mockEngine.downloadSpeedLimits[501], 0);

      // Verify sequential download mode was enabled
      expect(mockEngine.sequentialDownloads[501], isTrue);
      expect(mockEngine.highPriorityFiles[501], [0]);
    });

    test('4.2: Multi-torrent parallel priority boosting (20 distinct torrents)', () async {
      final futures = <Future<void>>[];
      for (int id = 600; id < 620; id++) {
        final t = E2ESecurityFakeTorrent(
          id: id,
          speedLimitDownEnabled: true,
          speedLimitDown: 2000 + id,
          engineRef: mockEngine,
        );
        futures.add(
          MoovPriorityBooster.boostForStreaming(
            torrent: t,
            file: t.files.first,
          ),
        );
      }

      await Future.wait(futures);

      for (int id = 600; id < 620; id++) {
        expect(mockEngine.sequentialDownloads[id], isTrue);
        expect(mockEngine.downloadSpeedLimits[id], 0);
      }
    });

    test('4.3: Boundary piece ranges and zero/inverted piece ranges', () async {
      // Single piece video (beginPiece == 0, endPiece == 0)
      final singlePieceFile = torrent_file.File(
        name: 'single.mp4',
        length: 65536,
        bytesCompleted: 65536,
        wanted: true,
        beginPiece: 0,
        endPiece: 0,
      );
      final torrent1 = E2ESecurityFakeTorrent(
        id: 701,
        pieceCount: 1,
        files: [singlePieceFile],
        engineRef: mockEngine,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent1,
        file: singlePieceFile,
      );
      expect(mockEngine.sequentialDownloads[701], isTrue);

      // Inverted pieces (beginPiece: 50, endPiece: 10) -> early return safe
      final invertedFile = torrent_file.File(
        name: 'inverted.mp4',
        length: 65536,
        bytesCompleted: 65536,
        wanted: true,
        beginPiece: 50,
        endPiece: 10,
      );
      final torrent2 = E2ESecurityFakeTorrent(
        id: 702,
        files: [invertedFile],
        engineRef: mockEngine,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent2,
        file: invertedFile,
      );
      // Sequential download was set, but piece indexing exited safely
      expect(mockEngine.sequentialDownloads[702], isTrue);
    });

    test('4.4: User manual speed limit override preservation during buffering', () async {
      final torrent = E2ESecurityFakeTorrent(
        id: 801,
        speedLimitDownEnabled: true,
        speedLimitDown: 4000,
        engineRef: mockEngine,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent,
        file: torrent.files.first,
      );

      // Verify booster recorded session and set downloadLimit to 0
      expect(mockEngine.downloadSpeedLimits[801], 0);
    });

    test('4.5: Engine error fault injection handled safely without throwing', () async {
      mockEngine.throwOnSpeedLimit = true;
      mockEngine.throwOnSequential = true;

      final torrent = E2ESecurityFakeTorrent(
        id: 901,
        speedLimitDownEnabled: true,
        speedLimitDown: 1000,
        engineRef: mockEngine,
      );

      // Must not throw or crash
      await MoovPriorityBooster.boostForStreaming(
        torrent: torrent,
        file: torrent.files.first,
      );
    });
  });

  // =========================================================================
  // 5. Bencode Dictionary Key Ordering with Raw UTF-8 Multi-byte Comparison
  // =========================================================================
  group('Tier 5 - Area 5: Bencode Multi-Byte Key Ordering & BEP 0003 Strictness', () {
    test('5.1: Raw UTF-8 byte comparison vs Unicode code point ordering', () {
      // In UTF-8:
      // "a"   -> [0x61]
      // "z"   -> [0x7A]
      // "ä"   -> [0xC3, 0xA4]
      // "中"  -> [0xE4, 0xB8, 0xAD]
      // "😀"  -> [0xF0, 0x9F, 0x98, 0x80]
      // In BEP 0003 byte order: 'a' < 'z' < 'ä' < '中' < '😀'
      final inputMap = {
        '😀': 5,
        'ä': 3,
        'z': 2,
        '中': 4,
        'a': 1,
      };

      final encoded = Bencode.encode(inputMap);
      final decoded = Bencode.decode(encoded, strictKeyOrder: true);

      expect(decoded, isA<Map<String, dynamic>>());
      final map = decoded as Map<String, dynamic>;
      expect(map['a'], 1);
      expect(map['z'], 2);
      expect(map['ä'], 3);
      expect(map['中'], 4);
      expect(map['😀'], 5);

      // Verify the exact encoded order of key tokens in the byte stream
      final encodedStr = utf8.decode(encoded);
      final posA = encodedStr.indexOf('1:a');
      final posZ = encodedStr.indexOf('1:z');
      final posAe = encodedStr.indexOf('2:ä');
      final posChinese = encodedStr.indexOf('3:中');
      final posEmoji = encodedStr.indexOf('4:😀');

      expect(posA, lessThan(posZ));
      expect(posZ, lessThan(posAe));
      expect(posAe, lessThan(posChinese));
      expect(posChinese, lessThan(posEmoji));
    });

    test('5.2: Prefix string key ordering in Bencode dictionaries', () {
      final inputMap = {
        'tests': 4,
        'test': 1,
        'testing': 3,
        'test1': 2,
      };

      final encoded = Bencode.encode(inputMap);
      final encodedStr = utf8.decode(encoded);

      // Byte order: "test" < "test1" < "testing" < "tests"
      final posTest = encodedStr.indexOf('4:testi1e');
      final posTest1 = encodedStr.indexOf('5:test1i2e');
      final posTesting = encodedStr.indexOf('7:testingi3e');
      final posTests = encodedStr.indexOf('5:testsi4e');

      expect(posTest, lessThan(posTest1));
      expect(posTest1, lessThan(posTesting));
      expect(posTesting, lessThan(posTests));
    });

    test('5.3: UTF-8 Uint8List keys in Bencode dictionaries & non-UTF8 rejection', () {
      final utf8Key1 = Uint8List.fromList(utf8.encode('alpha'));
      final utf8Key2 = Uint8List.fromList(utf8.encode('beta'));
      final utf8Key3 = Uint8List.fromList(utf8.encode('gamma'));

      final inputMap = {
        utf8Key3: 'val3',
        utf8Key1: 'val1',
        utf8Key2: 'val2',
      };

      final encoded = Bencode.encode(inputMap);
      final decoded = Bencode.decode(encoded, strictKeyOrder: true);
      expect(decoded, isA<Map<String, dynamic>>());
      final map = decoded as Map<String, dynamic>;
      expect(utf8.decode(map['alpha'] as Uint8List), 'val1');
      expect(utf8.decode(map['beta'] as Uint8List), 'val2');
      expect(utf8.decode(map['gamma'] as Uint8List), 'val3');

      // Non-UTF8 byte string in dictionary key must be rejected by strict UTF-8 decoder
      final invalidUtf8Bytes = Uint8List.fromList([
        0x64, // 'd'
        0x32, 0x3A, 0x00, 0xFF, // '2:' followed by non-UTF8 bytes
        0x69, 0x31, 0x65, // 'i1e'
        0x65, // 'e'
      ]);
      expect(
        () => Bencode.decode(invalidUtf8Bytes),
        throwsA(isA<FormatException>()),
        reason: 'BEP 0003 dictionary keys must be valid UTF-8 strings',
      );
    });

    test('5.4: Strict vs non-strict dictionary key ordering validation', () {
      // Intentionally out of order: "z" before "a"
      const outOfOrder = 'd1:zi2e1:ai1ee';
      final bytes = Uint8List.fromList(utf8.encode(outOfOrder));

      // Strict mode must throw
      expect(
        () => Bencode.decode(bytes, strictKeyOrder: true),
        throwsA(isA<FormatException>()),
      );

      // Non-strict mode must parse successfully
      final relaxed = Bencode.decode(bytes, strictKeyOrder: false) as Map<String, dynamic>;
      expect(relaxed['z'], 2);
      expect(relaxed['a'], 1);

      // Duplicate keys must always throw even in relaxed mode
      const dupKeys = 'd1:ai1e1:ai2ee';
      expect(
        () => Bencode.decode(Uint8List.fromList(utf8.encode(dupKeys))),
        throwsA(isA<FormatException>()),
      );
    });

    test('5.5: 1,000 international multi-byte keys dictionary scale & SHA-1 roundtrip', () {
      final largeDict = <String, dynamic>{};
      for (int i = 0; i < 1000; i++) {
        final key = 'key_${i}_漢字_тест_🚀_$i';
        largeDict[key] = i;
      }

      final encoded = Bencode.encode(largeDict);
      final digest = sha1.convert(encoded);
      expect(digest.bytes.length, 20);

      final decoded = Bencode.decode(encoded, strictKeyOrder: true) as Map<String, dynamic>;
      expect(decoded.length, 1000);
      expect(decoded['key_999_漢字_тест_🚀_999'], 999);
    });
  });

  // =========================================================================
  // 6. Seed Ratio Auto-Stop Precision & Boundary Calculation Hardening
  // =========================================================================
  group('Tier 5 - Area 6: Seed Ratio Auto-Stop Precision & Boundary Calculation Hardening', () {
    test('6.1: High-precision floating point ratio boundaries', () async {
      final seedRatioService = SeedRatioService.instance;
      await seedRatioService.setGoal(101, 1.0);
      await seedRatioService.setGoal(102, 1.0);
      await seedRatioService.setGoal(103, 0.3333333333333333);

      final torrentExact = E2ESecurityFakeTorrent(
        id: 101,
        downloadedEver: 1000000,
        uploadedEver: 1000000, // Ratio = 1.0
        status: TorrentStatus.seeding,
      );

      final torrentBelow = E2ESecurityFakeTorrent(
        id: 102,
        downloadedEver: 1000000,
        uploadedEver: 999999, // Ratio = 0.999999 < 1.0
        status: TorrentStatus.seeding,
      );

      final torrentThird = E2ESecurityFakeTorrent(
        id: 103,
        downloadedEver: 3,
        uploadedEver: 1, // Ratio = 0.3333333333333333
        status: TorrentStatus.seeding,
      );

      await seedRatioService.checkAndStop([
        torrentExact,
        torrentBelow,
        torrentThird,
      ]);

      expect(mockEngine.pausedTorrents, contains(101));
      expect(mockEngine.pausedTorrents, isNot(contains(102)));
      expect(mockEngine.pausedTorrents, contains(103));
    });

    test('6.2: Division by zero & initial seeder fallback calculation', () {
      // 1. Both downloadedEver and size are zero -> 0.0
      final tZero = E2ESecurityFakeTorrent(
        id: 201,
        downloadedEver: 0,
        size: 0,
        uploadedEver: 5000,
      );
      expect(SeedRatioService.calculateRatio(tZero), 0.0);

      // 2. Initial seeder fallback: downloadedEver = 0, size = 1000, uploadedEver = 1500 -> 1.5
      final tInitialSeed = E2ESecurityFakeTorrent(
        id: 202,
        downloadedEver: 0,
        size: 1000,
        uploadedEver: 1500,
      );
      expect(SeedRatioService.calculateRatio(tInitialSeed), 1.5);
    });

    test('6.3: Negative values handling and defensive bounds', () {
      final tNegative = E2ESecurityFakeTorrent(
        id: 203,
        downloadedEver: -1000,
        size: 1000,
        uploadedEver: -500,
      );
      final ratio = SeedRatioService.calculateRatio(tNegative);
      expect(ratio, lessThanOrEqualTo(0.0));
    });

    test('6.4: Massive 64-bit integer values (int64 scale) calculation', () async {
      final seedRatioService = SeedRatioService.instance;
      await seedRatioService.setGoal(301, 2.0);

      const int64Max = 9223372036854775807;
      final tHuge = E2ESecurityFakeTorrent(
        id: 301,
        downloadedEver: 1000000000, // 1 GB
        uploadedEver: int64Max,
        status: TorrentStatus.seeding,
      );

      final ratio = SeedRatioService.calculateRatio(tHuge);
      expect(ratio, greaterThan(2.0));

      await seedRatioService.checkAndStop([tHuge]);
      expect(mockEngine.pausedTorrents, contains(301));
    });

    test('6.5: Batch evaluation with 100 torrents, ignored IDs, and non-seeding statuses', () async {
      final seedRatioService = SeedRatioService.instance;
      final torrents = <Torrent>[];
      final ignoredIds = <int>{};

      for (int i = 1; i <= 100; i++) {
        await seedRatioService.setGoal(i, 1.5);

        final TorrentStatus status;
        if (i <= 50) {
          status = TorrentStatus.seeding;
        } else if (i <= 70) {
          status = TorrentStatus.downloading;
        } else {
          status = TorrentStatus.stopped;
        }

        if (i >= 41 && i <= 50) {
          ignoredIds.add(i); // 10 torrents ignored
        }

        torrents.add(
          E2ESecurityFakeTorrent(
            id: i,
            status: status,
            downloadedEver: 1000,
            uploadedEver: 2000, // Ratio = 2.0 > 1.5 goal
          ),
        );
      }

      await seedRatioService.checkAndStop(torrents, ignoredIds);

      // Exactly torrents 1..40 should be paused (seeding, > goal, not ignored)
      expect(mockEngine.pausedTorrents.length, 40);
      for (int i = 1; i <= 40; i++) {
        expect(mockEngine.pausedTorrents, contains(i));
      }
      for (int i = 41; i <= 100; i++) {
        expect(mockEngine.pausedTorrents, isNot(contains(i)));
      }
    });
  });
}
