import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<List<InternetAddress>> _mockLookup(String host) async {
  final clean = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  final lower = clean.toLowerCase();

  if (lower == 'example.com' || lower == 'blocklist.example.com') {
    return [InternetAddress('93.184.216.34')];
  }
  if (lower == 'custom.public-domain.org') {
    return [InternetAddress('142.250.190.46')];
  }
  if (lower == 'localtest.me' || lower == 'internal.example.com') {
    return [InternetAddress.loopbackIPv4];
  }
  if (lower == 'private.example.com') {
    return [InternetAddress('10.0.0.5')];
  }
  if (lower == 'cgnat.example.com') {
    return [InternetAddress('100.64.1.1')];
  }
  if (lower == 'ipv6-private.example.com') {
    return [InternetAddress('fc00::1')];
  }
  if (lower == 'offline-domain.com') {
    throw const SocketException('Name or service not known');
  }
  if (lower == 'stalling-server.com') {
    throw TimeoutException('DNS timeout');
  }
  throw const SocketException('Host not found');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BlocklistService.isValidBlocklistUrl', () {
    test('accepts empty URL (disabled)', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl('', lookup: _mockLookup),
        isTrue,
      );
    });

    test('accepts public HTTPS URL with mock lookup', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://example.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isTrue,
      );
    });

    test('accepts public HTTP URL with mock lookup', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://custom.public-domain.org/list.txt',
          lookup: _mockLookup,
        ),
        isTrue,
      );
    });

    test('rejects hostname resolving to loopback via DNS', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://localtest.me/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects hostname resolving to RFC 1918 private IP via DNS', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://private.example.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects hostname resolving to CGNAT IP via DNS', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://cgnat.example.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects hostname resolving to IPv6 unique-local via DNS', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://ipv6-private.example.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('accepts offline unresolvable domain (deferring to fetch time)',
        () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://offline-domain.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isTrue,
      );
    });

    test('rejects hostname on DNS TimeoutException (fail-closed SSRF gate)',
        () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'https://stalling-server.com/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects non-http schemes', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'ftp://example.com/list.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects URLs containing userInfo', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://user:pass@example.com/list.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects localhost', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://localhost/list.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects private 10.x.x.x', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://10.0.0.1/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects private 192.168.x.x', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://192.168.1.1/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects private 172.16/12 range', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://172.16.0.1/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://172.31.255.255/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('accepts public 172.x addresses outside 172.16/12', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://172.217.0.0/blocklist.txt',
          lookup: _mockLookup,
        ),
        isTrue,
      );
    });

    test('rejects 169.254 link-local range', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://169.254.1.1/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects IPv6 loopback', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://[::1]/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects IPv6 unique-local', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://[fc00::1]/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });

    test('rejects IPv6 link-local', () async {
      expect(
        await BlocklistService.isValidBlocklistUrl(
          'http://[fe80::1]/blocklist.txt',
          lookup: _mockLookup,
        ),
        isFalse,
      );
    });
  });

  group('BlocklistService State & Storage', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      BlocklistService.instance.resetForTest();
    });

    test('loads default values on fresh start', () async {
      final service = BlocklistService.instance;
      await service.load();

      expect(service.isEnabled, isFalse);
      expect(service.url, equals(BlocklistService.defaultUrl));
      expect(service.rulesCount, equals(0));
      expect(service.lastUpdated, isNull);
    });

    test('loads stored URL and enabled state from preferences', () async {
      SharedPreferences.setMockInitialValues({
        'gravity_torrent_blocklist_enabled': true,
        'gravity_torrent_blocklist_url': 'http://172.217.0.0/blocklist.txt',
        'gravity_torrent_blocklist_rules_count': '12345',
        'gravity_torrent_blocklist_last_updated': '2026-08-29T12:00:00.000Z',
      });
      SharedPrefsStorage.resetForTest();

      final service = BlocklistService.instance;
      await service.load();

      expect(service.isEnabled, isTrue);
      expect(service.url, equals('http://172.217.0.0/blocklist.txt'));
      expect(service.rulesCount, equals(12345));
      expect(service.lastUpdated, isNotNull);
    });

    test('falls back to defaultUrl when stored URL is invalid or unsafe',
        () async {
      SharedPreferences.setMockInitialValues({
        'gravity_torrent_blocklist_enabled': true,
        'gravity_torrent_blocklist_url': 'http://192.168.1.1/blocklist.txt',
      });
      SharedPrefsStorage.resetForTest();

      final service = BlocklistService.instance;
      await service.load();

      expect(service.url, equals(BlocklistService.defaultUrl));
    });

    test('setUrl persists valid URL and throws ArgumentError on unsafe URL',
        () async {
      final service = BlocklistService.instance;
      await service.load();

      await service.setUrl('http://172.217.0.0/blocklist.txt');
      expect(service.url, equals('http://172.217.0.0/blocklist.txt'));

      expect(
        () => service.setUrl('http://10.0.0.1/blocklist.txt'),
        throwsArgumentError,
      );
    });
  });
}
