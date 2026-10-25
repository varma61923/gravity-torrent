import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/utils/bencode.dart';

void main() {
  group('Adversarial Bencode - Malformed Integers', () {
    test('rejects leading zeros in positive and negative integers', () {
      final cases = ['i00e', 'i01e', 'i007e', 'i-01e', 'i-00e', 'i-007e'];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" should throw FormatException',
        );
      }
    });

    test('rejects negative zero per BEP 0003', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i-0e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects explicit positive signs', () {
      final cases = ['i+0e', 'i+1e', 'i+42e', 'i+9999e'];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" should throw FormatException',
        );
      }
    });

    test('rejects unterminated integers or missing e', () {
      final cases = ['i', 'i123', 'i-42', 'i0', 'i9999999999'];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" should throw FormatException',
        );
      }
    });

    test('rejects empty integers and bare signs', () {
      final cases = ['ie', 'i-e', 'i+e', 'i--1e', 'i-1-1e', 'i+-5e'];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" should throw FormatException',
        );
      }
    });

    test(
        'rejects invalid characters, floats, hex, spaces, and null bytes in integer token',
        () {
      final cases = [
        'i1.0e',
        'i1.5e',
        'i 1e',
        'i1 e',
        'i\t5e',
        'i5\te',
        'i\n-2e',
        'i-2\ne',
        'i\r42e',
        'i42\re',
        'i \t\n\r 7e',
        'i\x0b5e', // vertical tab
        'i\x0c5e', // form feed
        'i0x10e',
        'i0b101e',
        'i1a2e',
        'iNaNe',
        'iInfe',
        'i\x00e',
      ];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" should throw FormatException',
        );
      }
    });

    test('handles 64-bit integer boundaries and rejects integer overflows', () {
      // 64-bit boundaries
      const maxInt = 9223372036854775807;
      const minInt = -9223372036854775808;

      expect(
        Bencode.decode(Uint8List.fromList(ascii.encode('i${maxInt}e'))),
        equals(maxInt),
      );
      expect(
        Bencode.decode(Uint8List.fromList(ascii.encode('i${minInt}e'))),
        equals(minInt),
      );

      // Huge integers beyond 64-bit signed int
      final overflowCases = [
        'i9223372036854775808e', // maxInt + 1
        'i-9223372036854775809e', // minInt - 1
        'i999999999999999999999999e',
        'i-999999999999999999999999e',
        'i123456789012345678901234567890e',
      ];
      for (final c in overflowCases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Overflow integer "$c" should throw FormatException',
        );
      }
    });
  });

  group('Adversarial Bencode - Truncated Strings & Length Anomalies', () {
    test('rejects truncated byte strings at various cutoffs', () {
      final cases = [
        '5:abc', // 3 bytes instead of 5
        '5:abcd', // 4 bytes instead of 5
        '100:short',
        '10:', // 0 bytes instead of 10
        '1:', // 0 bytes instead of 1
      ];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Truncated string "$c" should throw FormatException',
        );
      }
    });

    test('rejects negative, non-digit, or missing colon lengths', () {
      final cases = [
        '-1:a',
        '-5:hello',
        '--1:a',
        '1-1:a',
        '+5:hello',
        ' 5:hello',
        '5 :hello',
        '5a:hello',
        'a5:hello',
        '5hello',
        ':hello',
      ];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Malformed length string "$c" should throw FormatException',
        );
      }
    });

    test('rejects leading zeros in string lengths', () {
      final cases = ['00:', '01:a', '005:hello', '09:123456789'];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Leading zero length "$c" should throw FormatException',
        );
      }
    });

    test('rejects massive or overflow string lengths safely without OOM crash',
        () {
      final cases = [
        '999999999999999999999999:abc',
        '9223372036854775807:abc', // int64.max
        '9223372036854775806:abc', // int64.max - 1
        '9223372036854775800:abc',
        '4611686018427387903:abc', // int64.max / 2
        '2147483647:abc', // int32.max
      ];
      for (final c in cases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Massive length "$c" should throw FormatException',
        );
      }
    });

    test('handles zero-length strings and arbitrary binary payloads correctly',
        () {
      expect(
        Bencode.decode(Uint8List.fromList(ascii.encode('0:'))),
        equals(Uint8List(0)),
      );

      final rawBytes = Uint8List.fromList([
        0x00,
        0x01,
        0x02,
        0xFF,
        0xFE,
        0x80,
        0x7F,
        0x00,
        0x00,
        0xAA,
      ]);
      final encoded = Bencode.encode(rawBytes);
      expect(encoded.sublist(0, 3), equals(ascii.encode('10:')));
      expect(encoded.sublist(3), equals(rawBytes));

      final decoded = Bencode.decode(encoded) as Uint8List;
      expect(decoded, equals(rawBytes));
    });
  });

  group(
      'Adversarial Bencode - Dictionary Key Ordering, Uniqueness & UTF-8 Bytes',
      () {
    test('rejects duplicate dictionary keys at root and nested levels', () {
      final duplicateRoot = Uint8List.fromList(
        ascii.encode('d3:cow3:moo3:cow4:moo2e'),
      );
      expect(
        () => Bencode.decode(duplicateRoot),
        throwsA(isA<FormatException>()),
      );

      final duplicateNested = Uint8List.fromList(
        ascii.encode('d4:dictd3:cow3:moo3:cow4:moo2ee'),
      );
      expect(
        () => Bencode.decode(duplicateNested),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsorted dictionary keys under strict key ordering', () {
      final unsortedRoot = Uint8List.fromList(
        ascii.encode('d3:zoo1:a3:cow3:mooe'),
      );
      expect(
        () => Bencode.decode(unsortedRoot, strictKeyOrder: true),
        throwsA(isA<FormatException>()),
      );

      final unsortedSubstrings = Uint8List.fromList(
        ascii.encode('d2:aa1:11:a1:2e'), // 'aa' before 'a' -> invalid!
      );
      expect(
        () => Bencode.decode(unsortedSubstrings, strictKeyOrder: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('allows non-strict mode when strictKeyOrder is false', () {
      final unsorted = Uint8List.fromList(
        ascii.encode('d3:zoo1:a3:cow3:mooe'),
      );
      final decoded = Bencode.decode(unsorted, strictKeyOrder: false)
          as Map<String, dynamic>;
      expect(decoded.containsKey('zoo'), isTrue);
      expect(decoded.containsKey('cow'), isTrue);
    });

    test(
        'strictly enforces UTF-8 byte ordering vs UTF-16 code units (BEP 0003)',
        () {
      // Test cases with 1-byte, 2-byte, 3-byte, and 4-byte UTF-8 sequences
      // 'a' = 0x61 (1 byte)
      // 'z' = 0x7A (1 byte)
      // 'ä' = 0xC3 0xA4 (2 bytes)
      // '中' = 0xE4 0xB8 0xAD (3 bytes)
      // '\uE000' = 0xEE 0x80 0x80 (3 bytes, BMP)
      // '🌍' (\u{1F600} / \u{1F30D}) = 0xF0 0x9F ... (4 bytes, non-BMP)

      final map = <String, dynamic>{
        '🌍': 4,
        '\uE000': 3,
        '中': 2,
        'ä': 1,
        'z': 0,
        'a': -1,
      };

      final encoded = Bencode.encode(map);
      final decoded = Bencode.decode(encoded) as Map<String, dynamic>;

      // Expected sorted key order by raw UTF-8 byte sequence:
      // 'a' (0x61)
      // 'z' (0x7A)
      // 'ä' (0xC3 0xA4)
      // '中' (0xE4 0xB8 0xAD)
      // '\uE000' (0xEE 0x80 0x80)
      // '🌍' (0xF0 0x9F 0x8C 0x8D)
      final expectedKeys = ['a', 'z', 'ä', '中', '\uE000', '🌍'];
      expect(decoded.keys.toList(), equals(expectedKeys));

      // Test that reversing any pair causes decode to fail under strictKeyOrder
      // Manually construct invalidly ordered bencode payload
      final invalidPayload = BytesBuilder();
      invalidPayload.addByte(0x64); // 'd'
      final emojiBytes = utf8.encode('🌍');
      invalidPayload.add(ascii.encode('${emojiBytes.length}:'));
      invalidPayload.add(emojiBytes);
      invalidPayload.add(ascii.encode('i1e'));
      final puaBytes = utf8.encode('\uE000');
      invalidPayload.add(ascii.encode('${puaBytes.length}:'));
      invalidPayload.add(puaBytes);
      invalidPayload.add(ascii.encode('i2e'));
      invalidPayload.addByte(0x65); // 'e'

      expect(
        () => Bencode.decode(invalidPayload.toBytes(), strictKeyOrder: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-string dictionary keys', () {
      final invalidKeys = [
        'di42e4:spame',
        'dle4:spame',
        'dde4:spame',
      ];
      for (final c in invalidKeys) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason:
              'Dictionary with non-string key "$c" should throw FormatException',
        );
      }
    });
  });

  group('Adversarial Bencode - Deep Nesting Limits & Stack Safety', () {
    test('accurately decodes at exact maxDepth limit (512 levels)', () {
      final buffer = StringBuffer();
      for (int i = 0; i < 512; i++) {
        buffer.write('l');
      }
      buffer.write('i42e');
      for (int i = 0; i < 512; i++) {
        buffer.write('e');
      }
      final bytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      final decoded = Bencode.decode(bytes, maxDepth: 512);
      expect(decoded, isNotNull);
    });

    test('throws FormatException when nesting exceeds maxDepth (513 levels)',
        () {
      final buffer = StringBuffer();
      for (int i = 0; i < 513; i++) {
        buffer.write('l');
      }
      buffer.write('i42e');
      for (int i = 0; i < 513; i++) {
        buffer.write('e');
      }
      final bytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      expect(
        () => Bencode.decode(bytes, maxDepth: 512),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Exceeded maximum bencode nesting depth'),
          ),
        ),
      );
    });

    test('enforces maxDepth on nested dictionaries', () {
      final buffer = StringBuffer();
      for (int i = 0; i < 600; i++) {
        buffer.write('d1:a');
      }
      buffer.write('i1e');
      for (int i = 0; i < 600; i++) {
        buffer.write('e');
      }
      final bytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      expect(
        () => Bencode.decode(bytes, maxDepth: 512),
        throwsA(isA<FormatException>()),
      );
    });

    test(
        'extreme depth stress test (1500 levels) never triggers uncatchable StackOverflow',
        () {
      final buffer = StringBuffer();
      for (int i = 0; i < 1500; i++) {
        buffer.write('l');
      }
      buffer.write('i0e');
      for (int i = 0; i < 1500; i++) {
        buffer.write('e');
      }
      final bytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      expect(
        () => Bencode.decode(bytes, maxDepth: 512),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Adversarial Bencode - Trailing Junk & Container Delimiters', () {
    test('rejects trailing junk data after root integer, string, list, or dict',
        () {
      final payloads = [
        'i42eextra',
        '4:spamjunk',
        'leextra',
        'deextra',
        'l4:spameextra',
        'd3:cow3:mooe\x00',
        'd3:cow3:mooe   ',
      ];
      for (final p in payloads) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(p))),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Extraneous trailing data'),
            ),
          ),
          reason:
              'Payload with trailing data "$p" should throw FormatException',
        );
      }
    });

    test('rejects unclosed or extra closed delimiters', () {
      final payloads = [
        'l',
        'd',
        'l4:spam',
        'd3:cow3:moo',
        'll4:spame',
        'ee',
        'e',
        'i42ee',
        '4:spame',
      ];
      for (final p in payloads) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(p))),
          throwsA(isA<FormatException>()),
          reason:
              'Unbalanced delimiter payload "$p" should throw FormatException',
        );
      }
    });
  });

  group('Adversarial Bencode - decodeTorrent & Corrupted Metainfo', () {
    Uint8List makeValidTorrent({
      dynamic name = 'sample.bin',
      dynamic pieceLength = 16384,
      dynamic pieces,
      dynamic length = 32768,
      dynamic files,
      dynamic announce = 'http://tracker.org/announce',
      dynamic announceList,
      dynamic privateVal,
    }) {
      final piecesBytes = pieces ?? Uint8List(40); // 2 pieces
      final info = <String, dynamic>{
        'name': name,
        'piece length': pieceLength,
        'pieces': piecesBytes,
      };
      if (files != null) {
        info['files'] = files;
      } else if (length != null) {
        info['length'] = length;
      }
      if (privateVal != null) {
        info['private'] = privateVal;
      }

      final root = <String, dynamic>{
        'info': info,
      };
      if (announce != null) root['announce'] = announce;
      if (announceList != null) root['announce-list'] = announceList;
      return Bencode.encode(root);
    }

    test('throws FormatException on corrupted info dictionary', () {
      // 1. Root is not a dict
      expect(
        () => Bencode.decodeTorrent(Uint8List.fromList(ascii.encode('i42e'))),
        throwsA(isA<FormatException>()),
      );

      // 2. Info is not a dict
      expect(
        () => Bencode.decodeTorrent(
          Uint8List.fromList(ascii.encode('d4:info4:spame')),
        ),
        throwsA(isA<FormatException>()),
      );

      // 3. Missing info key
      expect(
        () => Bencode.decodeTorrent(
          Uint8List.fromList(ascii.encode('d8:announce16:http://test.com/e')),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on invalid piece length', () {
      // Non-integer piece length
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieceLength: '16384')),
        throwsA(isA<FormatException>()),
      );

      // Zero piece length
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieceLength: 0)),
        throwsA(isA<FormatException>()),
      );

      // Negative piece length
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieceLength: -16384)),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on invalid pieces byte string', () {
      // Not a byte string
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieces: 12345)),
        throwsA(isA<FormatException>()),
      );

      // Invalid length: 19 bytes (not divisible by 20)
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieces: Uint8List(19))),
        throwsA(isA<FormatException>()),
      );

      // Invalid length: 21 bytes
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieces: Uint8List(21))),
        throwsA(isA<FormatException>()),
      );

      // Invalid length: 39 bytes
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(pieces: Uint8List(39))),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on invalid single-file length or missing mode',
        () {
      // Negative single-file length
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(length: -10)),
        throwsA(isA<FormatException>()),
      );

      // Neither length nor files present
      expect(
        () =>
            Bencode.decodeTorrent(makeValidTorrent(length: null, files: null)),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on corrupted multi-file file entries', () {
      // files is not a list
      expect(
        () => Bencode.decodeTorrent(makeValidTorrent(files: 'not a list')),
        throwsA(isA<FormatException>()),
      );

      // files entry is not a map
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(files: ['not a map']),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry missing length
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'path': ['file.txt'],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry negative length
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': -50,
                'path': ['file.txt'],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry missing path or empty path
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {'length': 100, 'path': []},
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry path is not a list
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {'length': 100, 'path': 'string_instead_of_list'},
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry path is a raw Uint8List byte string
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': Uint8List.fromList(utf8.encode('byte_string_path.txt')),
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry path containing non-string items (e.g. integers, maps, nested lists)
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': [12345],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': [
                  {'nested': 'dict'},
                ],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': [
                  ['nested_list'],
                ],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      // files entry path containing empty string components
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': [''],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decodeTorrent(
          makeValidTorrent(
            files: [
              {
                'length': 100,
                'path': ['dir', ''],
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('handles fallback name and private flag correctly', () {
      // Missing name falls back gracefully to 'Unnamed Torrent'
      final torrentWithoutName = makeValidTorrent(name: null);
      final metadata = Bencode.decodeTorrent(torrentWithoutName);
      expect(metadata.name, equals('Unnamed Torrent'));

      // private flag = 1
      final privTorrent = makeValidTorrent(privateVal: 1);
      final privMeta = Bencode.decodeTorrent(privTorrent);
      expect(privMeta.isPrivate, isTrue);

      // private flag = 0
      final pubTorrent = makeValidTorrent(privateVal: 0);
      final pubMeta = Bencode.decodeTorrent(pubTorrent);
      expect(pubMeta.isPrivate, isFalse);
    });

    test(
        'infoHash is identical to SHA-1 of original raw info dictionary bytes slice',
        () {
      // Create a torrent metainfo with non-standard key ordering in the raw bytes
      // to guarantee that infoHash is calculated directly on the raw slice and not re-serialized
      final valid = makeValidTorrent(name: 'hash_test.iso', length: 1000);
      final meta = Bencode.decodeTorrent(valid);

      // Decode the dictionary raw and verify SHA-1
      final rawDecoded = Bencode.decode(valid) as Map<String, dynamic>;
      final rawInfoEncoded = Bencode.encode(rawDecoded['info'] as Object);
      final sha1Expected =
          sha1.convert(rawInfoEncoded).toString().toLowerCase();

      expect(meta.infoHashHex, equals(sha1Expected));
      expect(meta.infoHash.length, equals(20));
    });
  });

  group('Adversarial Bencode - Fuzz & Random Mutation Stress Harness', () {
    test(
        'survives 1000 randomized pseudo-fuzz mutations without crashes or hangs',
        () {
      final rng = Random(0xCAFE);

      // Base valid seeds
      final validSeeds = [
        ascii.encode('i42e'),
        ascii.encode('4:spam'),
        ascii.encode('l4:spami42ee'),
        ascii.encode('d3:cow3:moo4:spam4:eggse'),
        ascii.encode(
          'd4:infod6:lengthi100e4:name4:test12:piece lengthi16384e6:pieces20:12345678901234567890eee',
        ),
      ];

      int formatExceptions = 0;
      int successfulDecodes = 0;

      for (int i = 0; i < 1000; i++) {
        final mutationType = rng.nextInt(5);
        Uint8List testPayload;

        if (mutationType == 0) {
          // Completely random byte array (length 0 to 256)
          final len = rng.nextInt(256);
          testPayload = Uint8List(len);
          for (int j = 0; j < len; j++) {
            testPayload[j] = rng.nextInt(256);
          }
        } else if (mutationType == 1) {
          // Truncation of valid seed
          final seed = validSeeds[rng.nextInt(validSeeds.length)];
          final cut = rng.nextInt(seed.length + 1);
          testPayload = Uint8List.fromList(seed.sublist(0, cut));
        } else if (mutationType == 2) {
          // Bit flips on valid seed
          final seed = validSeeds[rng.nextInt(validSeeds.length)];
          testPayload = Uint8List.fromList(seed);
          if (testPayload.isNotEmpty) {
            final flipIndex = rng.nextInt(testPayload.length);
            testPayload[flipIndex] ^= (1 << rng.nextInt(8));
          }
        } else if (mutationType == 3) {
          // Insertion of random byte into valid seed
          final seed = validSeeds[rng.nextInt(validSeeds.length)];
          final insertPos = rng.nextInt(seed.length + 1);
          final list = List<int>.from(seed);
          list.insert(insertPos, rng.nextInt(256));
          testPayload = Uint8List.fromList(list);
        } else {
          // Repetition of bencode tokens ('i', 'e', 'l', 'd', ':', '0')
          final tokens = [0x69, 0x65, 0x6C, 0x64, 0x3A, 0x30, 0x31, 0x2D];
          final len = rng.nextInt(64) + 1;
          testPayload = Uint8List(len);
          for (int j = 0; j < len; j++) {
            testPayload[j] = tokens[rng.nextInt(tokens.length)];
          }
        }

        try {
          final res =
              Bencode.decode(testPayload, allowTrailingData: rng.nextBool());
          if (res != null) {
            successfulDecodes++;
          }
        } on FormatException {
          formatExceptions++;
        } catch (e, st) {
          fail(
            'Unexpected exception type ${e.runtimeType}: $e\n$st for payload: $testPayload',
          );
        }
      }

      expect(formatExceptions + successfulDecodes, equals(1000));
      expect(formatExceptions, greaterThan(0));
    });
  });
}
