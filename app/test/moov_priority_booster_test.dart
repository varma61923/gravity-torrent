import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/main.dart' as app_main;
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';

class MockEngine implements Engine {
  int? lastSequentialTorrentId;
  bool? lastSequentialValue;
  int? lastSpeedLimitTorrentId;
  int? lastDownloadLimit;
  int? lastUploadLimit;
  final List<String> callLog = [];
  Torrent Function(int id)? onFetchTorrent;

  @override
  Future<void> setTorrentSequentialDownload(int id, bool sequential) async {
    lastSequentialTorrentId = id;
    lastSequentialValue = sequential;
    callLog.add('setTorrentSequentialDownload($id, $sequential)');
  }

  @override
  Future<void> setTorrentSpeedLimit(
    int id, {
    int? downloadLimit,
    int? uploadLimit,
  }) async {
    lastSpeedLimitTorrentId = id;
    lastDownloadLimit = downloadLimit;
    lastUploadLimit = uploadLimit;
    callLog.add('setTorrentSpeedLimit($id, dl: $downloadLimit)');
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    callLog.add('fetchTorrent($id)');
    if (onFetchTorrent != null) {
      return onFetchTorrent!(id);
    }
    throw UnimplementedError();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTorrent extends Torrent {
  final List<String> filePriorityCalls = [];
  int? sequentialFromPiece;

  FakeTorrent({
    required super.id,
    required super.name,
    required super.pieceCount,
    required super.pieceSize,
    required super.pieces,
    required super.files,
    required super.speedLimitDownEnabled,
    required super.speedLimitDown,
    super.labels,
    super.progress = 0.0,
    super.status = TorrentStatus.downloading,
    super.size = 1000000,
    super.rateDownload = 0,
    super.rateUpload = 0,
    super.downloadedEver = 0,
    super.uploadedEver = 0,
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
    super.speedLimitUpEnabled = false,
    super.speedLimitUp = 0,
    DateTime? doneDate,
  }) : super(doneDate: doneDate ?? DateTime.now());

  @override
  Future<void> setFilesPriority({
    List<int>? priorityHigh,
    List<int>? priorityLow,
    List<int>? priorityNormal,
  }) async {
    if (priorityHigh != null) {
      filePriorityCalls.add('high: $priorityHigh');
    }
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int piece) async {
    sequentialFromPiece = piece;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockEngine mockEngine;

  setUp(() {
    mockEngine = MockEngine();
    if (getIt.isRegistered<Engine>()) {
      getIt.unregister<Engine>();
    }
    getIt.registerSingleton<Engine>(mockEngine);
    app_main.engine = mockEngine;
    MoovPriorityBooster.resetForTest();
  });

  tearDown(() {
    MoovPriorityBooster.resetForTest();
  });

  group('MoovPriorityBooster Boundary Validation', () {
    test('aborts early if pieceSize is <= 0', () async {
      final fakeTorrent = FakeTorrent(
        id: 1,
        name: 'Zero Piece Size',
        pieceCount: 100,
        pieceSize: 0,
        pieces: List.filled(100, false),
        files: [
          torrent_file.File(
            name: 'video.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 0,
            endPiece: 10,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 500,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      expect(
        mockEngine.callLog,
        equals(['setTorrentSequentialDownload(1, true)']),
      );
      expect(mockEngine.lastSpeedLimitTorrentId, isNull);
    });

    test('aborts early if startPiece < 0 or startPiece > endPiece', () async {
      final fakeTorrent = FakeTorrent(
        id: 2,
        name: 'Invalid Piece Bounds',
        pieceCount: 100,
        pieceSize: 16384,
        pieces: List.filled(100, false),
        files: [
          torrent_file.File(
            name: 'invalid.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 20,
            endPiece: 10, // start > end
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 500,
      );

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      expect(mockEngine.lastSpeedLimitTorrentId, isNull);
    });

    test('clamps endPiece to pieceCount - 1', () async {
      final fakeTorrent = FakeTorrent(
        id: 3,
        name: 'Clamped Pieces',
        pieceCount: 50,
        pieceSize: 16384,
        pieces: List.filled(50, true), // all loaded
        files: [
          torrent_file.File(
            name: 'clamped.mp4',
            length: 1000,
            bytesCompleted: 0,
            wanted: true,
            beginPiece: 0,
            endPiece: 100, // exceeds pieceCount
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 300,
      );

      mockEngine.onFetchTorrent = (id) => fakeTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      expect(fakeTorrent.sequentialFromPiece, equals(0));
      expect(fakeTorrent.filePriorityCalls, equals(['high: [0]']));
    });
  });

  group('Speed Limit Restoration Logic & Non-Clobbering', () {
    test(
        'disables limit on start and restores when pieces are loaded (if enabled)',
        () async {
      final fakeTorrent = FakeTorrent(
        id: 10,
        name: 'Restore Limit',
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true), // loaded
        files: [
          torrent_file.File(
            name: 'movie.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 0,
            endPiece: 19,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 1000,
      );

      // Live torrent returned has speedLimitDownEnabled = false (waiting to be restored)
      final liveTorrent = FakeTorrent(
        id: 10,
        name: 'Restore Limit',
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: fakeTorrent.files,
        speedLimitDownEnabled: false, // still disabled by booster
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => liveTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      // Allow unawaited async completion
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockEngine.callLog, contains('setTorrentSpeedLimit(10, dl: 0)'));
      expect(
        mockEngine.callLog,
        contains('setTorrentSpeedLimit(10, dl: 1000)'),
      );
    });

    test(
        'does NOT disable or restore speed limit if speed limit was originally disabled',
        () async {
      final fakeTorrent = FakeTorrent(
        id: 11,
        name: 'No Limit',
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: [
          torrent_file.File(
            name: 'movie.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 0,
            endPiece: 19,
          ),
        ],
        speedLimitDownEnabled: false,
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => fakeTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        mockEngine.callLog
            .where((c) => c.startsWith('setTorrentSpeedLimit')),
        isEmpty,
      );
    });

    test(
        'does NOT clobber user-modified speed limits configured during buffering',
        () async {
      final fakeTorrent = FakeTorrent(
        id: 12,
        name: 'User Modified',
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: [
          torrent_file.File(
            name: 'movie.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 0,
            endPiece: 19,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 1000,
      );

      // Suppose user explicitly set download limit to 250 while buffering
      final liveUserModifiedTorrent = FakeTorrent(
        id: 12,
        name: 'User Modified',
        pieceCount: 20,
        pieceSize: 16384,
        pieces: List.filled(20, true),
        files: fakeTorrent.files,
        speedLimitDownEnabled: true, // User re-enabled it!
        speedLimitDown: 250,
      );

      mockEngine.onFetchTorrent = (id) => liveUserModifiedTorrent;

      await MoovPriorityBooster.boostForStreaming(
        torrent: fakeTorrent,
        file: fakeTorrent.files.first,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockEngine.callLog, contains('setTorrentSpeedLimit(12, dl: 0)'));
      // Should NOT contain restoration of stale 1000
      expect(
        mockEngine.callLog
            .where((c) => c == 'setTorrentSpeedLimit(12, dl: 1000)'),
        isEmpty,
      );
    });

    test(
        'handles overlapping / concurrent boost requests on same torrent safely',
        () async {
      final fakeTorrent = FakeTorrent(
        id: 13,
        name: 'Concurrent Boost',
        pieceCount: 50,
        pieceSize: 16384,
        pieces: List.filled(50, true),
        files: [
          torrent_file.File(
            name: 'track1.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 0,
            endPiece: 20,
          ),
          torrent_file.File(
            name: 'track2.mp4',
            length: 327680,
            bytesCompleted: 327680,
            wanted: true,
            beginPiece: 21,
            endPiece: 40,
          ),
        ],
        speedLimitDownEnabled: true,
        speedLimitDown: 800,
      );

      final liveTorrent = FakeTorrent(
        id: 13,
        name: 'Concurrent Boost',
        pieceCount: 50,
        pieceSize: 16384,
        pieces: List.filled(50, true),
        files: fakeTorrent.files,
        speedLimitDownEnabled: false,
        speedLimitDown: 0,
      );

      mockEngine.onFetchTorrent = (id) => liveTorrent;

      // Trigger two concurrent boosts
      await Future.wait([
        MoovPriorityBooster.boostForStreaming(
          torrent: fakeTorrent,
          file: fakeTorrent.files[0],
        ),
        MoovPriorityBooster.boostForStreaming(
          torrent: fakeTorrent,
          file: fakeTorrent.files[1],
        ),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Limit should only be restored once both complete
      final restoreCalls = mockEngine.callLog
          .where((c) => c == 'setTorrentSpeedLimit(13, dl: 800)')
          .toList();
      expect(restoreCalls.length, equals(1));
    });
  });
}
