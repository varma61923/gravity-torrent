import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/pin_service.dart';
import 'package:gravity_torrent/services/remote_control_service.dart';
import 'package:gravity_torrent/services/rss_episode_parser.dart';
import 'package:gravity_torrent/services/rss_service.dart';
import 'package:gravity_torrent/services/scheduler_service.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:gravity_torrent/utils/media_queue.dart';
import 'package:gravity_torrent/utils/secure_token.dart';
import 'package:gravity_torrent/utils/subtitles.dart';

void main() {
  group('Edge-case hunt', () {
    test('subtitle language does not misdetect release-group/quality tags', () {
      // When the last segment is not a language code, the title must not be
      // mistaken for one.
      expect(detectSubtitleLanguage('Movie.2020.1080p.srt'), isNull);
      expect(detectSubtitleLanguage('Movie.2020.BluRay.srt'), isNull);
      expect(detectSubtitleLanguage('Movie.Title.DVDRip.srt'), isNull);
    });

    test(
      'subtitle language still recognises real tags after quality markers',
      () {
        expect(detectSubtitleLanguage('Movie.2020.1080p.eng.srt'), 'en');
        expect(detectSubtitleLanguage('Movie.2020.BluRay.fra.srt'), 'fr');
        expect(detectSubtitleLanguage('Movie.Title.DVDRip.en.srt'), 'en');
      },
    );

    test('isPrivateIp treats IPv4-mapped loopback as private', () {
      final service = RemoteControlService.instance;
      final address = InternetAddress('::ffff:127.0.0.1');
      expect(
        service.isPrivateIp(address),
        isTrue,
        reason: 'IPv4-mapped loopback should not be bound',
      );
    });

    test(
      'isValidBlocklistUrl rejects localhost variants and private ranges',
      () async {
        expect(
          await BlocklistService.isValidBlocklistUrl(
            'http://127.0.0.1/list.txt',
          ),
          isFalse,
        );
        expect(
          await BlocklistService.isValidBlocklistUrl(
            'http://localhost./list.txt',
          ),
          isFalse,
          reason: 'localhost with trailing dot is still localhost',
        );
        expect(
          await BlocklistService.isValidBlocklistUrl(
            'http://169.254.1.1/list.txt',
          ),
          isFalse,
        );
        expect(
          await BlocklistService.isValidBlocklistUrl(
            'http://[::ffff:127.0.0.1]/list.txt',
          ),
          isFalse,
        );
      },
    );

    test('RSS isTorrentLink accepts .torrent URLs with query or fragment', () {
      expect(
        RssService.instance.isTorrentLink(
          'https://example.com/file.torrent?passkey=secret',
        ),
        isTrue,
      );
      expect(
        RssService.instance.isTorrentLink(
          'https://example.com/file.torrent#section',
        ),
        isTrue,
      );
    });

    test('pathCarriesToken rejects token in query or fragment', () {
      const token = 'abc123';
      expect(
        pathCarriesToken('/$token?other=abc123', token),
        isTrue,
        reason: 'query string after the token is allowed',
      );
      expect(
        pathCarriesToken('/$token#abc123', token),
        isTrue,
        reason: 'fragment after the token is allowed',
      );
      expect(pathCarriesToken('/other?token=$token', token), isFalse);
      expect(pathCarriesToken('/other#token=$token', token), isFalse);
    });

    test('naturalCompare ignores leading zeros across digit runs', () {
      final names = ['E007.mkv', 'E06.mkv', 'E8.mkv']..sort(naturalCompare);
      expect(names, ['E06.mkv', 'E007.mkv', 'E8.mkv']);
    });

    test('schedule wrap-midnight boundaries', () {
      const window = ScheduleWindow(
        start: ScheduleTime(hour: 23, minute: 0),
        end: ScheduleTime(hour: 7, minute: 0),
      );
      // Monday 06:00 is inside the wrap window (Sunday night -> Monday morning).
      expect(window.isActiveAt(DateTime(2024, 1, 1, 6, 0)), isTrue);
      // Monday 08:00 is outside.
      expect(window.isActiveAt(DateTime(2024, 1, 1, 8, 0)), isFalse);
      // Monday 23:30 is inside (Monday night).
      expect(window.isActiveAt(DateTime(2024, 1, 1, 23, 30)), isTrue);
    });

    test('PinLockoutException formats seconds correctly when under 1 minute', () {
      final excSeconds = PinLockoutException(const Duration(seconds: 45));
      expect(excSeconds.toString(), 'Too many failed attempts. Try again in 45 seconds.');

      final excMinutes = PinLockoutException(const Duration(minutes: 5));
      expect(excMinutes.toString(), 'Too many failed attempts. Try again in 5 minutes.');
    });

    test('RssEpisodeParser handles range like S01E01-E10 and 1x1-10 correctly', () {
      final episodes = RssEpisodeParser.parseEpisodeFilter('S01E01-E03;S02E05-E07');
      expect(episodes, ['S01E01', 'S01E02', 'S01E03', 'S02E05', 'S02E06', 'S02E07']);

      final match1 = RssEpisodeParser.matchesFilter(
        'Show.Name.S01E05.1080p',
        'S01E01-E10',
      );
      expect(match1, isTrue);

      final match2 = RssEpisodeParser.matchesFilter(
        'Show.Name.S01E15.1080p',
        'S01E01-E10',
      );
      expect(match2, isFalse);
    });

    test('TorrentCreatorService handles empty tracker tiers gracefully', () async {
      final tempDir = Directory.systemTemp.createTempSync('torrent_test_');
      try {
        final sampleFile = File('${tempDir.path}/test.bin');
        sampleFile.writeAsBytesSync(List.filled(1024, 0));

        final outPath = await TorrentCreatorService.create(
          inputPath: sampleFile.path,
          outputDirectory: tempDir.path,
          trackers: [
            [''],
            [],
          ],
        );
        expect(File(outPath).existsSync(), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('isPubliclyRoutableHost defers to fetch time on DNS timeout', () async {
      final isRoutable = await IpAddressScope.isPubliclyRoutableHost(
        'slow-dns.example.com',
        lookup: (_) => Future.delayed(
          const Duration(milliseconds: 200),
          () => throw const SocketException('offline'),
        ),
        timeout: const Duration(milliseconds: 10),
      );
      expect(isRoutable, isTrue);
    });
  });
}
