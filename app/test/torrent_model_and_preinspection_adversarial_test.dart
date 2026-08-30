import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart';
import 'package:gravity_torrent/engine/transmission/transmission.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/bitfield.dart';

void main() {
  group('1. Piece Counts at Extreme Scales & Boundaries', () {
    test('pieceCount = 0 with various bitfield inputs', () {
      // 1.1 pieceCount = 0, empty pieces
      final model0 = TransmissionTorrentModel.fromJson({
        'id': 101,
        'pieceCount': 0,
        'pieces': '',
      });
      expect(model0.pieceCount, equals(0));
      expect(model0.pieces, isEmpty);

      // 1.2 pieceCount = 0, null pieces
      final model0Null = TransmissionTorrentModel.fromJson({
        'id': 102,
        'pieceCount': 0,
        'pieces': null,
      });
      expect(model0Null.pieceCount, equals(0));
      expect(model0Null.pieces, isEmpty);

      // 1.3 pieceCount = 0, but non-empty bitfield supplied (should return empty list)
      final model0WithData = TransmissionTorrentModel.fromJson({
        'id': 103,
        'pieceCount': 0,
        'pieces': base64Encode(Uint8List.fromList([0xFF, 0xFF])),
      });
      expect(model0WithData.pieceCount, equals(0));
      expect(model0WithData.pieces, isEmpty);

      // Direct bitfield utility check
      expect(convertBitfieldToBoolList(Uint8List.fromList([0xFF]), 0), isEmpty);
    });

    test('pieceCount = 1 (single piece scale)', () {
      // 1.4 pieceCount = 1, bit = 1 (MSB of byte 0: 0x80)
      final model1Loaded = TransmissionTorrentModel.fromJson({
        'id': 104,
        'pieceCount': 1,
        'pieces': base64Encode(Uint8List.fromList([0x80])),
      });
      expect(model1Loaded.pieceCount, equals(1));
      expect(model1Loaded.pieces.length, equals(1));
      expect(model1Loaded.pieces[0], isTrue);

      // 1.5 pieceCount = 1, bit = 0 (byte 0: 0x00)
      final model1Unloaded = TransmissionTorrentModel.fromJson({
        'id': 105,
        'pieceCount': 1,
        'pieces': base64Encode(Uint8List.fromList([0x00])),
      });
      expect(model1Unloaded.pieceCount, equals(1));
      expect(model1Unloaded.pieces.length, equals(1));
      expect(model1Unloaded.pieces[0], isFalse);

      // 1.6 pieceCount = 1, empty bitfield (should default to false)
      final model1Empty = TransmissionTorrentModel.fromJson({
        'id': 106,
        'pieceCount': 1,
        'pieces': '',
      });
      expect(model1Empty.pieceCount, equals(1));
      expect(model1Empty.pieces.length, equals(1));
      expect(model1Empty.pieces[0], isFalse);
    });

    test('pieceCount = 1,000,000 (1 Million exact scale)', () {
      const pieceCount = 1000000;
      const numBytes = 1000000 ~/ 8; // exactly 125,000 bytes
      expect(numBytes, equals(125000));

      final bitfieldBytes = Uint8List(numBytes);
      // Set first piece (piece 0: byte 0, bit 7)
      bitfieldBytes[0] |= 0x80;
      // Set intermediate piece (piece 500,000: byte 62,500, bit 7)
      bitfieldBytes[500000 ~/ 8] |= (1 << (7 - (500000 % 8)));
      // Set last piece (piece 999,999: byte 124,999, bit 0)
      bitfieldBytes[124999] |= 0x01;

      final model1M = TransmissionTorrentModel.fromJson({
        'id': 107,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });

      expect(model1M.pieceCount, equals(pieceCount));
      expect(model1M.pieces.length, equals(pieceCount));
      expect(model1M.pieces[0], isTrue);
      expect(model1M.pieces[1], isFalse);
      expect(model1M.pieces[500000], isTrue);
      expect(model1M.pieces[500001], isFalse);
      expect(model1M.pieces[999998], isFalse);
      expect(model1M.pieces[999999], isTrue);
    });

    test('pieceCount = 1,000,001 (1 Million + 1 boundary scale)', () {
      const pieceCount = 1000001;
      const numBytes = (pieceCount + 7) ~/ 8; // 125,001 bytes
      expect(numBytes, equals(125001));

      final bitfieldBytes = Uint8List(numBytes);
      // Set piece 0
      bitfieldBytes[0] |= 0x80;
      // Set piece 1,000,000 (byte 125,000, bit 7)
      bitfieldBytes[125000] |= 0x80;

      final model1MPlus1 = TransmissionTorrentModel.fromJson({
        'id': 108,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });

      expect(model1MPlus1.pieceCount, equals(pieceCount));
      expect(model1MPlus1.pieces.length, equals(pieceCount));
      expect(model1MPlus1.pieces[0], isTrue);
      expect(model1MPlus1.pieces[999999], isFalse);
      expect(model1MPlus1.pieces[1000000], isTrue);
    });

    test('pieceCount = 5,000,000 (Extreme 5 Million scale)', () {
      const pieceCount = 5000000;
      const numBytes = (pieceCount + 7) ~/ 8; // 625,000 bytes
      expect(numBytes, equals(625000));

      final bitfieldBytes = Uint8List(numBytes);
      // Set piece 0
      bitfieldBytes[0] |= 0x80;
      // Set piece 2,500,000 (byte 312,500, bit 7)
      bitfieldBytes[312500] |= 0x80;
      // Set piece 4,999,999 (byte 624,999, bit 0)
      bitfieldBytes[624999] |= 0x01;

      final stopwatch = Stopwatch()..start();
      final model5M = TransmissionTorrentModel.fromJson({
        'id': 109,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });
      stopwatch.stop();

      expect(model5M.pieceCount, equals(pieceCount));
      expect(model5M.pieces.length, equals(pieceCount));
      expect(model5M.pieces[0], isTrue);
      expect(model5M.pieces[1], isFalse);
      expect(model5M.pieces[2500000], isTrue);
      expect(model5M.pieces[2500001], isFalse);
      expect(model5M.pieces[4999998], isFalse);
      expect(model5M.pieces[4999999], isTrue);

      // Verify fast execution under 1000ms
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('Negative piece counts are defensively clamped to 0', () {
      const negativeCounts = [-1, -5, -100, -999999, -9223372036854775807];
      for (final neg in negativeCounts) {
        final model = TransmissionTorrentModel.fromJson({
          'id': 110,
          'pieceCount': neg,
          'pieces': base64Encode(Uint8List.fromList([0xFF, 0xFF])),
        });
        expect(
          model.pieceCount,
          equals(0),
          reason: 'pieceCount $neg should clamp to 0',
        );
        expect(
          model.pieces,
          isEmpty,
          reason: 'pieces for count $neg should be empty',
        );
      }
    });

    test('Null, missing, and non-integer pieceCount types', () {
      // Null
      final mNull =
          TransmissionTorrentModel.fromJson({'id': 111, 'pieceCount': null});
      expect(mNull.pieceCount, equals(0));
      expect(mNull.pieces, isEmpty);

      // Missing
      final mMissing = TransmissionTorrentModel.fromJson({'id': 112});
      expect(mMissing.pieceCount, equals(0));
      expect(mMissing.pieces, isEmpty);

      // Double
      final mDouble =
          TransmissionTorrentModel.fromJson({'id': 114, 'pieceCount': 50.7});
      expect(mDouble.pieceCount, equals(50));
      expect(mDouble.pieces.length, equals(50));

      // String triggers TypeError on strict cast (standard Dart JSON model pattern)
      expect(
        () => TransmissionTorrentModel.fromJson(
          {'id': 113, 'pieceCount': 'invalid'},
        ),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('2. Base64 Bitfield Decoding & Malformed Payloads', () {
    test('partial bitfields pad missing pieces with false', () {
      const pieceCount = 100;
      // Only 2 bytes (16 bits) supplied: 0xF0 (11110000), 0x0F (00001111)
      final partialBytes = Uint8List.fromList([0xF0, 0x0F]);
      final model = TransmissionTorrentModel.fromJson({
        'id': 201,
        'pieceCount': pieceCount,
        'pieces': base64Encode(partialBytes),
      });

      expect(model.pieces.length, equals(pieceCount));
      // First byte: 11110000
      expect(model.pieces.sublist(0, 4), equals([true, true, true, true]));
      expect(model.pieces.sublist(4, 8), equals([false, false, false, false]));
      // Second byte: 00001111
      expect(model.pieces.sublist(8, 12), equals([false, false, false, false]));
      expect(model.pieces.sublist(12, 16), equals([true, true, true, true]));
      // Remaining 84 pieces (indices 16..99) must all be false
      expect(model.pieces.sublist(16).every((p) => p == false), isTrue);
    });

    test('extra bits in bitfield beyond pieceCount are safely ignored', () {
      const pieceCount = 5;
      // 1 byte: 0xFF (11111111) -> 8 bits, but only 5 requested
      final model = TransmissionTorrentModel.fromJson({
        'id': 202,
        'pieceCount': pieceCount,
        'pieces': base64Encode(Uint8List.fromList([0xFF])),
      });

      expect(model.pieces.length, equals(5));
      expect(model.pieces, equals([true, true, true, true, true]));

      // 100 bytes supplied for 10 pieces
      final hugeBytes = Uint8List(100)..fillRange(0, 100, 0xFF);
      final modelHuge = TransmissionTorrentModel.fromJson({
        'id': 203,
        'pieceCount': 10,
        'pieces': base64Encode(hugeBytes),
      });
      expect(modelHuge.pieces.length, equals(10));
      expect(modelHuge.pieces.every((p) => p == true), isTrue);
    });

    test('partial last byte with unused trailing bits', () {
      const pieceCount = 11;
      // 2 bytes: byte 0 = 0xAA (10101010), byte 1 = 0xE0 (11100000 -> only top 3 bits for pieces 8, 9, 10)
      final bytes = Uint8List.fromList([0xAA, 0xE0]);
      final model = TransmissionTorrentModel.fromJson({
        'id': 204,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bytes),
      });

      expect(model.pieces.length, equals(11));
      expect(model.pieces[0], isTrue);
      expect(model.pieces[1], isFalse);
      expect(model.pieces[2], isTrue);
      expect(model.pieces[3], isFalse);
      expect(model.pieces[4], isTrue);
      expect(model.pieces[5], isFalse);
      expect(model.pieces[6], isTrue);
      expect(model.pieces[7], isFalse);
      expect(model.pieces[8], isTrue);
      expect(model.pieces[9], isTrue);
      expect(model.pieces[10], isTrue);
    });

    test('corrupted base64 bitfields fall back gracefully to all false', () {
      const pieceCount = 100;
      final malformedStrings = [
        'invalid base64!!!',
        '==', // bad padding
        'AAAA==', // invalid padding layout
        'A', // incomplete base64 quantum
        '###%%%&&&',
        '   \n\t  ',
      ];

      for (final badStr in malformedStrings) {
        final model = TransmissionTorrentModel.fromJson({
          'id': 205,
          'pieceCount': pieceCount,
          'pieces': badStr,
        });

        expect(model.pieceCount, equals(pieceCount));
        expect(model.pieces.length, equals(pieceCount));
        expect(
          model.pieces.every((p) => p == false),
          isTrue,
          reason: 'String "$badStr" should fail safely to all false',
        );
      }
    });

    test('non-string pieces JSON field falls back gracefully to all false', () {
      const pieceCount = 50;
      final nonStringValues = [
        12345,
        12.34,
        true,
        false,
        ['a', 'b'],
        {'nested': 'map'},
      ];

      for (final nonStr in nonStringValues) {
        final model = TransmissionTorrentModel.fromJson({
          'id': 206,
          'pieceCount': pieceCount,
          'pieces': nonStr,
        });

        expect(model.pieceCount, equals(pieceCount));
        expect(model.pieces.length, equals(pieceCount));
        expect(
          model.pieces.every((p) => p == false),
          isTrue,
          reason: 'Non-string value $nonStr should fail safely to all false',
        );
      }
    });
  });

  group('3. Torrent.hasLoadedPieces Boundary & Robustness Harness', () {
    test('hasLoadedPieces on empty torrent (pieceCount = 0)', () {
      final model = TransmissionTorrentModel.fromJson({
        'id': 301,
        'pieceCount': 0,
        'pieces': '',
      });
      final torrent = createTransmissionTorrentFromJson(model);

      expect(
        torrent.hasLoadedPieces([]),
        isTrue,
        reason: 'Empty query on empty torrent is vacuum true',
      );
      expect(
        torrent.hasLoadedPieces([0]),
        isFalse,
        reason: 'Index 0 is out of bounds on empty torrent',
      );
      expect(torrent.hasLoadedPieces([-1]), isFalse);
      expect(torrent.hasLoadedPieces([100]), isFalse);
    });

    test('hasLoadedPieces on single piece torrent (pieceCount = 1)', () {
      // Loaded
      final modelLoaded = TransmissionTorrentModel.fromJson({
        'id': 302,
        'pieceCount': 1,
        'pieces': base64Encode(Uint8List.fromList([0x80])),
      });
      final torrentLoaded = createTransmissionTorrentFromJson(modelLoaded);

      expect(torrentLoaded.hasLoadedPieces([]), isTrue);
      expect(torrentLoaded.hasLoadedPieces([0]), isTrue);
      expect(torrentLoaded.hasLoadedPieces([0, 0]), isTrue);
      // Boundary out-of-range checks
      expect(
        torrentLoaded.hasLoadedPieces([1]),
        isFalse,
        reason: 'Index 1 == pieceCount is out of bounds',
      );
      expect(torrentLoaded.hasLoadedPieces([2]), isFalse);
      expect(torrentLoaded.hasLoadedPieces([-1]), isFalse);
      expect(torrentLoaded.hasLoadedPieces([0, 1]), isFalse);
      expect(torrentLoaded.hasLoadedPieces([1, 0]), isFalse);

      // Unloaded
      final modelUnloaded = TransmissionTorrentModel.fromJson({
        'id': 303,
        'pieceCount': 1,
        'pieces': base64Encode(Uint8List.fromList([0x00])),
      });
      final torrentUnloaded = createTransmissionTorrentFromJson(modelUnloaded);
      expect(torrentUnloaded.hasLoadedPieces([0]), isFalse);
      expect(torrentUnloaded.hasLoadedPieces([]), isTrue);
    });

    test('hasLoadedPieces boundaries at 1,000,000 pieces', () {
      const pieceCount = 1000000;
      final bitfieldBytes = Uint8List(125000);
      // Set pieces: 0, 1, 999998, 999999
      bitfieldBytes[0] |= 0xC0; // bits 7 & 6 (pieces 0 & 1)
      bitfieldBytes[124999] |= 0x03; // bits 1 & 0 (pieces 999998 & 999999)

      final model = TransmissionTorrentModel.fromJson({
        'id': 304,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });
      final torrent = createTransmissionTorrentFromJson(model);

      // Valid loaded pieces
      expect(torrent.hasLoadedPieces([0]), isTrue);
      expect(torrent.hasLoadedPieces([1]), isTrue);
      expect(torrent.hasLoadedPieces([999998]), isTrue);
      expect(torrent.hasLoadedPieces([999999]), isTrue);
      expect(torrent.hasLoadedPieces([0, 1, 999998, 999999]), isTrue);

      // Valid unloaded pieces
      expect(torrent.hasLoadedPieces([2]), isFalse);
      expect(torrent.hasLoadedPieces([500000]), isFalse);
      expect(torrent.hasLoadedPieces([999997]), isFalse);

      // Out of bounds boundaries
      expect(
        torrent.hasLoadedPieces([1000000]),
        isFalse,
        reason: 'Index 1000000 == pieceCount',
      );
      expect(torrent.hasLoadedPieces([1000001]), isFalse);
      expect(torrent.hasLoadedPieces([1000100]), isFalse);
      expect(torrent.hasLoadedPieces([5000000]), isFalse);
      expect(torrent.hasLoadedPieces([-1]), isFalse);
      expect(torrent.hasLoadedPieces([-1000000]), isFalse);

      // Mixed loaded and out of bounds
      expect(torrent.hasLoadedPieces([0, 1000000]), isFalse);
      expect(torrent.hasLoadedPieces([0, -1]), isFalse);
      expect(torrent.hasLoadedPieces([999999, 1000000]), isFalse);
    });

    test('hasLoadedPieces boundaries at 1,000,001 pieces', () {
      const pieceCount = 1000001;
      final bitfieldBytes = Uint8List(125001);
      // Set piece 1,000,000 (byte 125,000, bit 7)
      bitfieldBytes[125000] |= 0x80;

      final model = TransmissionTorrentModel.fromJson({
        'id': 305,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });
      final torrent = createTransmissionTorrentFromJson(model);

      expect(
        torrent.hasLoadedPieces([1000000]),
        isTrue,
        reason: 'Last piece is index 1000000',
      );
      expect(
        torrent.hasLoadedPieces([1000001]),
        isFalse,
        reason: 'Index 1000001 == pieceCount',
      );
      expect(torrent.hasLoadedPieces([1000002]), isFalse);
    });

    test('hasLoadedPieces random query stress test on 5,000,000 pieces', () {
      const pieceCount = 5000000;
      final bitfieldBytes = Uint8List(625000);
      final random = Random(42);
      final Set<int> loadedIndices = {};

      // Seed 2,000 random loaded pieces across the 5M range
      for (int i = 0; i < 2000; i++) {
        final idx = random.nextInt(pieceCount);
        loadedIndices.add(idx);
        final byteIdx = idx ~/ 8;
        final bitIdx = 7 - (idx % 8);
        bitfieldBytes[byteIdx] |= (1 << bitIdx);
      }

      final model = TransmissionTorrentModel.fromJson({
        'id': 306,
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });
      final torrent = createTransmissionTorrentFromJson(model);

      // Test all verified loaded pieces individually
      for (final idx in loadedIndices) {
        expect(torrent.hasLoadedPieces([idx]), isTrue);
      }

      // Test batches of loaded pieces
      final loadedList = loadedIndices.toList();
      for (int i = 0; i < loadedList.length - 10; i += 10) {
        final batch = loadedList.sublist(i, i + 10);
        expect(torrent.hasLoadedPieces(batch), isTrue);
      }

      // Test random non-loaded and out-of-bounds indices
      for (int i = 0; i < 1000; i++) {
        final candidate = random.nextInt(pieceCount * 2);
        final isActuallyLoaded = loadedIndices.contains(candidate);
        expect(torrent.hasLoadedPieces([candidate]), equals(isActuallyLoaded));
      }
    });
  });

  group('4. Multi-File Torrents, Zero-Byte Files & Terabyte Scales', () {
    test('multi-file torrent containing zero-byte files', () {
      final torrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'Project_With_Empty_Files',
          'piece length': 16384,
          'pieces': Uint8List(20),
          'files': [
            {
              'length': 0,
              'path': ['.gitkeep'],
            },
            {
              'length': 0,
              'path': ['empty_dir', 'placeholder.touch'],
            },
            {
              'length': 5000,
              'path': ['src', 'main.dart'],
            },
            {
              'length': 0,
              'path': ['docs', 'TODO.txt'],
            },
          ],
        },
      };

      final encoded = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.name, equals('Project_With_Empty_Files'));
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.files.length, equals(4));
      expect(metadata.totalSize, equals(5000));
      expect(metadata.files[0].path, equals('.gitkeep'));
      expect(metadata.files[0].length, equals(0));
      expect(metadata.files[1].path, equals('empty_dir/placeholder.touch'));
      expect(metadata.files[1].length, equals(0));
      expect(metadata.files[2].path, equals('src/main.dart'));
      expect(metadata.files[2].length, equals(5000));
      expect(metadata.files[3].path, equals('docs/TODO.txt'));
      expect(metadata.files[3].length, equals(0));
    });

    test('multi-file torrent where all files are zero-byte', () {
      final torrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'All_Empty',
          'piece length': 16384,
          'pieces': Uint8List(20),
          'files': [
            {
              'length': 0,
              'path': ['empty1.txt'],
            },
            {
              'length': 0,
              'path': ['empty2.txt'],
            },
          ],
        },
      };

      final encoded = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.totalSize, equals(0));
      expect(metadata.files.length, equals(2));
      expect(metadata.files[0].length, equals(0));
      expect(metadata.files[1].length, equals(0));
    });

    test('multi-file torrent with 5,000 files in hierarchy', () {
      const fileCount = 5000;
      final fileList = <Map<String, dynamic>>[];
      int expectedTotalSize = 0;

      for (int i = 0; i < fileCount; i++) {
        final fileSize = (i % 10 == 0) ? 0 : (i * 100);
        expectedTotalSize += fileSize;
        fileList.add({
          'length': fileSize,
          'path': ['folder_${i ~/ 100}', 'subfolder_${i ~/ 10}', 'file_$i.dat'],
        });
      }

      final torrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'Massive_Hierarchy',
          'piece length': 65536,
          'pieces': Uint8List(20),
          'files': fileList,
        },
      };

      final encoded = Bencode.encode(torrentDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.isMultiFile, isTrue);
      expect(metadata.files.length, equals(fileCount));
      expect(metadata.totalSize, equals(expectedTotalSize));
      expect(metadata.files[0].path, equals('folder_0/subfolder_0/file_0.dat'));
      expect(
        metadata.files[4999].path,
        equals('folder_49/subfolder_499/file_4999.dat'),
      );
    });

    test('terabyte-scale single-file and multi-file torrent calculations', () {
      // 10 Terabytes = 10 * 1024^4 = 10,995,116,277,760 bytes
      const tenTB = 10995116277760;

      final singleTorrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'big_data.tar',
          'piece length': 16777216, // 16 MiB piece size
          'pieces': Uint8List(20 * (tenTB ~/ 16777216)),
          'length': tenTB,
        },
      };

      final singleEncoded = Bencode.encode(singleTorrentDict);
      final singleMeta = Bencode.decodeTorrent(singleEncoded);

      expect(singleMeta.totalSize, equals(tenTB));
      expect(singleMeta.files.first.length, equals(tenTB));

      // Multi-file 50 Terabytes = 5 * 10 TB files = 54,975,581,388,800 bytes
      const fiftyTB = 54975581388800;
      final multiTorrentDict = {
        'announce': 'http://tracker.example.com/announce',
        'info': {
          'name': 'Multi_TB_Dataset',
          'piece length': 16777216,
          'pieces': Uint8List(20),
          'files': List.generate(
            5,
            (i) => {
              'length': tenTB,
              'path': ['part_$i.raw'],
            },
          ),
        },
      };

      final multiEncoded = Bencode.encode(multiTorrentDict);
      final multiMeta = Bencode.decodeTorrent(multiEncoded);

      expect(multiMeta.totalSize, equals(fiftyTB));
      expect(multiMeta.files.length, equals(5));
      expect(multiMeta.files.every((f) => f.length == tenTB), isTrue);
    });

    test('TransmissionTorrentModel file list parsing with 2,000 files', () {
      const count = 2000;
      final rawFiles = List.generate(
        count,
        (i) => {
          'name': 'dir/sub/file_$i.bin',
          'length': i * 1024,
          'bytesCompleted': (i % 2 == 0) ? (i * 1024) : 0,
          'beginPiece': i,
          'endPiece': i + 1,
        },
      );

      final model = TransmissionTorrentModel.fromJson({
        'id': 401,
        'name': 'Large File List Torrent',
        'totalSize': 100000000,
        'files': rawFiles,
      });

      expect(model.files.length, equals(count));
      expect(model.files[0].name, equals('dir/sub/file_0.bin'));
      expect(model.files[0].length, equals(0));
      expect(model.files[0].bytesCompleted, equals(0));
      expect(model.files[1000].name, equals('dir/sub/file_1000.bin'));
      expect(model.files[1000].length, equals(1000 * 1024));
      expect(model.files[1000].bytesCompleted, equals(1000 * 1024));
      expect(model.files[1000].beginPiece, equals(1000));
      expect(model.files[1000].endPiece, equals(1001));
    });
  });

  group('5. Storage Threshold Condition Logic & Pre-Inspection Boundaries', () {
    // Exact boolean logic helper matching AddTorrentDialog
    bool checkLowStorageTrigger(int freeSpace, int predictedSize) {
      return freeSpace > 0 && predictedSize > 0 && freeSpace < predictedSize;
    }

    test('Storage threshold boundary tests (freeSpace vs predictedSize)', () {
      const predictedSize = 5000000000; // 5 GB

      // 1. freeSpace = predictedSize - 1 -> MUST TRIGGER
      expect(
        checkLowStorageTrigger(predictedSize - 1, predictedSize),
        isTrue,
        reason:
            'freeSpace strictly 1 byte less than predictedSize must trigger warning',
      );

      // 2. freeSpace = predictedSize -> MUST NOT TRIGGER (exact fit)
      expect(
        checkLowStorageTrigger(predictedSize, predictedSize),
        isFalse,
        reason:
            'freeSpace exactly equal to predictedSize should not trigger warning',
      );

      // 3. freeSpace = predictedSize + 1 -> MUST NOT TRIGGER
      expect(
        checkLowStorageTrigger(predictedSize + 1, predictedSize),
        isFalse,
        reason:
            'freeSpace 1 byte greater than predictedSize should not trigger warning',
      );

      // 4. freeSpace = 0 -> MUST NOT TRIGGER (unmeasured or permission denied)
      expect(
        checkLowStorageTrigger(0, predictedSize),
        isFalse,
        reason: 'Unmeasured freeSpace (0) must bypass gracefully',
      );

      // 5. predictedSize = 0 -> MUST NOT TRIGGER (magnet link / zero-byte torrent)
      expect(
        checkLowStorageTrigger(10000000000, 0),
        isFalse,
        reason: 'Unknown/zero predictedSize (0) must bypass gracefully',
      );

      // 6. Both 0 -> MUST NOT TRIGGER
      expect(
        checkLowStorageTrigger(0, 0),
        isFalse,
      );

      // 7. Negative freeSpace -> MUST NOT TRIGGER
      expect(
        checkLowStorageTrigger(-1, predictedSize),
        isFalse,
      );

      // 8. Negative predictedSize -> MUST NOT TRIGGER
      expect(
        checkLowStorageTrigger(10000000000, -1),
        isFalse,
      );
    });

    test('Storage threshold across multi-terabyte scales', () {
      // 50 TB torrent
      const fiftyTB = 54975581388800;
      // 2 TB free space
      const twoTB = 2199023255552;
      // 100 TB free space
      const hundredTB = 109951162777600;

      // 2 TB free < 50 TB predicted -> triggers warning
      expect(checkLowStorageTrigger(twoTB, fiftyTB), isTrue);

      // 100 TB free > 50 TB predicted -> does not trigger
      expect(checkLowStorageTrigger(hundredTB, fiftyTB), isFalse);

      // Exactly 50 TB free == 50 TB predicted -> does not trigger
      expect(checkLowStorageTrigger(fiftyTB, fiftyTB), isFalse);
      expect(checkLowStorageTrigger(fiftyTB - 1, fiftyTB), isTrue);
      expect(checkLowStorageTrigger(fiftyTB + 1, fiftyTB), isFalse);
    });
  });
}
