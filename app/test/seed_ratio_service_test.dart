import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTorrent extends Torrent {
  FakeTorrent({
    required super.id,
    super.status = TorrentStatus.seeding,
    super.downloadedEver = 0,
    super.uploadedEver = 0,
    super.size = 0,
    super.name = 'Test Torrent',
  }) : super(
          labels: const [],
          progress: 1.0,
          rateDownload: 0,
          rateUpload: 0,
          eta: 0,
          pieceCount: 0,
          pieces: const [],
          pieceSize: 0,
          errorString: '',
          location: '',
          isPrivate: false,
          addedDate: 0,
          creator: '',
          comment: '',
          files: const [],
          peersConnected: 0,
          magnetLink: '',
          sequentialDownload: false,
          speedLimitDownEnabled: false,
          speedLimitUpEnabled: false,
          speedLimitDown: 0,
          speedLimitUp: 0,
          doneDate: DateTime.fromMillisecondsSinceEpoch(0),
        );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockEngine implements Engine {
  final List<int> pausedIds = [];

  @override
  Future<void> pauseTorrent(int id) async {
    pausedIds.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SeedRatioService', () {
    late MockEngine mockEngine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SharedPrefsStorage.resetForTest();
      SeedRatioService.instance.resetForTest();

      mockEngine = MockEngine();
      if (getIt.isRegistered<Engine>()) {
        getIt.unregister<Engine>();
      }
      getIt.registerSingleton<Engine>(mockEngine);
    });

    tearDown(() {
      if (getIt.isRegistered<Engine>()) {
        getIt.unregister<Engine>();
      }
    });

    group('calculateRatio', () {
      test('Case 1: Standard download and seed uses uploadedEver / downloadedEver', () {
        final t = FakeTorrent(
          id: 1,
          downloadedEver: 1000,
          uploadedEver: 2000,
          size: 10000,
        );
        expect(SeedRatioService.calculateRatio(t), equals(2.0));
      });

      test('Case 2: Partial download uses downloadedEver as denominator', () {
        final t = FakeTorrent(
          id: 2,
          downloadedEver: 500,
          uploadedEver: 1500,
          size: 5000,
        );
        expect(SeedRatioService.calculateRatio(t), equals(3.0));
      });

      test('Case 3: Initial seeder (downloadedEver == 0) falls back to size', () {
        final t = FakeTorrent(
          id: 3,
          downloadedEver: 0,
          uploadedEver: 3000,
          size: 1500,
        );
        expect(SeedRatioService.calculateRatio(t), equals(2.0));
      });

      test('Case 4: Zero size and zero downloadedEver returns 0.0 safely', () {
        final t = FakeTorrent(
          id: 4,
          downloadedEver: 0,
          uploadedEver: 500,
          size: 0,
        );
        expect(SeedRatioService.calculateRatio(t), equals(0.0));
      });

      test('Case 5: Zero uploadedEver returns 0.0', () {
        final t = FakeTorrent(
          id: 5,
          downloadedEver: 1000,
          uploadedEver: 0,
          size: 1000,
        );
        expect(SeedRatioService.calculateRatio(t), equals(0.0));
      });

      test('Case 6: Negative/corrupted values safely return 0.0', () {
        final t = FakeTorrent(
          id: 6,
          downloadedEver: -10,
          uploadedEver: 50,
          size: -20,
        );
        expect(SeedRatioService.calculateRatio(t), equals(0.0));
      });
    });

    group('Goal Management & Persistence', () {
      test('Case 7: Set, get, has, and remove goals', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(1, 1.5);
        await service.setGoal(2, 2.0);

        expect(service.getGoal(1), equals(1.5));
        expect(service.hasGoal(1), isTrue);
        expect(service.getGoal(2), equals(2.0));
        expect(service.hasGoal(2), isTrue);
        expect(service.getGoal(3), isNull);
        expect(service.hasGoal(3), isFalse);

        await service.removeGoal(1);
        expect(service.getGoal(1), isNull);
        expect(service.hasGoal(1), isFalse);
        expect(service.getGoal(2), equals(2.0));
      });

      test('Case 8: Goals persist and reload from storage', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(42, 3.5);

        service.resetForTest();
        expect(service.getGoal(42), isNull);

        await service.load();
        expect(service.getGoal(42), equals(3.5));
      });

      test('Case 9: Handles corrupted json in SharedPreferences gracefully', () async {
        SharedPreferences.setMockInitialValues({
          'gravity_torrent_seed_ratio_goals': 'invalid-json-content{',
        });
        SharedPrefsStorage.resetForTest();

        final service = SeedRatioService.instance;
        service.resetForTest();

        await service.load();
        expect(service.getGoal(1), isNull);
      });
    });

    group('checkAndStop', () {
      test('Case 10: Pauses seeding torrent exceeding ratio goal', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(1, 1.5);

        final torrent1 = FakeTorrent(
          id: 1,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 1500,
        );

        await service.checkAndStop([torrent1]);
        expect(mockEngine.pausedIds, contains(1));
      });

      test('Case 11: Does not pause seeding torrent below goal', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(1, 2.0);

        final torrent1 = FakeTorrent(
          id: 1,
          status: TorrentStatus.seeding,
          downloadedEver: 1000,
          uploadedEver: 1500,
        );

        await service.checkAndStop([torrent1]);
        expect(mockEngine.pausedIds, isEmpty);
      });

      test('Case 12: Does not pause non-seeding torrent even if ratio exceeded', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(1, 1.0);

        final torrent1 = FakeTorrent(
          id: 1,
          status: TorrentStatus.downloading,
          downloadedEver: 500,
          uploadedEver: 1000,
        );

        await service.checkAndStop([torrent1]);
        expect(mockEngine.pausedIds, isEmpty);
      });

      test('Case 13: Ignores torrents listed in ignoredIds', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(1, 1.0);

        final torrent1 = FakeTorrent(
          id: 1,
          status: TorrentStatus.seeding,
          downloadedEver: 500,
          uploadedEver: 1000,
        );

        await service.checkAndStop([torrent1], {1});
        expect(mockEngine.pausedIds, isEmpty);
      });

      test('Case 14: Pauses initial seeder when uploadedEver / size >= goal', () async {
        final service = SeedRatioService.instance;
        await service.setGoal(2, 1.2);

        final torrent2 = FakeTorrent(
          id: 2,
          status: TorrentStatus.seeding,
          downloadedEver: 0,
          size: 1000,
          uploadedEver: 1300,
        );

        await service.checkAndStop([torrent2]);
        expect(mockEngine.pausedIds, contains(2));
      });
    });
  });
}
