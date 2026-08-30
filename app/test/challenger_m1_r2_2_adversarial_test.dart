import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:gravity_torrent/utils/bitfield.dart';

void main() {
  group('Target 1 — Bencode Codec Adversarial Battery', () {
    group('1.1 Integer Decoding Attacks', () {
      test('64-bit boundaries and canonical values decode correctly', () {
        const minInt = -9223372036854775808;
        const maxInt = 9223372036854775807;

        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i0e'))),
          equals(0),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i1e'))),
          equals(1),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i-1e'))),
          equals(-1),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i42e'))),
          equals(42),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i-42e'))),
          equals(-42),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i${maxInt}e'))),
          equals(maxInt),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('i${minInt}e'))),
          equals(minInt),
        );
      });

      test('rejects integer overflows beyond 64-bit signed range', () {
        final overflowCases = [
          'i9223372036854775808e',
          'i-9223372036854775809e',
          'i18446744073709551615e',
          'i9999999999999999999999999999999999999999999e',
          'i-9999999999999999999999999999999999999999999e',
        ];
        for (final payload in overflowCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Integer overflow payload "$payload" must throw FormatException',
          );
        }
      });

      test('rejects leading zeros and negative zero per BEP 0003', () {
        final leadingZeroCases = [
          'i-0e',
          'i00e',
          'i01e',
          'i007e',
          'i00000000000000000000e',
          'i-01e',
          'i-00e',
          'i-007e',
        ];
        for (final payload in leadingZeroCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason: 'Leading zero payload "$payload" must throw FormatException',
          );
        }
      });

      test('rejects positive sign prefix per BEP 0003', () {
        final signCases = ['i+0e', 'i+1e', 'i+42e', 'i+999999e'];
        for (final payload in signCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Explicit positive sign payload "$payload" must throw FormatException',
          );
        }
      });

      test('rejects malformed, empty, or sign-only integers', () {
        final malformedCases = [
          'ie',
          'i-e',
          'i+e',
          'i--1e',
          'i++1e',
          'i+-1e',
          'i-+1e',
          'i-0-1e',
          'i1-2e',
        ];
        for (final payload in malformedCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Malformed sign/empty payload "$payload" must throw FormatException',
          );
        }
      });

      test(
        'rejects whitespace, non-ASCII digits, and non-digit characters in integers',
        () {
          final invalidCharCases = [
            'i 1e',
            'i1 e',
            'i 100 e',
            'i\t5e',
            'i5\te',
            'i\n-2e',
            'i-2\ne',
            'i\r42e',
            'i42\re',
            'i\x001e',
            'i1\x00e',
            'i\x0b5e',
            'i\x0c5e',
            'i1.0e',
            'i3.14159e',
            'i0x10e',
            'i0b101e',
            'i1a2e',
            'iNaNe',
            'iInfe',
            'i\u0660e', // Arabic digit
            'i\uFF10e', // Fullwidth digit
          ];
          for (final payload in invalidCharCases) {
            expect(
              () => Bencode.decode(Uint8List.fromList(utf8.encode(payload))),
              throwsA(isA<FormatException>()),
              reason:
                  'Invalid char payload "$payload" must throw FormatException',
            );
          }
        },
      );

      test('rejects unterminated integers', () {
        final unterminatedCases = [
          'i',
          'i0',
          'i123',
          'i-42',
          'i9223372036854775807',
        ];
        for (final payload in unterminatedCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Unterminated integer payload "$payload" must throw FormatException',
          );
        }
      });
    });

    group('1.2 Byte String Decoding Attacks', () {
      test('decodes valid strings and binary byte arrays', () {
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('0:'))),
          equals(Uint8List(0)),
        );
        expect(
          utf8.decode(
            Bencode.decode(Uint8List.fromList(ascii.encode('4:spam')))
                as Uint8List,
          ),
          equals('spam'),
        );

        final rawBytes = Uint8List.fromList([
          0x00,
          0xFF,
          0xFE,
          0x42,
          0x00,
          0x7F,
        ]);
        final encoded = Bencode.encode(rawBytes);
        final decoded = Bencode.decode(encoded);
        expect(decoded, equals(rawBytes));
      });

      test('rejects negative lengths, leading zeros, and missing colons', () {
        final invalidLengthCases = [
          '-1:abc',
          '-0:abc',
          '00:',
          '01:a',
          '007:abcdefg',
          '5hello',
          '0',
          '10',
        ];
        for (final payload in invalidLengthCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Invalid length payload "$payload" must throw FormatException',
          );
        }
      });

      test('rejects whitespace, floats, and non-digits in string length', () {
        final invalidLenChars = [
          ' 5:hello',
          '5 :hello',
          '\t5:hello',
          '5\t:hello',
          '\n5:hello',
          '5.0:hello',
          '5a:hello',
          '+5:hello',
          ':hello',
        ];
        for (final payload in invalidLenChars) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Invalid length char payload "$payload" must throw FormatException',
          );
        }
      });

      test('rejects truncated byte strings (premature EOF)', () {
        final truncatedCases = ['10:abc', '5:four', '1:', '1000:small'];
        for (final payload in truncatedCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Truncated string payload "$payload" must throw FormatException',
          );
        }
      });

      test(
        'safe handling of 64-bit integer overflow in string length (no RangeError or crash)',
        () {
          final hugeLengthCases = [
            '9223372036854775807:abc',
            '9223372036854775800:abc',
            '9223372036854775806:test',
            '9223372036854775808:abc',
            '18446744073709551615:abc',
            '999999999999999999999999999999:abc',
          ];
          for (final payload in hugeLengthCases) {
            expect(
              () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
              throwsA(isA<FormatException>()),
              reason:
                  'Huge string length payload "$payload" must throw FormatException safely',
            );
          }
        },
      );
    });

    group('1.3 List & Nesting Attacks', () {
      test('decodes empty, nested, and heterogeneous lists', () {
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('le'))),
          equals(<dynamic>[]),
        );
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('lli1eeleli2eee'))),
          equals([
            [1],
            <dynamic>[],
            [2],
          ]),
        );

        final list =
            Bencode.decode(Uint8List.fromList(ascii.encode('l4:spami42ee')))
                as List<dynamic>;
        expect(list.length, equals(2));
        expect(utf8.decode(list[0] as Uint8List), equals('spam'));
        expect(list[1], equals(42));
      });

      test('rejects unterminated lists and extra delimiters', () {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode('l'))),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode('li1e'))),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode('leee'))),
          throwsA(isA<FormatException>()),
        );
      });

      test('enforces maxDepth recursion limit and prevents StackOverflow', () {
        // Build 512 nested lists -> should succeed
        final valid512 = StringBuffer();
        for (int i = 0; i < 512; i++) {
          valid512.write('l');
        }
        valid512.write('i1e');
        for (int i = 0; i < 512; i++) {
          valid512.write('e');
        }
        final decoded512 = Bencode.decode(
          Uint8List.fromList(ascii.encode(valid512.toString())),
        );
        expect(decoded512, isA<List<dynamic>>());

        // Build 513 nested lists -> should throw FormatException
        final invalid513 = StringBuffer();
        for (int i = 0; i < 513; i++) {
          invalid513.write('l');
        }
        invalid513.write('i1e');
        for (int i = 0; i < 513; i++) {
          invalid513.write('e');
        }
        expect(
          () => Bencode.decode(
            Uint8List.fromList(ascii.encode(invalid513.toString())),
          ),
          throwsA(isA<FormatException>()),
        );

        // Extreme 2000 nested lists
        final extreme2000 = StringBuffer();
        for (int i = 0; i < 2000; i++) {
          extreme2000.write('l');
        }
        extreme2000.write('i1e');
        for (int i = 0; i < 2000; i++) {
          extreme2000.write('e');
        }
        expect(
          () => Bencode.decode(
            Uint8List.fromList(ascii.encode(extreme2000.toString())),
          ),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('1.4 Dictionary & BEP 0003 Key Ordering Attacks', () {
      test('decodes empty and standard dictionaries', () {
        expect(
          Bencode.decode(Uint8List.fromList(ascii.encode('de'))),
          equals(<String, dynamic>{}),
        );
        final dict =
            Bencode.decode(
                  Uint8List.fromList(ascii.encode('d3:cow3:moo4:spam4:eggse')),
                )
                as Map<String, dynamic>;
        expect(utf8.decode(dict['cow'] as Uint8List), equals('moo'));
        expect(utf8.decode(dict['spam'] as Uint8List), equals('eggs'));
      });

      test('encoder sorts keys strictly by UTF-8 byte order', () {
        final map = {
          'z': 1,
          'a': 2,
          'aa': 3,
          'b': 4,
          'ä': 5, // UTF-8: 0xC3 0xA4
          'ü': 6, // UTF-8: 0xC3 0xBC
        };
        final encoded = Bencode.encode(map);
        final encodedStr = utf8.decode(encoded, allowMalformed: true);

        // Check that keys appear in order: a, aa, b, z, ä, ü
        final posA = encodedStr.indexOf('1:a');
        final posAA = encodedStr.indexOf('2:aa');
        final posB = encodedStr.indexOf('1:b');
        final posZ = encodedStr.indexOf('1:z');
        final posAe = encodedStr.indexOf('2:ä');
        final posUe = encodedStr.indexOf('2:ü');

        expect(posA < posAA, isTrue);
        expect(posAA < posB, isTrue);
        expect(posB < posZ, isTrue);
        expect(posZ < posAe, isTrue);
        expect(posAe < posUe, isTrue);
      });

      test('decoder rejects out-of-order keys under strictKeyOrder', () {
        const outOfOrder = 'd1:bi1e1:ai2ee';
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(outOfOrder))),
          throwsA(isA<FormatException>()),
        );
      });

      test('decoder rejects duplicate dictionary keys', () {
        const duplicateKeys = 'd1:ai1e1:ai2ee';
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(duplicateKeys))),
          throwsA(isA<FormatException>()),
        );
      });

      test('decoder rejects non-string dictionary keys', () {
        final nonStringKeyCases = ['di1ei2ee', 'dli1ee5:helloe', 'dde5:helloe'];
        for (final payload in nonStringKeyCases) {
          expect(
            () => Bencode.decode(Uint8List.fromList(ascii.encode(payload))),
            throwsA(isA<FormatException>()),
            reason:
                'Non-string key payload "$payload" must throw FormatException',
          );
        }
      });

      test('trailing data validation', () {
        final trailingPayload = Uint8List.fromList(ascii.encode('i42ejunk'));
        expect(
          () => Bencode.decode(trailingPayload, allowTrailingData: false),
          throwsA(isA<FormatException>()),
        );
        expect(
          Bencode.decode(trailingPayload, allowTrailingData: true),
          equals(42),
        );
      });
    });
  });

  group(
    'Target 2 — Torrent Metadata Parser (Bencode.decodeTorrent) Adversarial Battery',
    () {
      test('single-file torrent decode and SHA-1 infoHash matching', () {
        final piecesBytes = Uint8List(40); // 2 pieces of 20 bytes
        for (int i = 0; i < 40; i++) {
          piecesBytes[i] = i & 0xFF;
        }

        final infoDict = <String, dynamic>{
          'length': 1048576,
          'name': 'ubuntu-24.04.iso',
          'piece length': 524288,
          'pieces': piecesBytes,
        };

        final rootDict = <String, dynamic>{
          'announce': 'https://tracker.ubuntu.com/announce',
          'announce-list': [
            ['https://tracker.ubuntu.com/announce'],
            ['https://backup.tracker.com/announce'],
          ],
          'comment': 'Official Ubuntu ISO',
          'created by': 'mktorrent',
          'creation date': 1714000000,
          'info': infoDict,
        };

        final encoded = Bencode.encode(rootDict);
        final meta = Bencode.decodeTorrent(encoded);

        expect(meta.name, equals('ubuntu-24.04.iso'));
        expect(meta.totalSize, equals(1048576));
        expect(meta.pieceLength, equals(524288));
        expect(meta.pieceCount, equals(2));
        expect(meta.isMultiFile, isFalse);
        expect(meta.files.length, equals(1));
        expect(meta.files.first.path, equals('ubuntu-24.04.iso'));
        expect(meta.files.first.length, equals(1048576));
        expect(meta.announce, equals('https://tracker.ubuntu.com/announce'));
        expect(meta.announceList.length, equals(2));
        expect(meta.comment, equals('Official Ubuntu ISO'));
        expect(meta.createdBy, equals('mktorrent'));
        expect(meta.creationDate, isNotNull);

        // Verify SHA-1 infoHash calculation
        final expectedInfoHash = sha1.convert(Bencode.encode(infoDict)).bytes;
        expect(meta.infoHash, equals(Uint8List.fromList(expectedInfoHash)));
        expect(
          meta.infoHashHex,
          equals(
            sha1.convert(Bencode.encode(infoDict)).toString().toLowerCase(),
          ),
        );

        // Piece hashes
        expect(
          meta.getPieceHash(0),
          equals(Uint8List.sublistView(piecesBytes, 0, 20)),
        );
        expect(
          meta.getPieceHash(1),
          equals(Uint8List.sublistView(piecesBytes, 20, 40)),
        );
        expect(() => meta.getPieceHash(-1), throwsRangeError);
        expect(() => meta.getPieceHash(2), throwsRangeError);
      });

      test('multi-file torrent decode and path hierarchy parsing', () {
        final piecesBytes = Uint8List(60); // 3 pieces of 20 bytes
        final infoDict = <String, dynamic>{
          'name': 'dataset_folder',
          'piece length': 262144,
          'pieces': piecesBytes,
          'files': [
            {
              'length': 1000,
              'path': ['train', 'data.csv'],
            },
            {
              'length': 2000,
              'path': ['test', 'data.csv'],
            },
            {
              'length': 500,
              'path': ['README.md'],
            },
          ],
        };

        final rootDict = <String, dynamic>{'info': infoDict};

        final encoded = Bencode.encode(rootDict);
        final meta = Bencode.decodeTorrent(encoded);

        expect(meta.name, equals('dataset_folder'));
        expect(meta.totalSize, equals(3500));
        expect(meta.pieceCount, equals(3));
        expect(meta.isMultiFile, isTrue);
        expect(meta.files.length, equals(3));
        expect(meta.files[0].path, equals('train/data.csv'));
        expect(meta.files[0].length, equals(1000));
        expect(meta.files[1].path, equals('test/data.csv'));
        expect(meta.files[1].length, equals(2000));
        expect(meta.files[2].path, equals('README.md'));
        expect(meta.files[2].length, equals(500));
      });

      test('rejects corrupted or malformed torrent metainfo structures', () {
        // Non-dict root
        expect(
          () => Bencode.decodeTorrent(
            Uint8List.fromList(ascii.encode('i42e')),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => Bencode.decodeTorrent(
            Uint8List.fromList(ascii.encode('l4:teste')),
          ),
          throwsA(isA<FormatException>()),
        );

        // Missing info dict
        expect(
          () => Bencode.decodeTorrent(
            Uint8List.fromList(ascii.encode('d3:cow3:mooe')),
          ),
          throwsA(isA<FormatException>()),
        );

        // Info is not a dict
        expect(
          () => Bencode.decodeTorrent(
            Uint8List.fromList(ascii.encode('d4:info5:helloe')),
          ),
          throwsA(isA<FormatException>()),
        );

        // Invalid piece length (missing, <= 0, string)
        final badPieceLen1 = Bencode.encode({
          'info': {
            'name': 'x',
            'pieces': Uint8List(20),
            'length': 100,
          },
        });
        expect(
          () => Bencode.decodeTorrent(badPieceLen1),
          throwsA(isA<FormatException>()),
        );

        final badPieceLen2 = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 0,
            'pieces': Uint8List(20),
            'length': 100,
          },
        });
        expect(
          () => Bencode.decodeTorrent(badPieceLen2),
          throwsA(isA<FormatException>()),
        );

        final badPieceLen3 = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': -100,
            'pieces': Uint8List(20),
            'length': 100,
          },
        });
        expect(
          () => Bencode.decodeTorrent(badPieceLen3),
          throwsA(isA<FormatException>()),
        );

        // Invalid pieces (not multiple of 20, missing, wrong type)
        final badPieces1 = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(19),
            'length': 100,
          },
        });
        expect(
          () => Bencode.decodeTorrent(badPieces1),
          throwsA(isA<FormatException>()),
        );

        final badPieces2 = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': 12345,
            'length': 100,
          },
        });
        expect(
          () => Bencode.decodeTorrent(badPieces2),
          throwsA(isA<FormatException>()),
        );

        // Neither length nor files in info
        final noFilesOrLen = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
          },
        });
        expect(
          () => Bencode.decodeTorrent(noFilesOrLen),
          throwsA(isA<FormatException>()),
        );

        // Multi-file: files is not a list or is Uint8List
        final filesIsBytes = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
            'files': Uint8List.fromList(ascii.encode('not_a_list')),
          },
        });
        expect(
          () => Bencode.decodeTorrent(filesIsBytes),
          throwsA(isA<FormatException>()),
        );

        // Multi-file: files entry is not a dict
        final filesEntryNotDict = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
            'files': [123],
          },
        });
        expect(
          () => Bencode.decodeTorrent(filesEntryNotDict),
          throwsA(isA<FormatException>()),
        );

        // Multi-file: files entry path is byte string / not a list
        final pathIsByteString = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
            'files': [
              {
                'length': 100,
                'path': Uint8List.fromList(
                  ascii.encode('string_instead_of_list'),
                ),
              },
            ],
          },
        });
        expect(
          () => Bencode.decodeTorrent(pathIsByteString),
          throwsA(isA<FormatException>()),
        );

        // Multi-file: files entry path is empty list
        final pathIsEmptyList = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
            'files': [
              {'length': 100, 'path': <dynamic>[]},
            ],
          },
        });
        expect(
          () => Bencode.decodeTorrent(pathIsEmptyList),
          throwsA(isA<FormatException>()),
        );

        // Multi-file: files entry path has empty component
        final pathHasEmptyComp = Bencode.encode({
          'info': {
            'name': 'x',
            'piece length': 1024,
            'pieces': Uint8List(20),
            'files': [
              {
                'length': 100,
                'path': ['folder', '', 'file.txt'],
              },
            ],
          },
        });
        expect(
          () => Bencode.decodeTorrent(pathHasEmptyComp),
          throwsA(isA<FormatException>()),
        );
      });
    },
  );

  group('Target 3 — Model Piece Scale & Bitfield Adversarial Battery', () {
    test('supports swarms with pieceCount > 1,000,000 without clamping', () {
      const largePieceCounts = [1000000, 1000001, 2000000, 5000000];

      for (final count in largePieceCounts) {
        final model = TransmissionTorrentModel.fromJson({
          'id': 1,
          'pieceCount': count,
          'pieces': '',
        });
        expect(model.pieceCount, equals(count));
        expect(model.pieces.length, equals(count));
        expect(model.pieces.every((p) => p == false), isTrue);
      }
    });

    test('correctly decodes large bitfields at scale boundaries', () {
      const count = 1000008; // exactly 125001 bytes
      const numBytes = count ~/ 8;
      final bytes = Uint8List(numBytes);

      // Set piece 0 (MSB of byte 0)
      bytes[0] = 0x80;
      // Set piece 1,000,000 (byte 125,000, bit 7)
      bytes[125000] = 0x80;
      // Set piece 1,000,007 (byte 125,000, bit 0)
      bytes[125000] |= 0x01;

      final model = TransmissionTorrentModel.fromJson({
        'id': 2,
        'pieceCount': count,
        'pieces': base64Encode(bytes),
      });

      expect(model.pieceCount, equals(count));
      expect(model.pieces.length, equals(count));
      expect(model.pieces[0], isTrue);
      expect(model.pieces[1], isFalse);
      expect(model.pieces[1000000], isTrue);
      expect(model.pieces[1000001], isFalse);
      expect(model.pieces[1000007], isTrue);
    });

    test(
      'defensively clamps negative pieceCount and handles missing fields',
      () {
        final negativeModel = TransmissionTorrentModel.fromJson({
          'id': 3,
          'pieceCount': -50,
          'pieces': '////',
        });
        expect(negativeModel.pieceCount, equals(0));
        expect(negativeModel.pieces, isEmpty);

        final nullModel = TransmissionTorrentModel.fromJson({
          'id': 4,
          'pieceCount': null,
          'pieces': null,
        });
        expect(nullModel.pieceCount, equals(0));
        expect(nullModel.pieces, isEmpty);
      },
    );

    test(
      'convertBitfieldToBoolList handles truncated, oversized, and edge bitfields',
      () {
        // Truncated: pieceCount = 16, bitfield has only 1 byte (8 pieces)
        final truncated = convertBitfieldToBoolList(
          Uint8List.fromList([0xFF]),
          16,
        );
        expect(truncated.length, equals(16));
        expect(truncated.sublist(0, 8), equals(List.filled(8, true)));
        expect(truncated.sublist(8, 16), equals(List.filled(8, false)));

        // Oversized: pieceCount = 4, bitfield has 2 bytes (16 pieces)
        final oversized = convertBitfieldToBoolList(
          Uint8List.fromList([0xFF, 0xFF]),
          4,
        );
        expect(oversized.length, equals(4));
        expect(oversized, equals(List.filled(4, true)));

        // Empty bitfield with large pieceCount
        final emptyLarge = convertBitfieldToBoolList(Uint8List(0), 100000);
        expect(emptyLarge.length, equals(100000));
        expect(emptyLarge.every((p) => p == false), isTrue);
      },
    );

    test(
      'graceful fallback for malformed or non-string pieces JSON fields',
      () {
        final malformedCases = [
          'invalid base64!!!',
          '==',
          'AAAA==',
          'A',
          12345,
          3.14,
          true,
          false,
          ['base64string'],
          {'key': 'value'},
        ];

        for (final rawPieces in malformedCases) {
          final model = TransmissionTorrentModel.fromJson({
            'id': 5,
            'pieceCount': 10,
            'pieces': rawPieces,
          });
          expect(model.pieceCount, equals(10));
          expect(model.pieces.length, equals(10));
          expect(model.pieces.every((p) => p == false), isTrue);
        }
      },
    );
  });

  group('Target 4 — Add Torrent Pre-Inspection & Storage Check Battery', () {
    test(
      'calculates predictedSize accurately across single-file and multi-file torrents',
      () {
        // Single-file
        final singleInfo = {
          'name': 'linux.iso',
          'length':
              4294967296, // 4 GB (exceeds 32-bit signed int if not 64-bit int)
          'piece length': 1048576,
          'pieces': Uint8List(20),
        };
        final singleMeta = Bencode.decodeTorrent(
          Bencode.encode({'info': singleInfo}),
        );
        expect(singleMeta.totalSize, equals(4294967296));

        // Multi-file
        final multiInfo = {
          'name': 'big_dataset',
          'piece length': 1048576,
          'pieces': Uint8List(20),
          'files': [
            {
              'length': 5368709120,
              'path': ['chunk1.bin'],
            }, // 5 GB
            {
              'length': 5368709120,
              'path': ['chunk2.bin'],
            }, // 5 GB
            {
              'length': 0,
              'path': ['empty.txt'],
            }, // 0 B
          ],
        };
        final multiMeta = Bencode.decodeTorrent(
          Bencode.encode({'info': multiInfo}),
        );
        expect(multiMeta.totalSize, equals(10737418240)); // 10 GB
      },
    );

    test('storage warning condition logic validation', () {
      bool shouldWarn(int freeSpace, int predictedSize) {
        return freeSpace > 0 && predictedSize > 0 && freeSpace < predictedSize;
      }

      // Cases where warning SHOULD trigger
      expect(shouldWarn(100, 200), isTrue);
      expect(shouldWarn(1000000, 2000000), isTrue);
      expect(shouldWarn(1, 2), isTrue);

      // Cases where warning should NOT trigger
      expect(shouldWarn(200, 100), isFalse); // enough space
      expect(shouldWarn(100, 100), isFalse); // exact space
      expect(shouldWarn(0, 100), isFalse); // freeSpace unknown (0)
      expect(
        shouldWarn(100, 0),
        isFalse,
      ); // predictedSize unknown (0, e.g. magnet link before metadata)
      expect(shouldWarn(0, 0), isFalse); // both unknown
      expect(shouldWarn(-1, 100), isFalse); // negative free space
    });
  });
}
