import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_libtransmission/flutter_libtransmission.dart'
    as flutter_libtransmission;
import 'package:path_provider/path_provider.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/session.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/session_get_request.dart';
import 'package:gravity_torrent/engine/transmission/models/session_get_response.dart';
import 'package:gravity_torrent/engine/transmission/models/session_set_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_action_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_add_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_add_response.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_get_request.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_get_response.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_remove_request.dart';
import 'package:path/path.dart' as path;
import 'package:gravity_torrent/engine/transmission/models/torrent_set_location.dart';
import 'package:gravity_torrent/engine/transmission/models/torrent_set_request.dart';
import 'package:gravity_torrent/platforms/android/default_session.dart'
    as android;
import 'package:gravity_torrent/platforms/ios/default_session.dart' as ios;

Future<Directory> getConfigDir() async {
  final configDir = path.join(
    (await getApplicationSupportDirectory()).path,
    'transmission',
  );
  return Directory(configDir);
}

void _requestEngineCheckpoint() {
  if (getIt.isRegistered<Engine>()) {
    getIt<Engine>().requestCheckpoint();
  }
}

const torrentGetFields = [
  TorrentField.id,
  TorrentField.name,
  TorrentField.percentDone,
  TorrentField.status,
  TorrentField.totalSize,
  TorrentField.rateDownload,
  TorrentField.rateUpload,
  TorrentField.labels,
  TorrentField.addedDate,
  TorrentField.errorString,
  TorrentField.isPrivate,
  TorrentField.downloadDir,
  TorrentField.files,
  TorrentField.fileStats,
  TorrentField.downloadedEver,
  TorrentField.uploadedEver,
  TorrentField.eta,
  TorrentField.pieces,
  TorrentField.pieceSize,
  TorrentField.pieceCount,
  TorrentField.comment,
  TorrentField.creator,
  TorrentField.peersConnected,
  TorrentField.magnetLink,
  TorrentField.sequentialDownload,
  TorrentField.speedLimitDownEnabled,
  TorrentField.speedLimitUpEnabled,
  TorrentField.speedLimitDown,
  TorrentField.speedLimitUp,
  TorrentField.doneDate,
  TorrentField.leftUntilDone,
  TorrentField.sizeWhenDone,
  TorrentField.seedRatioMode,
  TorrentField.seedRatioLimit,
  TorrentField.seedIdleMode,
  TorrentField.seedIdleLimit,
  TorrentField.honorsSessionLimits,
  TorrentField.queuePosition,
];

TransmissionTorrent createTransmissionTorrentFromJson(
  TransmissionTorrentModel torrent,
) {
  return TransmissionTorrent(
    id: torrent.id,
    name: torrent.name,
    progress: torrent.sizeWhenDone > 0
        ? ((torrent.sizeWhenDone - torrent.leftUntilDone) /
                torrent.sizeWhenDone)
            .clamp(0.0, 1.0)
        : torrent.percentDone,
    status: torrent.status,
    size: torrent.totalSize,
    rateDownload: torrent.rateDownload,
    rateUpload: torrent.rateUpload,
    labels: torrent.labels,
    addedDate: torrent.addedDate,
    errorString: torrent.errorString,
    magnetLink: torrent.magnetLink,
    isPrivate: torrent.isPrivate,
    location: torrent.location,
    files: torrent.files
        .asMap()
        .entries
        .map(
          (entry) => torrent_file.File(
            name: entry.value.name,
            length: entry.value.length,
            bytesCompleted: entry.value.bytesCompleted,
            // fileStats and files are parallel arrays; guard against a
            // transient length mismatch to avoid a RangeError.
            wanted: entry.key < torrent.fileStats.length
                ? torrent.fileStats[entry.key].wanted
                : true,
            beginPiece: entry.value.beginPiece,
            endPiece: entry.value.endPiece,
          ),
        )
        .toList(),
    downloadedEver: torrent.downloadedEver,
    uploadedEver: torrent.uploadedEver,
    eta: torrent.eta,
    pieces: torrent.pieces,
    pieceCount: torrent.pieceCount,
    pieceSize: torrent.pieceSize,
    comment: torrent.comment,
    creator: torrent.creator,
    peersConnected: torrent.peersConnected,
    sequentialDownload: torrent.sequentialDownload,
    speedLimitDownEnabled: torrent.speedLimitDownEnabled,
    speedLimitUpEnabled: torrent.speedLimitUpEnabled,
    speedLimitDown: torrent.speedLimitDown,
    speedLimitUp: torrent.speedLimitUp,
    doneDate: torrent.doneDate,
    seedRatioMode: torrent.seedRatioMode,
    seedRatioLimit: torrent.seedRatioLimit,
    seedIdleMode: torrent.seedIdleMode,
    seedIdleLimit: torrent.seedIdleLimit,
    honorsSessionLimits: torrent.honorsSessionLimits,
    queuePosition: torrent.queuePosition,
  );
}

