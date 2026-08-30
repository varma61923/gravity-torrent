import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:gravity_torrent/utils/bencode.dart';

void main() {
  group('BEP 12 Multi-Tracker Tier Parsing & Creation Tests', () {
    test('parses empty and whitespace strings into empty list', () {
      expect(TorrentCreatorService.parseTrackerTiers(''), isEmpty);
      expect(TorrentCreatorService.parseTrackerTiers('   '), isEmpty);
      expect(TorrentCreatorService.parseTrackerTiers('\n\n  \n\t  \n'), isEmpty);
      expect(TorrentCreatorService.parseTrackerTiers('\r\n\r\n   \r\n'), isEmpty);
    });

    test('parses single tracker on single line as 1 tier with 1 tracker', () {
      const input = 'http://tracker1.example.com/announce';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers, equals([
        ['http://tracker1.example.com/announce'],
      ]),);
    });

    test('parses consecutive lines as belonging to the SAME tier (tier 0)', () {
      const input = '''
http://tracker1.example.com/announce
http://tracker2.example.com/announce
udp://tracker3.example.com:6969/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers, equals([
        [
          'http://tracker1.example.com/announce',
          'http://tracker2.example.com/announce',
          'udp://tracker3.example.com:6969/announce',
        ],
      ]),);
    });

    test('parses blank-line separated blocks into distinct tiers per BEP 12', () {
      const input = '''
http://tier0-tracker1.example.com/announce
http://tier0-tracker2.example.com/announce

http://tier1-tracker1.example.com/announce
http://tier1-tracker2.example.com/announce
http://tier1-tracker3.example.com/announce

udp://tier2-tracker1.example.com:6969/announce
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers, equals([
        [
          'http://tier0-tracker1.example.com/announce',
          'http://tier0-tracker2.example.com/announce',
        ],
        [
          'http://tier1-tracker1.example.com/announce',
          'http://tier1-tracker2.example.com/announce',
          'http://tier1-tracker3.example.com/announce',
        ],
        [
          'udp://tier2-tracker1.example.com:6969/announce',
        ],
      ]),);
    });

    test('handles multiple consecutive blank lines and surrounding whitespace', () {
      const input = '''
   
  http://tier0-tracker1.example.com/announce   
  http://tier0-tracker2.example.com/announce   


  http://tier1-tracker1.example.com/announce   
   
   
''';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers, equals([
        [
          'http://tier0-tracker1.example.com/announce',
          'http://tier0-tracker2.example.com/announce',
        ],
        [
          'http://tier1-tracker1.example.com/announce',
        ],
      ]),);
    });

    test('handles Windows CRLF line endings correctly', () {
      const input = 'http://t1\r\nhttp://t2\r\n\r\nhttp://t3\r\n';
      final tiers = TorrentCreatorService.parseTrackerTiers(input);

      expect(tiers, equals([
        ['http://t1', 'http://t2'],
        ['http://t3'],
      ]),);
    });

    test('TorrentCreatorService.create generates BEP 12 announce and announce-list metainfo', () async {
      final tempDir = Directory.systemTemp.createTempSync('bep12_torrent_test_');
      try {
        final sampleFile = File('${tempDir.path}/payload.bin');
        sampleFile.writeAsBytesSync(List.filled(2048, 42));

        const trackerText = '''
http://primary1.tracker.org/announce
http://primary2.tracker.org/announce

http://backup1.tracker.org/announce
''';
        final parsedTiers = TorrentCreatorService.parseTrackerTiers(trackerText);
        final outPath = await TorrentCreatorService.create(
          inputPath: sampleFile.path,
          outputDirectory: tempDir.path,
          trackers: parsedTiers,
        );

        final torrentBytes = File(outPath).readAsBytesSync();
        final metadata = Bencode.decodeTorrent(torrentBytes);

        // BEP 12 backward compatibility: announce is first tracker of tier 0
        expect(metadata.announce, equals('http://primary1.tracker.org/announce'));

        // BEP 12 announce-list contains all tiers
        expect(metadata.announceList, equals([
          ['http://primary1.tracker.org/announce', 'http://primary2.tracker.org/announce'],
          ['http://backup1.tracker.org/announce'],
        ]),);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
