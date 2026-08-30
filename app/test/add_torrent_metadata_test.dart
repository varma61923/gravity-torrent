import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/utils/bencode.dart';

void main() {
  group('Add Torrent Metainfo Pre-Inspection & Disk Space Logic', () {
    test('accurately calculates predictedSize for single-file torrents', () {
      const singleFileSize = 10485760; // 10 MiB
      final dummyPieces = Uint8List(20 * 10);

      final torrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'test_file.iso',
          'piece length': 1048576, // 1 MiB
          'pieces': dummyPieces,
          'length': singleFileSize,
        },
      };

      final bytes = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(bytes);

      expect(metadata.name, equals('test_file.iso'));
      expect(metadata.totalSize, equals(singleFileSize));
      expect(metadata.isMultiFile, isFalse);
      expect(metadata.files.length, equals(1));
      expect(metadata.files.first.path, equals('test_file.iso'));
      expect(metadata.files.first.length, equals(singleFileSize));
      expect(metadata.pieceLength, equals(1048576));
      expect(metadata.pieceCount, equals(10));
    });

    test('accurately calculates predictedSize across multi-file torrent hierarchies', () {
      final dummyPieces = Uint8List(20 * 2);

      final torrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'Dataset_Archive',
          'piece length': 16384,
          'pieces': dummyPieces,
          'files': [
            {
              'length': 1000,
              'path': ['data', 'raw', 'samples.csv'],
            },
            {
              'length': 4000,
              'path': ['data', 'processed', 'results.json'],
            },
            {
              'length': 15000,
              'path': ['README.md'],
            },
          ],
        },
      };

      final bytes = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(bytes);

      expect(metadata.name, equals('Dataset_Archive'));
      expect(metadata.totalSize, equals(20000));
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.files.length, equals(3));
      expect(metadata.files[0].path, equals('data/raw/samples.csv'));
      expect(metadata.files[0].length, equals(1000));
      expect(metadata.files[1].path, equals('data/processed/results.json'));
      expect(metadata.files[1].length, equals(4000));
      expect(metadata.files[2].path, equals('README.md'));
      expect(metadata.files[2].length, equals(15000));
    });

    test('validates free space threshold condition logic', () {
      bool shouldTriggerLowStorageWarning(int freeSpace, int predictedSize) {
        return freeSpace > 0 && predictedSize > 0 && freeSpace < predictedSize;
      }

      const torrentSize = 5000000000; // 5 GB

      // Free space is strictly less than predicted size -> Should trigger
      expect(shouldTriggerLowStorageWarning(2000000000, torrentSize), isTrue); // 2 GB free < 5 GB

      // Free space is greater than predicted size -> Should not trigger
      expect(shouldTriggerLowStorageWarning(10000000000, torrentSize), isFalse); // 10 GB free > 5 GB

      // Exact boundary tests
      expect(shouldTriggerLowStorageWarning(torrentSize - 1, torrentSize), isTrue);
      expect(shouldTriggerLowStorageWarning(torrentSize, torrentSize), isFalse);
      expect(shouldTriggerLowStorageWarning(torrentSize + 1, torrentSize), isFalse);

      // Unmeasured / zero free space -> Should bypass gracefully
      expect(shouldTriggerLowStorageWarning(0, torrentSize), isFalse);
      expect(shouldTriggerLowStorageWarning(-1, torrentSize), isFalse);

      // Magnet link / unknown predicted size (predictedSize = 0) -> Should bypass gracefully
      expect(shouldTriggerLowStorageWarning(1000000, 0), isFalse);
      expect(shouldTriggerLowStorageWarning(0, 0), isFalse);
    });

    test('validates corrupt and malformed payload handling', () {
      // 1. Truncated bencode stream
      expect(
        () => Bencode.decodeTorrent(Uint8List.fromList(ascii.encode('d4:info'))),
        throwsA(isA<FormatException>()),
      );

      // 2. Missing info dictionary
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({'comment': 'No info dict here'}),
        ),
        throwsA(isA<FormatException>()),
      );

      // 3. Info is not a dictionary
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({'info': 'not-a-dictionary'}),
        ),
        throwsA(isA<FormatException>()),
      );

      // 4. Missing both length and files
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid',
              'piece length': 16384,
              'pieces': Uint8List(20),
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );

      // 5. Negative file length in files list
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'negative_len',
              'piece length': 16384,
              'pieces': Uint8List(20),
              'files': [
                {'length': -100, 'path': ['bad.txt']},
              ],
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );

      // 6. Pieces byte array length not a multiple of 20
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid_pieces',
              'piece length': 16384,
              'pieces': Uint8List(19),
              'length': 100,
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('extracts exact bit-exact 20-byte SHA-1 infoHash', () {
      final infoDict = <String, dynamic>{
        'length': 12345,
        'name': 'hash_test.bin',
        'piece length': 16384,
        'pieces': Uint8List(20),
      };

      final rootDict = <String, dynamic>{
        'announce': 'http://tracker.example.com',
        'info': infoDict,
      };

      final rawTorrentBytes = Bencode.encode(rootDict);
      final metadata = Bencode.decodeTorrent(rawTorrentBytes);

      final rawInfoBytes = Bencode.encode(infoDict);
      final expectedDigest = sha1.convert(rawInfoBytes);

      expect(metadata.infoHash, equals(Uint8List.fromList(expectedDigest.bytes)));
      expect(metadata.infoHashHex, equals(expectedDigest.toString().toLowerCase()));
      expect(metadata.infoHashHex.length, equals(40));
    });
  });
}