final TorrentGetRequest torrentGetRequest = TorrentGetRequest(
  arguments: TorrentGetRequestArguments(
    fields: [
      TorrentField.id,
      TorrentField.name,
      TorrentField.percentDone,
      TorrentField.status,
      TorrentField.totalSize,
      TorrentField.rateDownload,
      TorrentField.rateUpload,
      TorrentField.labels,
      TorrentField.addedDate,
      TorrentField.errorString,
      TorrentField.isPrivate,
      TorrentField.downloadDir,
      TorrentField.files,
      TorrentField.fileStats,
      TorrentField.downloadedEver,
      TorrentField.uploadedEver,
      TorrentField.eta,
      TorrentField.pieces,
      TorrentField.pieceSize,
      TorrentField.pieceCount,
      TorrentField.comment,
      TorrentField.creator,
      TorrentField.peersConnected,
      TorrentField.magnetLink,
      TorrentField.sequentialDownload,
      TorrentField.speedLimitDownEnabled,
      TorrentField.speedLimitUpEnabled,
      TorrentField.speedLimitDown,
      TorrentField.speedLimitUp,
      TorrentField.doneDate,
      TorrentField.seedRatioMode,
      TorrentField.seedRatioLimit,
      TorrentField.seedIdleMode,
      TorrentField.seedIdleLimit,
      TorrentField.honorsSessionLimits,
      TorrentField.queuePosition,
    ],
  ),
);

class TransmissionTorrent extends Torrent {
  final int seedRatioMode;
  final double seedRatioLimit;
  final int seedIdleMode;
  final int seedIdleLimit;
  final bool honorsSessionLimits;
  final int queuePosition;

  TransmissionTorrent({
    required super.id,
    required super.name,
    required super.progress,
    required super.status,
    required super.size,
    required super.rateDownload,
    required super.rateUpload,
    required super.downloadedEver,
    required super.uploadedEver,
    required super.eta,
    required super.pieces,
    required super.pieceCount,
    required super.pieceSize,
    required super.errorString,
    required super.addedDate,
    required super.isPrivate,
    required super.location,
    required super.creator,
    required super.comment,
    required super.files,
    required super.labels,
    required super.peersConnected,
    required super.magnetLink,
    required super.sequentialDownload,
    required super.speedLimitDownEnabled,
    required super.speedLimitUpEnabled,
    required super.speedLimitDown,
    required super.speedLimitUp,
    required super.doneDate,
    this.seedRatioMode = 0,
    this.seedRatioLimit = 0.0,
    this.seedIdleMode = 0,
    this.seedIdleLimit = 0,
    this.honorsSessionLimits = true,
    this.queuePosition = -1,
  });

