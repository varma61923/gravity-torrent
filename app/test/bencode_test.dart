import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/utils/bencode.dart';

void main() {
  group('Bencode - Integer Encoding & Decoding', () {
    test('encodes and decodes standard integers', () {
      expect(Bencode.encode(0), equals(Uint8List.fromList(ascii.encode('i0e'))));
      expect(Bencode.encode(42), equals(Uint8List.fromList(ascii.encode('i42e'))));
      expect(Bencode.encode(-42), equals(Uint8List.fromList(ascii.encode('i-42e'))));

      expect(Bencode.decode(Uint8List.fromList(ascii.encode('i0e'))), equals(0));
      expect(Bencode.decode(Uint8List.fromList(ascii.encode('i42e'))), equals(42));
      expect(Bencode.decode(Uint8List.fromList(ascii.encode('i-42e'))), equals(-42));
    });

    test('supports 64-bit signed integer limits', () {
      const maxInt = 9223372036854775807;
      const minInt = -9223372036854775808;

      expect(Bencode.encode(maxInt), equals(Uint8List.fromList(ascii.encode('i${maxInt}e'))));
      expect(Bencode.encode(minInt), equals(Uint8List.fromList(ascii.encode('i${minInt}e'))));

      expect(Bencode.decode(Uint8List.fromList(ascii.encode('i${maxInt}e'))), equals(maxInt));
      expect(Bencode.decode(Uint8List.fromList(ascii.encode('i${minInt}e'))), equals(minInt));
    });

    test('rejects negative zero per BEP 0003', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i-0e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects leading zeros per BEP 0003', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i03e'))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i00e'))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i-03e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects explicit positive signs', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i+5e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty or unterminated integers', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('ie'))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i123'))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('i12a3e'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects whitespace within integer payloads', () {
      final whitespaceCases = [
        'i 1e',
        'i1 e',
        'i\t5e',
        'i5\te',
        'i\n-2e',
        'i-2\ne',
        'i\r\n42e',
        'i \t 0e',
      ];
      for (final c in whitespaceCases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Payload "$c" containing whitespace must throw FormatException',
        );
      }
    });
  });

  group('Bencode - Byte String Encoding & Decoding', () {
    test('encodes and decodes empty string', () {
      final encoded = Bencode.encode('');
      expect(encoded, equals(Uint8List.fromList(ascii.encode('0:'))));
      final decoded = Bencode.decode(encoded);
      expect(decoded, isA<Uint8List>());
      expect((decoded as Uint8List).isEmpty, isTrue);
    });

    test('encodes and decodes ASCII strings', () {
      final encoded = Bencode.encode('spam');
      expect(encoded, equals(Uint8List.fromList(ascii.encode('4:spam'))));
      final decoded = Bencode.decode(encoded);
      expect(decoded, equals(Uint8List.fromList(utf8.encode('spam'))));
      expect(utf8.decode(decoded as Uint8List), equals('spam'));
    });

    test('encodes multi-byte UTF-8 strings accurately with byte count', () {
      const text = 'hello 🌍'; // 'hello ' = 6 bytes, '🌍' = 4 bytes (0xF0 0x9F 0x8C 0x8D) -> total 10 bytes
      final encoded = Bencode.encode(text);
      final expectedHeader = ascii.encode('10:');
      expect(encoded.sublist(0, 3), equals(expectedHeader));
      final decoded = Bencode.decode(encoded) as Uint8List;
      expect(utf8.decode(decoded), equals(text));
    });

    test('encodes and decodes raw binary bytes safely', () {
      final raw = Uint8List.fromList([0x00, 0xFF, 0x80, 0x12, 0xFE, 0x00]);
      final encoded = Bencode.encode(raw);
      expect(encoded.sublist(0, 2), equals(ascii.encode('6:')));
      expect(encoded.sublist(2), equals(raw));
      final decoded = Bencode.decode(encoded) as Uint8List;
      expect(decoded, equals(raw));
    });

    test('rejects truncated byte strings', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('4:spa'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects leading zeros in byte string length', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('04:spam'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing colon or malformed length', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('4spam'))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('-4:spam'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects huge and 64-bit integer overflow byte string lengths safely', () {
      final hugeLengthCases = [
        '9223372036854775807:abc',
        '9223372036854775806:abc',
        '4611686018427387903:abc',
        '2147483647:abc',
      ];
      for (final c in hugeLengthCases) {
        expect(
          () => Bencode.decode(Uint8List.fromList(ascii.encode(c))),
          throwsA(isA<FormatException>()),
          reason: 'Huge string length "$c" must throw FormatException instead of crashing',
        );
      }
    });
  });

  group('Bencode - List Encoding & Decoding', () {
    test('encodes and decodes empty list', () {
      final encoded = Bencode.encode([]);
      expect(encoded, equals(Uint8List.fromList(ascii.encode('le'))));
      final decoded = Bencode.decode(encoded);
      expect(decoded, equals([]));
    });

    test('encodes and decodes heterogeneous lists', () {
      final encoded = Bencode.encode(['spam', 42]);
      expect(encoded, equals(Uint8List.fromList(ascii.encode('l4:spami42ee'))));
      final decoded = Bencode.decode(encoded) as List<dynamic>;
      expect(decoded.length, equals(2));
      expect(decoded[0], equals(Uint8List.fromList(utf8.encode('spam'))));
      expect(decoded[1], equals(42));
    });

    test('encodes and decodes nested lists', () {
      final encoded = Bencode.encode([
        ['nested'],
      ]);
      expect(encoded, equals(Uint8List.fromList(ascii.encode('ll6:nestedee'))));
      final decoded = Bencode.decode(encoded) as List<dynamic>;
      expect(decoded.length, equals(1));
      expect(decoded[0], isA<List<dynamic>>());
      expect((decoded[0] as List)[0], equals(Uint8List.fromList(utf8.encode('nested'))));
    });

    test('rejects unterminated lists', () {
      expect(
        () => Bencode.decode(Uint8List.fromList(ascii.encode('li1e'))),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Bencode - Dictionary Encoding & Decoding', () {
    test('encodes and decodes empty dictionary', () {
      final encoded = Bencode.encode({});
      expect(encoded, equals(Uint8List.fromList(ascii.encode('de'))));
      final decoded = Bencode.decode(encoded);
      expect(decoded, equals({}));
    });

    test('encodes and decodes standard dictionary', () {
      final dict = {
        'cow': 'moo',
        'spam': 'eggs',
      };
      final encoded = Bencode.encode(dict);
      expect(encoded, equals(Uint8List.fromList(ascii.encode('d3:cow3:moo4:spam4:eggse'))));
      final decoded = Bencode.decode(encoded) as Map<String, dynamic>;
      expect(decoded.keys.toList(), equals(['cow', 'spam']));
      expect(decoded['cow'], equals(Uint8List.fromList(utf8.encode('moo'))));
      expect(decoded['spam'], equals(Uint8List.fromList(utf8.encode('eggs'))));
    });

    test('sorts dictionary keys in unsigned lexicographical UTF-8 byte order', () {
      final dict = {
        'z': 1,
        'aa': 2,
        'a': 3,
        'b': 4,
      };
      final encoded = Bencode.encode(dict);
      expect(
        encoded,
        equals(Uint8List.fromList(ascii.encode('d1:ai3e2:aai2e1:bi4e1:zi1ee'))),
      );
    });

    test('properly orders UTF-8 bytes vs UTF-16 code units (BEP 0003 compliance)', () {
      // '\uE000' is Private Use Area (UTF-8: 0xEE 0x80 0x80)
      // '\u{1F600}' is Grinning Face emoji (UTF-8: 0xF0 0x9F 0x98 0x80)
      // In UTF-16: '\u{1F600}' (0xD83D 0xDE00) < '\uE000' (0xE000)
      // In UTF-8: 0xEE 0x80 0x80 < 0xF0 0x9F 0x98 0x80 -> '\uE000' must come FIRST!
      final dict = {
        '\u{1F600}': 'emoji',
        '\uE000': 'pua',
      };
      final encoded = Bencode.encode(dict);

      // Decoded keys in order must be '\uE000' then '\u{1F600}'
      final decoded = Bencode.decode(encoded) as Map<String, dynamic>;
      expect(decoded.keys.toList(), equals(['\uE000', '\u{1F600}']));
    });

    test('rejects duplicate dictionary keys', () {
      final duplicateKeyBytes = Uint8List.fromList(
        ascii.encode('d3:cow3:moo3:cow3:mooe'),
      );
      expect(
        () => Bencode.decode(duplicateKeyBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects out-of-order dictionary keys under strict key ordering', () {
      final outOfOrderBytes = Uint8List.fromList(
        ascii.encode('d4:spam4:eggs3:cow3:mooe'),
      );
      expect(
        () => Bencode.decode(outOfOrderBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-string dictionary keys', () {
      final nonStringKeyBytes = Uint8List.fromList(
        ascii.encode('di1e4:spame'),
      );
      expect(
        () => Bencode.decode(nonStringKeyBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unterminated dictionaries', () {
      final unterminatedBytes = Uint8List.fromList(
        ascii.encode('d3:cow3:moo'),
      );
      expect(
        () => Bencode.decode(unterminatedBytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Bencode - Deep Nesting & Security Limits', () {
    test('enforces maxDepth recursion limit and prevents StackOverflowError', () {
      final buffer = StringBuffer();
      for (int i = 0; i < 600; i++) {
        buffer.write('l');
      }
      buffer.write('i1e');
      for (int i = 0; i < 600; i++) {
        buffer.write('e');
      }
      final deepBytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      expect(
        () => Bencode.decode(deepBytes, maxDepth: 512),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Exceeded maximum bencode nesting depth'),
          ),
        ),
      );
    });

    test('respects configurable maxDepth parameter', () {
      final buffer = StringBuffer();
      for (int i = 0; i < 15; i++) {
        buffer.write('l');
      }
      buffer.write('i1e');
      for (int i = 0; i < 15; i++) {
        buffer.write('e');
      }
      final bytes = Uint8List.fromList(ascii.encode(buffer.toString()));

      expect(
        () => Bencode.decode(bytes, maxDepth: 10),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => Bencode.decode(bytes, maxDepth: 20),
        returnsNormally,
      );
    });
  });

  group('Bencode - Stream & Trailing Data Checks', () {
    test('rejects empty input buffer', () {
      expect(
        () => Bencode.decode(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects extraneous trailing data by default', () {
      final trailingBytes = Uint8List.fromList(ascii.encode('i42eextra'));
      expect(
        () => Bencode.decode(trailingBytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Extraneous trailing data'),
          ),
        ),
      );
    });

    test('allows trailing data when allowTrailingData is true', () {
      final trailingBytes = Uint8List.fromList(ascii.encode('i42eextra'));
      final decoded = Bencode.decode(trailingBytes, allowTrailingData: true);
      expect(decoded, equals(42));
    });
  });

  group('Bencode - decodeTorrent & TorrentMetadata', () {
    test('decodes single-file torrent metainfo and computes SHA-1 infoHash', () {
      final dummyPieces = Uint8List(60); // 3 pieces (3 * 20 bytes)
      for (int i = 0; i < 60; i++) {
        dummyPieces[i] = i % 256;
      }

      final infoDict = <String, dynamic>{
        'length': 45000,
        'name': 'test_file.iso',
        'piece length': 16384,
        'pieces': dummyPieces,
      };

      final rootDict = <String, dynamic>{
        'announce': 'http://tracker.example.com/announce',
        'comment': 'Test Torrent Comment',
        'created by': 'Gravity Test Suite',
        'creation date': 1700000000,
        'info': infoDict,
      };

      final encoded = Bencode.encode(rootDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.name, equals('test_file.iso'));
      expect(metadata.totalSize, equals(45000));
      expect(metadata.pieceLength, equals(16384));
      expect(metadata.pieceCount, equals(3));
      expect(metadata.isMultiFile, isFalse);
      expect(metadata.files.length, equals(1));
      expect(metadata.files.first.path, equals('test_file.iso'));
      expect(metadata.files.first.length, equals(45000));
      expect(metadata.announce, equals('http://tracker.example.com/announce'));
      expect(metadata.comment, equals('Test Torrent Comment'));
      expect(metadata.createdBy, equals('Gravity Test Suite'));
      expect(metadata.creationDate, equals(DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true)));

      // Validate InfoHash SHA-1 calculation
      final expectedInfoBytes = Bencode.encode(infoDict);
      final expectedDigest = sha1.convert(expectedInfoBytes);
      expect(metadata.infoHash, equals(Uint8List.fromList(expectedDigest.bytes)));
      expect(metadata.infoHashHex, equals(expectedDigest.toString().toLowerCase()));

      // Validate Piece Hash access
      final piece0 = metadata.getPieceHash(0);
      expect(piece0, equals(dummyPieces.sublist(0, 20)));
      final piece2 = metadata.getPieceHash(2);
      expect(piece2, equals(dummyPieces.sublist(40, 60)));

      expect(() => metadata.getPieceHash(3), throwsA(isA<RangeError>()));
      expect(() => metadata.getPieceHash(-1), throwsA(isA<RangeError>()));
    });

    test('decodes multi-file torrent metainfo with announce-list tiers', () {
      final dummyPieces = Uint8List(40); // 2 pieces (2 * 20 bytes)
      final infoDict = <String, dynamic>{
        'name': 'Music Album',
        'piece length': 32768,
        'pieces': dummyPieces,
        'files': [
          {
            'length': 5000,
            'path': ['disc1', '01_track.mp3'],
          },
          {
            'length': 8000,
            'path': ['disc1', '02_track.mp3'],
          },
          {
            'length': 2000,
            'path': ['cover.jpg'],
          },
        ],
      };

      final rootDict = <String, dynamic>{
        'announce': 'http://tracker1.com/announce',
        'announce-list': [
          ['http://tracker1.com/announce', 'http://tracker1-backup.com/announce'],
          ['udp://tracker2.com:1337/announce'],
        ],
        'info': infoDict,
      };

      final encoded = Bencode.encode(rootDict);
      final metadata = Bencode.decodeTorrent(encoded);

      expect(metadata.name, equals('Music Album'));
      expect(metadata.totalSize, equals(15000));
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.files.length, equals(3));
      expect(metadata.files[0].path, equals('disc1/01_track.mp3'));
      expect(metadata.files[0].length, equals(5000));
      expect(metadata.files[1].path, equals('disc1/02_track.mp3'));
      expect(metadata.files[1].length, equals(8000));
      expect(metadata.files[2].path, equals('cover.jpg'));
      expect(metadata.files[2].length, equals(2000));

      expect(metadata.announceList.length, equals(2));
      expect(metadata.announceList[0], equals(['http://tracker1.com/announce', 'http://tracker1-backup.com/announce']));
      expect(metadata.announceList[1], equals(['udp://tracker2.com:1337/announce']));
    });

    test('throws FormatException on malformed torrent structures', () {
      // Not a dictionary
      expect(
        () => Bencode.decodeTorrent(Uint8List.fromList(ascii.encode('li1ee'))),
        throwsA(isA<FormatException>()),
      );

      // Missing info dictionary
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({'announce': 'http://example.com'}),
        ),
        throwsA(isA<FormatException>()),
      );

      // Invalid pieces length (not divisible by 20)
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid',
              'piece length': 16384,
              'pieces': Uint8List(25),
              'length': 100,
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );

      // Missing length and files
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'missing_size',
              'piece length': 16384,
              'pieces': Uint8List(20),
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on byte string path or invalid path list in multi-file torrent', () {
      // files is a byte string
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid_files',
              'piece length': 16384,
              'pieces': Uint8List(20),
              'files': 'not_a_list',
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );

      // path is a byte string instead of a list of path components
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid_path',
              'piece length': 16384,
              'pieces': Uint8List(20),
              'files': [
                {
                  'length': 1000,
                  'path': 'single_file.txt',
                },
              ],
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );

      // path contains non-string items
      expect(
        () => Bencode.decodeTorrent(
          Bencode.encode({
            'info': {
              'name': 'invalid_path_items',
              'piece length': 16384,
              'pieces': Uint8List(20),
              'files': [
                {
                  'length': 1000,
                  'path': [12345],
                },
              ],
            },
          }),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
