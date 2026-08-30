import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart';
import 'package:gravity_torrent/engine/transmission/transmission.dart';

void main() {
  group('TransmissionTorrentModel scale & piece bounds', () {
    test('supports swarms with >1,000,000 pieces without clamping', () {
      const largePieceCount = 1500000;
      final model = TransmissionTorrentModel.fromJson({
        'id': 1,
        'name': 'Large Swarm',
        'pieceCount': largePieceCount,
        'pieces': '',
      });

      expect(model.pieceCount, equals(largePieceCount));
      expect(model.pieces.length, equals(largePieceCount));
      expect(model.pieces.every((p) => p == false), isTrue);
    });

    test('decodes large bitfield correctly across the 1,000,000 boundary', () {
      const pieceCount = 1200000;
      // 1,200,000 bits = 150,000 bytes
      const numBytes = (pieceCount + 7) ~/ 8;
      final bitfieldBytes = Uint8List(numBytes);

      // Set specific bits:
      // Piece 0: byte 0, bit 7 (0x80)
      bitfieldBytes[0] |= 0x80;
      // Piece 7: byte 0, bit 0 (0x01)
      bitfieldBytes[0] |= 0x01;
      // Piece 999,999: byte 124,999, bit 0 (999999 % 8 = 7 -> bit 0)
      const byte999k = 999999 ~/ 8;
      const bit999k = 7 - (999999 % 8);
      bitfieldBytes[byte999k] |= (1 << bit999k);
      // Piece 1,000,000: byte 125,000, bit 7
      const byte1m = 1000000 ~/ 8;
      const bit1m = 7 - (1000000 % 8);
      bitfieldBytes[byte1m] |= (1 << bit1m);
      // Piece 1,199,999 (last piece): byte 149,999, bit 0
      const byteLast = 1199999 ~/ 8;
      const bitLast = 7 - (1199999 % 8);
      bitfieldBytes[byteLast] |= (1 << bitLast);

      final base64Bitfield = base64Encode(bitfieldBytes);

      final model = TransmissionTorrentModel.fromJson({
        'id': 2,
        'name': 'Large Bitfield Torrent',
        'pieceCount': pieceCount,
        'pieces': base64Bitfield,
      });

      expect(model.pieceCount, equals(pieceCount));
      expect(model.pieces.length, equals(pieceCount));
      expect(model.pieces[0], isTrue);
      expect(model.pieces[7], isTrue);
      expect(model.pieces[8], isFalse);
      expect(model.pieces[999999], isTrue);
      expect(model.pieces[1000000], isTrue);
      expect(model.pieces[1000001], isFalse);
      expect(model.pieces[1199999], isTrue);
    });

    test('defensively clamps negative pieceCount to 0', () {
      final modelNegative = TransmissionTorrentModel.fromJson({
        'id': 3,
        'pieceCount': -100,
        'pieces': null,
      });

      expect(modelNegative.pieceCount, equals(0));
      expect(modelNegative.pieces, isEmpty);

      final modelNegativeWithPieces = TransmissionTorrentModel.fromJson({
        'id': 4,
        'pieceCount': -1,
        'pieces': base64Encode(Uint8List.fromList([255])),
      });

      expect(modelNegativeWithPieces.pieceCount, equals(0));
      expect(modelNegativeWithPieces.pieces, isEmpty);
    });

    test('handles zero, missing, and null pieceCount gracefully', () {
      final modelZero = TransmissionTorrentModel.fromJson({
        'id': 5,
        'pieceCount': 0,
      });
      expect(modelZero.pieceCount, equals(0));
      expect(modelZero.pieces, isEmpty);

      final modelMissing = TransmissionTorrentModel.fromJson({
        'id': 6,
      });
      expect(modelMissing.pieceCount, equals(0));
      expect(modelMissing.pieces, isEmpty);

      final modelNull = TransmissionTorrentModel.fromJson({
        'id': 7,
        'pieceCount': null,
        'pieces': null,
      });
      expect(modelNull.pieceCount, equals(0));
      expect(modelNull.pieces, isEmpty);
    });

    test('handles truncated bitfields with large pieceCount safely', () {
      const pieceCount = 2000000;
      // Only 2 bytes (16 bits) supplied
      final truncatedBytes = Uint8List.fromList([0xFF, 0x80]);
      final base64Truncated = base64Encode(truncatedBytes);

      final model = TransmissionTorrentModel.fromJson({
        'id': 8,
        'pieceCount': pieceCount,
        'pieces': base64Truncated,
      });

      expect(model.pieceCount, equals(pieceCount));
      expect(model.pieces.length, equals(pieceCount));
      expect(model.pieces[0], isTrue);
      expect(model.pieces[7], isTrue);
      expect(model.pieces[8], isTrue);
      expect(model.pieces[9], isFalse);
      expect(model.pieces[1999999], isFalse);
    });

    test('handles invalid base64 bitfield string gracefully with large pieceCount', () {
      const pieceCount = 1500000;
      final model = TransmissionTorrentModel.fromJson({
        'id': 9,
        'pieceCount': pieceCount,
        'pieces': '!!!not-a-valid-base64-string!!!',
      });

      expect(model.pieceCount, equals(pieceCount));
      expect(model.pieces.length, equals(pieceCount));
      expect(model.pieces.every((p) => p == false), isTrue);
    });

    test('verifies integration with hasLoadedPieces for piece indices > 1,000,000', () {
      const pieceCount = 2000000;
      const numBytes = (pieceCount + 7) ~/ 8;
      final bitfieldBytes = Uint8List(numBytes);

      // Set piece 0 and piece 1,500,000 to true
      bitfieldBytes[0] |= 0x80;
      const byte1_5m = 1500000 ~/ 8;
      const bit1_5m = 7 - (1500000 % 8);
      bitfieldBytes[byte1_5m] |= (1 << bit1_5m);

      final model = TransmissionTorrentModel.fromJson({
        'id': 10,
        'name': 'Large Integration Torrent',
        'pieceCount': pieceCount,
        'pieces': base64Encode(bitfieldBytes),
      });

      final torrent = createTransmissionTorrentFromJson(model);

      expect(torrent.pieceCount, equals(pieceCount));
      expect(torrent.pieces.length, equals(pieceCount));

      // Loaded pieces
      expect(torrent.hasLoadedPieces([0]), isTrue);
      expect(torrent.hasLoadedPieces([1500000]), isTrue);
      expect(torrent.hasLoadedPieces([0, 1500000]), isTrue);

      // Unloaded pieces
      expect(torrent.hasLoadedPieces([1]), isFalse);
      expect(torrent.hasLoadedPieces([1500001]), isFalse);
      expect(torrent.hasLoadedPieces([0, 1500001]), isFalse);

      // Out of bounds
      expect(torrent.hasLoadedPieces([2000000]), isFalse);
      expect(torrent.hasLoadedPieces([-1]), isFalse);

      // Empty query
      expect(torrent.hasLoadedPieces([]), isTrue);
    });
  });
}