  @override
  Future<void> start() async {
    final request = TorrentActionRequest(
      action: TorrentAction.start,
      arguments: TorrentActionRequestArguments(ids: [id]),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> stop() async {
    final request = TorrentActionRequest(
      action: TorrentAction.stop,
      arguments: TorrentActionRequestArguments(ids: [id]),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> startNow() async {
    final request = TorrentActionRequest(
      action: TorrentAction.startNow,
      arguments: TorrentActionRequestArguments(ids: [id]),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> verify() async {
    final request = TorrentActionRequest(
      action: TorrentAction.verify,
      arguments: TorrentActionRequestArguments(ids: [id]),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> reannounce() async {
    final request = TorrentActionRequest(
      action: TorrentAction.reannounce,
      arguments: TorrentActionRequestArguments(ids: [id]),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> remove(bool withData) async {
    final request = TorrentRemoveRequest(
      arguments: TorrentRemoveRequestArguments(
        ids: [id],
        deleteLocalData: withData,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    await super.remove(withData);
    _requestEngineCheckpoint();
  }

  @override
  Future<void> update(TorrentBase torrent) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(ids: [id], labels: torrent.labels),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    if (torrent.labels != null) {
      labels = torrent.labels;
    }
    _requestEngineCheckpoint();
  }

  @override
  Future<void> toggleFileWanted(int fileIndex, bool wanted) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        filesWanted: wanted ? [fileIndex] : null,
        filesUnwanted: !wanted ? [fileIndex] : null,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> toggleAllFilesWanted(bool wanted) async {
    final allFileIndexes =
        files.indexed.map((indexedElement) => indexedElement.$1).toList();

    final request = TorrentSetRequest(
      arguments: wanted
          ? TorrentSetRequestArguments(ids: [id], filesWanted: allFileIndexes)
          : TorrentSetRequestArguments(
              ids: [id],
              filesUnwanted: allFileIndexes,
            ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setFilesWanted(List<int> fileIndices, bool wanted) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        filesWanted: wanted ? fileIndices : null,
        filesUnwanted: !wanted ? fileIndices : null,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSequentialDownload(bool sequential) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        sequentialDownload: sequential,
      ),
    );

    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSequentialDownloadFromPiece(int piece) async {
    debugPrint('setSequentialDownloadFromPiece $piece');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        sequentialDownloadFromPiece: piece,
      ),
    );

    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSpeedLimits({
    required bool downloadEnabled,
    required bool uploadEnabled,
    int? downloadLimitKbps,
    int? uploadLimitKbps,
  }) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        speedLimitDownEnabled: downloadEnabled,
        speedLimitUpEnabled: uploadEnabled,
        speedLimitDown: downloadEnabled ? downloadLimitKbps : null,
        speedLimitUp: uploadEnabled ? uploadLimitKbps : null,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setFilesPriority({
    List<int>? priorityHigh,
    List<int>? priorityLow,
    List<int>? priorityNormal,
  }) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        priorityHigh: priorityHigh,
        priorityLow: priorityLow,
        priorityNormal: priorityNormal,
      ),
    );

    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSeedRatioMode(int mode) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedRatioMode: mode,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSeedRatioLimit(double limit) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedRatioLimit: limit,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSeedIdleMode(int mode) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedIdleMode: mode,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setSeedIdleLimit(int limit) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedIdleLimit: limit,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setHonorsSessionLimits(bool honors) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        honorsSessionLimits: honors,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setQueuePosition(int position) async {
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        queuePosition: position,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }

  @override
  Future<void> setPriorityPieces(List<int> pieceIndices, int priority) async {
    TorrentSetRequestArguments args;
    if (priority > 0) {
      args = TorrentSetRequestArguments(ids: [id], priorityHigh: pieceIndices);
    } else if (priority < 0) {
      args = TorrentSetRequestArguments(ids: [id], priorityLow: pieceIndices);
    } else {
      args =
          TorrentSetRequestArguments(ids: [id], priorityNormal: pieceIndices);
    }
    final request = TorrentSetRequest(arguments: args);
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    _requestEngineCheckpoint();
  }
}

class TransmissionSession extends Session {
  TransmissionSession({
    super.downloadDir,
    super.downloadQueueEnabled,
    super.downloadQueueSize,
    super.uploadQueueEnabled,
    super.uploadQueueSize,
    super.peerPort,
    super.speedLimitDownEnabled,
    super.speedLimitUpEnabled,
    super.speedLimitDown,
    super.speedLimitUp,
    super.seedRatioLimit,
    super.seedRatioLimited,
    super.encryption,
    super.blocklistEnabled,
    super.blocklistUrl,
    super.blocklistSize,
    super.dhtEnabled,
    super.pexEnabled,
    super.lpdEnabled,
    super.utpEnabled,
    super.altSpeedEnabled,
    super.altSpeedDown,
    super.altSpeedUp,
    super.altSpeedTimeEnabled,
    super.altSpeedTimeBegin,
    super.altSpeedTimeEnd,
    super.altSpeedTimeDay,
    super.idleSeedingLimitEnabled,
    super.idleSeedingLimit,
    super.ignoreLimitsOnLAN,
    super.includeOverheadInLimits,
  });

  @override
  Future<void> update(SessionBase session) async {
    final SessionSetRequest request = SessionSetRequest(
      arguments: SessionSetRequestArguments(
        downloadDir: session.downloadDir,
        downloadQueueEnabled: session.downloadQueueEnabled,
        downloadQueueSize: session.downloadQueueSize,
        uploadQueueEnabled: session.uploadQueueEnabled,
        uploadQueueSize: session.uploadQueueSize,
        peerPort: session.peerPort,
        speedLimitDownEnabled: session.speedLimitDownEnabled,
        speedLimitUpEnabled: session.speedLimitUpEnabled,
        speedLimitDown: session.speedLimitDown,
        speedLimitUp: session.speedLimitUp,
        seedRatioLimit: session.seedRatioLimit,
        seedRatioLimited: session.seedRatioLimited,
        encryption: session.encryption?.rpcValue,
        blocklistEnabled: session.blocklistEnabled,
        blocklistUrl: session.blocklistUrl,
        dhtEnabled: session.dhtEnabled,
        pexEnabled: session.pexEnabled,
        lpdEnabled: session.lpdEnabled,
        utpEnabled: session.utpEnabled,
        altSpeedEnabled: session.altSpeedEnabled,
        altSpeedDown: session.altSpeedDown,
        altSpeedUp: session.altSpeedUp,
        altSpeedTimeEnabled: session.altSpeedTimeEnabled,
        altSpeedTimeBegin: session.altSpeedTimeBegin,
        altSpeedTimeEnd: session.altSpeedTimeEnd,
        altSpeedTimeDay: session.altSpeedTimeDay,
        idleSeedingLimitEnabled: session.idleSeedingLimitEnabled,
        idleSeedingLimit: session.idleSeedingLimit,
        ignoreLimitsOnLAN: session.ignoreLimitsOnLAN,
        includeOverheadInLimits: session.includeOverheadInLimits,
      ),
    );

    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    if (getIt.isRegistered<Engine>()) {
      await getIt<Engine>().saveSession();
    }
    if (session.downloadDir != null) {
      downloadDir = session.downloadDir;
    }
    if (session.downloadQueueEnabled != null) {
      downloadQueueEnabled = session.downloadQueueEnabled;
    }
    if (session.downloadQueueSize != null) {
      downloadQueueSize = session.downloadQueueSize;
    }
    if (session.uploadQueueEnabled != null) {
      uploadQueueEnabled = session.uploadQueueEnabled;
    }
    if (session.uploadQueueSize != null) {
      uploadQueueSize = session.uploadQueueSize;
    }
    if (session.peerPort != null) {
      peerPort = session.peerPort;
    }
    if (session.speedLimitDownEnabled != null) {
      speedLimitDownEnabled = session.speedLimitDownEnabled;
    }
    if (session.speedLimitUpEnabled != null) {
      speedLimitUpEnabled = session.speedLimitUpEnabled;
    }
    if (session.speedLimitDown != null) {
      speedLimitDown = session.speedLimitDown;
    }
    if (session.speedLimitUp != null) {
      speedLimitUp = session.speedLimitUp;
    }
    if (session.seedRatioLimit != null) {
      seedRatioLimit = session.seedRatioLimit;
    }
    if (session.seedRatioLimited != null) {
      seedRatioLimited = session.seedRatioLimited;
    }
    if (session.encryption != null) {
      encryption = session.encryption;
    }
    if (session.blocklistEnabled != null) {
      blocklistEnabled = session.blocklistEnabled;
    }
    if (session.blocklistUrl != null) {
      blocklistUrl = session.blocklistUrl;
    }
    if (session.blocklistSize != null) {
      blocklistSize = session.blocklistSize;
    }
    if (session.dhtEnabled != null) {
      dhtEnabled = session.dhtEnabled;
    }
    if (session.pexEnabled != null) {
      pexEnabled = session.pexEnabled;
    }
    if (session.lpdEnabled != null) {
      lpdEnabled = session.lpdEnabled;
    }
    if (session.utpEnabled != null) {
      utpEnabled = session.utpEnabled;
    }
    if (session.altSpeedEnabled != null) {
      altSpeedEnabled = session.altSpeedEnabled;
    }
    if (session.altSpeedDown != null) {
      altSpeedDown = session.altSpeedDown;
    }
    if (session.altSpeedUp != null) {
      altSpeedUp = session.altSpeedUp;
    }
    if (session.altSpeedTimeEnabled != null) {
      altSpeedTimeEnabled = session.altSpeedTimeEnabled;
    }
    if (session.altSpeedTimeBegin != null) {
      altSpeedTimeBegin = session.altSpeedTimeBegin;
    }
    if (session.altSpeedTimeEnd != null) {
      altSpeedTimeEnd = session.altSpeedTimeEnd;
    }
    if (session.altSpeedTimeDay != null) {
      altSpeedTimeDay = session.altSpeedTimeDay;
    }
    if (session.idleSeedingLimitEnabled != null) {
      idleSeedingLimitEnabled = session.idleSeedingLimitEnabled;
    }
    if (session.idleSeedingLimit != null) {
      idleSeedingLimit = session.idleSeedingLimit;
    }
    if (session.ignoreLimitsOnLAN != null) {
      ignoreLimitsOnLAN = session.ignoreLimitsOnLAN;
    }
    if (session.includeOverheadInLimits != null) {
      includeOverheadInLimits = session.includeOverheadInLimits;
    }
  }
}

void _expectSuccess(String raw) {
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final result = decoded['result'] as String? ?? '';
    if (result != 'success') {
      throw TransmissionRpcError(result);
    }
  } on FormatException catch (e) {
    throw TransmissionRpcError('invalid response: $e');
  } on TypeError catch (e) {
    throw TransmissionRpcError('invalid response: $e');
  }
}

List<Torrent> _parseTorrentsResponse(String res) {
  final TorrentGetResponse decodedRes;
  try {
    decodedRes = TorrentGetResponse.fromJson(
      (jsonDecode(res) as Map<String, dynamic>),
    );
  } catch (e) {
    throw TransmissionRpcError('Invalid fetch torrents response: $e');
  }
  if (decodedRes.result != 'success') {
    throw TransmissionRpcError(decodedRes.result);
  }
  return decodedRes.arguments.torrents
      .map((torrent) {
        try {
          return createTransmissionTorrentFromJson(torrent);
        } catch (e, stack) {
          debugPrint('Failed to parse torrent: $e\n$stack');
          return null;
        }
      })
      .whereType<Torrent>()
      .toList();
}

class TransmissionEngine extends Engine {
  Timer? _checkpointTimer;
  Timer? _saveDebounce;
  bool _closed = false;
  Future<void>? _activeSave;

  void startCheckpointTimer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        await saveSession();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('TransmissionEngine checkpoint failed: $e\n$s');
        }
      }
    });
  }

  @override
  void requestCheckpoint() {
    if (_closed) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), () async {
      try {
        await saveSession();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('TransmissionEngine checkpoint failed: $e\n$s');
        }
      }
    });
  }

  Future<void> _initDefaultDesktopDownloadDir() async {
    try {
      final session = await fetchSession();
      if (session.downloadDir != null && session.downloadDir!.isNotEmpty) {
        return;
      }
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        if (!downloadsDir.existsSync()) {
          downloadsDir.createSync(recursive: true);
        }
        await session.update(SessionBase(downloadDir: downloadsDir.path));
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint(
          'TransmissionEngine _initDefaultDesktopDownloadDir failed: $e\n$s',
        );
      }
    }
  }

  @override
  Future<void> init() async {
    _closed = false;
    final configDir = await getConfigDir();
    flutter_libtransmission.initSession(configDir.path);
    if (Platform.isAndroid) {
      await android.initDefaultDownloadDir(this);
    }

    if (Platform.isIOS) {
      await ios.initDefaultDownloadDir(this);
      // Once done, restart session to reload torrents in error state
      await shutdown();
      flutter_libtransmission.initSession(configDir.path);
      _closed = false;
    }

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      await _initDefaultDesktopDownloadDir();
    }

    startCheckpointTimer();

    try {
      final keys = await SharedPrefsStorage.getKeys();
      for (final key in keys) {
        if (key.startsWith('streaming_active_')) {
          final idString = key.substring('streaming_active_'.length);
          final id = int.tryParse(idString);
          if (id != null) {
            try {
              final torrent = await fetchTorrent(id);
              await torrent.stopStreaming();
            } catch (e) {
              if (kDebugMode) {
                debugPrint('Failed to stop streaming for $id at init: $e');
              }
              await SharedPrefsStorage.remove(key);
            }
          } else {
            await SharedPrefsStorage.remove(key);
          }
        }
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('TransmissionEngine init streaming cleanup failed: $e\n$s');
      }
    }
  }

  @override
  Future<void> saveSession() async {
    if (_closed) return;
    final previousSave = _activeSave;
    final completer = Completer<void>();
    _activeSave = completer.future;

    try {
      if (previousSave != null) {
        await previousSave.catchError((_) {});
      }
      if (_closed) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      flutter_libtransmission.saveSettings();
      if (!completer.isCompleted) completer.complete();
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
      rethrow;
    } finally {
      if (_activeSave == completer.future) {
        _activeSave = null;
      }
    }
  }

  @override
  Future<void> shutdown() async {
    if (_closed) return;
    _checkpointTimer?.cancel();
    _saveDebounce?.cancel();
    try {
      // Flush settings before marking the engine closed so saveSession()
      // actually writes to disk.
      await saveSession();
    } catch (e) {
      // Ignore save errors during shutdown.
      if (kDebugMode) debugPrint('TransmissionEngine shutdown save failed: $e');
    }
    _closed = true;
    try {
      final pendingSave = _activeSave;
      if (pendingSave != null) {
        await pendingSave.catchError((_) {});
      }
      await Isolate.run(() => flutter_libtransmission.closeSession());
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TransmissionEngine shutdown Isolate.run failed: $e\n$st');
      }
    }
  }

  @override
  Future<TorrentAddedResponse> addTorrent(
    String? filename,
    String? metainfo,
    String? downloadDir,
  ) async {
    if (_closed) throw StateError('Engine is closed');
    final torrentAddRequest = TorrentAddRequest(
      arguments: TorrentAddRequestArguments(
        filename: filename,
        metainfo: metainfo,
        downloadDir: downloadDir,
      ),
    );
    final jsonResponse = await flutter_libtransmission.requestAsync(
      jsonEncode(torrentAddRequest),
    );
    final TorrentAddResponse response;
    try {
      response = TorrentAddResponse.fromJson(
        (jsonDecode(jsonResponse) as Map<String, dynamic>),
      );
    } catch (e) {
      throw TransmissionRpcError('Invalid add torrent response: $e');
    }

    if (response.result != 'success') {
      throw TorrentAddError(response.result);
    }

    if (!response.arguments.torrentAdded &&
        !response.arguments.torrentDuplicate) {
      throw TorrentAddError(response.result);
    }

    if (response.arguments.torrentDuplicate) {
      return TorrentAddedResponse.duplicated;
    }

    requestCheckpoint();
    return TorrentAddedResponse.added;
  }

  @override
  Future<List<Torrent>> fetchTorrents() async {
    if (_closed) throw StateError('Engine is closed');
    final String res = await flutter_libtransmission.requestAsync(
      jsonEncode(
        TorrentGetRequest(
          arguments: TorrentGetRequestArguments(fields: torrentGetFields),
        ),
      ),
    );

    return compute(_parseTorrentsResponse, res);
  }

  @override
  Future<Torrent> fetchTorrent(int id) async {
    if (_closed) throw StateError('Engine is closed');
    final String res = await flutter_libtransmission.requestAsync(
      jsonEncode(
        TorrentGetRequest(
          arguments: TorrentGetRequestArguments(
            ids: [id],
            fields: torrentGetFields,
          ),
        ),
      ),
    );

    final TorrentGetResponse decodedRes;
    try {
      decodedRes = TorrentGetResponse.fromJson(
        (jsonDecode(res) as Map<String, dynamic>),
      );
    } catch (e) {
      throw TransmissionRpcError('Invalid fetch torrent response: $e');
    }

    if (decodedRes.result != 'success') {
      throw TransmissionRpcError(decodedRes.result);
    }

    final torrents = decodedRes.arguments.torrents;
    if (torrents.isEmpty) {
      throw StateError('Torrent $id not found');
    }
    return createTransmissionTorrentFromJson(torrents.first);
  }

  @override
  Future<Session> fetchSession() async {
    if (_closed) throw StateError('Engine is closed');
    final SessionGetRequest sessionGetRequest = SessionGetRequest(
      arguments: SessionGetRequestArguments(
        fields: [
          SessionField.downloadDir,
          SessionField.downloadQueueEnabled,
          SessionField.downloadQueueSize,
          SessionField.peerPort,
          SessionField.speedLimitDownEnabled,
          SessionField.speedLimitUpEnabled,
          SessionField.speedLimitDown,
          SessionField.speedLimitUp,
          SessionField.encryption,
          SessionField.blocklistEnabled,
          SessionField.blocklistUrl,
          SessionField.blocklistSize,
          SessionField.dhtEnabled,
          SessionField.pexEnabled,
          SessionField.lpdEnabled,
          SessionField.utpEnabled,
          SessionField.seedRatioLimit,
          SessionField.seedRatioLimited,
          SessionField.altSpeedEnabled,
          SessionField.altSpeedDown,
          SessionField.altSpeedUp,
          SessionField.altSpeedTimeEnabled,
          SessionField.altSpeedTimeBegin,
          SessionField.altSpeedTimeEnd,
          SessionField.altSpeedTimeDay,
          SessionField.idleSeedingLimitEnabled,
          SessionField.idleSeedingLimit,
          SessionField.uploadQueueEnabled,
          SessionField.uploadQueueSize,
          SessionField.ignoreLimitsOnLAN,
          SessionField.includeOverheadInLimits,
        ],
      ),
    );
    final String res = await flutter_libtransmission.requestAsync(
      jsonEncode(sessionGetRequest),
    );

    final SessionGetResponse decodedRes;
    try {
      decodedRes = SessionGetResponse.fromJson(
        (jsonDecode(res) as Map<String, dynamic>),
      );
    } catch (e) {
      throw TransmissionRpcError('Invalid fetch session response: $e');
    }

    if (decodedRes.result != 'success') {
      throw TransmissionRpcError(decodedRes.result);
    }

    return TransmissionSession(
      downloadDir: decodedRes.arguments.downloadDir,
      downloadQueueEnabled: decodedRes.arguments.downloadQueueEnabled,
      downloadQueueSize: decodedRes.arguments.downloadQueueSize,
      uploadQueueEnabled: decodedRes.arguments.uploadQueueEnabled,
      uploadQueueSize: decodedRes.arguments.uploadQueueSize,
      peerPort: decodedRes.arguments.peerPort,
      speedLimitDownEnabled: decodedRes.arguments.speedLimitDownEnabled,
      speedLimitUpEnabled: decodedRes.arguments.speedLimitUpEnabled,
      speedLimitDown: decodedRes.arguments.speedLimitDown,
      speedLimitUp: decodedRes.arguments.speedLimitUp,
      encryption: EncryptionMode.fromRpcValue(decodedRes.arguments.encryption),
      blocklistEnabled: decodedRes.arguments.blocklistEnabled,
      blocklistUrl: decodedRes.arguments.blocklistUrl,
      blocklistSize: decodedRes.arguments.blocklistSize,
      dhtEnabled: decodedRes.arguments.dhtEnabled,
      pexEnabled: decodedRes.arguments.pexEnabled,
      lpdEnabled: decodedRes.arguments.lpdEnabled,
      utpEnabled: decodedRes.arguments.utpEnabled,
      seedRatioLimit: decodedRes.arguments.seedRatioLimit,
      seedRatioLimited: decodedRes.arguments.seedRatioLimited,
      altSpeedEnabled: decodedRes.arguments.altSpeedEnabled,
      altSpeedDown: decodedRes.arguments.altSpeedDown,
      altSpeedUp: decodedRes.arguments.altSpeedUp,
      altSpeedTimeEnabled: decodedRes.arguments.altSpeedTimeEnabled,
      altSpeedTimeBegin: decodedRes.arguments.altSpeedTimeBegin,
      altSpeedTimeEnd: decodedRes.arguments.altSpeedTimeEnd,
      altSpeedTimeDay: decodedRes.arguments.altSpeedTimeDay,
      idleSeedingLimitEnabled: decodedRes.arguments.idleSeedingLimitEnabled,
      idleSeedingLimit: decodedRes.arguments.idleSeedingLimit,
      ignoreLimitsOnLAN: decodedRes.arguments.sessionSpeedLimitLan,
      includeOverheadInLimits: decodedRes.arguments.sessionSpeedLimitOverhead,
    );
  }

  @override
  Future<void> resetSettings() async {
    if (_closed) throw StateError('Engine is closed');
    final pending = _activeSave;
    final completer = Completer<void>();
    _activeSave = completer.future;

    try {
      if (pending != null) await pending.catchError((_) {});
      await Isolate.run(() => flutter_libtransmission.resetSettings());
      if (Platform.isAndroid) {
        await android.initDefaultDownloadDir(this);
      }
      if (Platform.isIOS) {
        await ios.initDefaultDownloadDir(this);
      }
    } finally {
      completer.complete();
      if (_activeSave == completer.future) {
        _activeSave = null;
      }
    }
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentsLocation(
    TorrentSetLocationArguments torrentSetLocationArguments,
  ) async {
    if (_closed) throw StateError('Engine is closed');
    if (torrentSetLocationArguments.ids.isEmpty) return;
    final request = TorrentSetLocationRequest(
      arguments: torrentSetLocationArguments,
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> removeTorrents(List<int> torrentIds, bool withData) async {
    if (_closed) throw StateError('Engine is closed');
    if (torrentIds.isEmpty) return;
    final request = TorrentRemoveRequest(
      arguments: TorrentRemoveRequestArguments(
        ids: torrentIds,
        deleteLocalData: withData,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    for (final id in torrentIds) {
      try {
        await SharedPrefsStorage.remove('streaming_active_$id');
        await SharedPrefsStorage.remove('streaming_files_$id');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to remove streaming keys for $id: $e');
        }
      }
    }
    requestCheckpoint();
  }

  @override
  Future<void> pauseTorrent(int id) async {
    if (_closed) throw StateError('Engine is closed');
    return pauseTorrents([id]);
  }

  @override
  Future<void> pauseTorrents(List<int> ids) async {
    if (_closed) throw StateError('Engine is closed');
    if (ids.isEmpty) return;
    final request = TorrentActionRequest(
      action: TorrentAction.stop,
      arguments: TorrentActionRequestArguments(ids: ids),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> resumeTorrent(int id) async {
    if (_closed) throw StateError('Engine is closed');
    return resumeTorrents([id]);
  }

  @override
  Future<void> resumeTorrents(List<int> ids) async {
    if (_closed) throw StateError('Engine is closed');
    if (ids.isEmpty) return;
    final request = TorrentActionRequest(
      action: TorrentAction.start,
      arguments: TorrentActionRequestArguments(ids: ids),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSpeedLimit(
    int id, {
    int? downloadLimit,
    int? uploadLimit,
  }) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        speedLimitDownEnabled: downloadLimit != null ? downloadLimit > 0 : null,
        speedLimitUpEnabled: uploadLimit != null ? uploadLimit > 0 : null,
        speedLimitDown:
            (downloadLimit != null && downloadLimit > 0) ? downloadLimit : null,
        speedLimitUp:
            (uploadLimit != null && uploadLimit > 0) ? uploadLimit : null,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSequentialDownload(int id, bool sequential) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        sequentialDownload: sequential,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSeedRatioMode(int id, int mode) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedRatioMode: mode,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSeedRatioLimit(int id, double limit) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedRatioLimit: limit,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSeedIdleMode(int id, int mode) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedIdleMode: mode,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentSeedIdleLimit(int id, int limit) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        seedIdleLimit: limit,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentHonorsSessionLimits(int id, bool honors) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        honorsSessionLimits: honors,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentQueuePosition(int id, int position) async {
    if (_closed) throw StateError('Engine is closed');
    final request = TorrentSetRequest(
      arguments: TorrentSetRequestArguments(
        ids: [id],
        queuePosition: position,
      ),
    );
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<void> setTorrentPriorityPieces(
    int id,
    List<int> pieceIndices,
    int priority,
  ) async {
    if (_closed) throw StateError('Engine is closed');
    TorrentSetRequestArguments args;
    if (priority > 0) {
      args = TorrentSetRequestArguments(ids: [id], priorityHigh: pieceIndices);
    } else if (priority < 0) {
      args = TorrentSetRequestArguments(ids: [id], priorityLow: pieceIndices);
    } else {
      args =
          TorrentSetRequestArguments(ids: [id], priorityNormal: pieceIndices);
    }
    final request = TorrentSetRequest(arguments: args);
    _expectSuccess(
      await flutter_libtransmission.requestAsync(jsonEncode(request)),
    );
    requestCheckpoint();
  }

  @override
  Future<int> updateBlocklist() async {
    if (_closed) throw StateError('Engine is closed');
    final responseRaw = await flutter_libtransmission.requestAsync(
      jsonEncode({'method': 'blocklist-update', 'arguments': {}}),
    );
    try {
      final decoded = jsonDecode(responseRaw) as Map<String, dynamic>;
      if (decoded['result'] != 'success') {
        return 0;
      }
      final args = decoded['arguments'] as Map<String, dynamic>?;
      return (args?['blocklist-size'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
