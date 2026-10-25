import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/utils/bitfield.dart';

enum TorrentField {
  id,
  name,
  status,
  percentDone,
  totalSize,
  rateDownload,
  rateUpload,
  downloadedEver,
  uploadedEver,
  eta,
  pieceCount,
  pieces,
  pieceSize,
  errorString,
  addedDate,
  downloadDir,
  isPrivate,
  creator,
  comment,
  files,
  fileStats,
  labels,
  peersConnected,
  magnetLink,
  sequentialDownload,
  speedLimitDownEnabled,
  speedLimitUpEnabled,
  speedLimitDown,
  speedLimitUp,
  doneDate,
  leftUntilDone,
  sizeWhenDone,
  seedRatioMode,
  seedRatioLimit,
  seedIdleMode,
  seedIdleLimit,
  honorsSessionLimits,
  queuePosition,
}

class TransmissionTorrentFile {
  final String name;
  final int length;
  final int bytesCompleted;
  final int beginPiece;
  final int endPiece;

  TransmissionTorrentFile(
    this.name,
    this.length,
    this.bytesCompleted,
    this.beginPiece,
    this.endPiece,
  );

  TransmissionTorrentFile.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String? ?? '',
        length = (json['length'] as num?)?.toInt() ?? 0,
        bytesCompleted =
            ((json['bytesCompleted'] ?? json['bytes_completed']) as num?)
                    ?.toInt() ??
                0,
        beginPiece =
            ((json['begin_piece'] ?? json['beginPiece']) as num?)?.toInt() ?? 0,
        endPiece =
            ((json['end_piece'] ?? json['endPiece']) as num?)?.toInt() ?? 0;
}

class TransmissionTorrentFileStats {
  final bool wanted;

  TransmissionTorrentFileStats(this.wanted);

  TransmissionTorrentFileStats.fromJson(Map<String, dynamic> json)
      : wanted = json['wanted'] as bool? ?? true;
}

class TransmissionTorrentModel {
  final int id;
  final String name;
  final double percentDone;
  final TorrentStatus status;
  final int totalSize;
  final int rateDownload;
  final int rateUpload;
  final int downloadedEver;
  final int uploadedEver;
  final int eta;
  final int pieceCount;
  final List<bool> pieces;
  final int pieceSize;
  final String errorString;
  final String location;
  final bool isPrivate;
  final int addedDate;
  final String creator;
  final String comment;
  final List<TransmissionTorrentFile> files;
  final List<TransmissionTorrentFileStats> fileStats;
  final List<String> labels;
  final int peersConnected;
  final String magnetLink;
  final bool sequentialDownload;
  final bool speedLimitDownEnabled;
  final bool speedLimitUpEnabled;
  final int speedLimitDown;
  final int speedLimitUp;
  final DateTime doneDate;
  final int leftUntilDone;
  final int sizeWhenDone;
  final int seedRatioMode;
  final double seedRatioLimit;
  final int seedIdleMode;
  final int seedIdleLimit;
  final bool honorsSessionLimits;
  final int queuePosition;

  const TransmissionTorrentModel(
    this.id,
    this.name,
    this.percentDone,
    this.status,
    this.totalSize,
    this.rateDownload,
    this.rateUpload,
    this.downloadedEver,
    this.uploadedEver,
    this.eta, // in seconds
    this.errorString,
    this.pieces,
    this.pieceSize,
    this.pieceCount,
    this.addedDate,
    this.isPrivate,
    this.location,
    this.comment,
    this.creator,
    this.files,
    this.labels,
    this.peersConnected,
    this.fileStats,
    this.magnetLink,
    this.sequentialDownload,
    this.speedLimitDownEnabled,
    this.speedLimitUpEnabled,
    this.speedLimitDown,
    this.speedLimitUp,
    this.doneDate,
    this.leftUntilDone,
    this.sizeWhenDone,
    this.seedRatioMode,
    this.seedRatioLimit,
    this.seedIdleMode,
    this.seedIdleLimit,
    this.honorsSessionLimits,
    this.queuePosition,
  );

  TransmissionTorrentModel.fromJson(Map<String, dynamic> json)
      : id = (json['id'] as num?)?.toInt() ?? 0,
        name = json['name'] as String? ?? '',
        percentDone = json['percentDone'] is int
            ? (json['percentDone'] as int).toDouble()
            : (json['percentDone'] as double? ?? 0.0),
        status = (() {
          final s = (json['status'] as num?)?.toInt() ?? 0;
          if (s >= 0 && s < TorrentStatus.values.length) {
            return TorrentStatus.values[s];
          }
          return TorrentStatus.stopped;
        })(),
        totalSize = (json['totalSize'] as num?)?.toInt() ?? 0,
        rateDownload = (json['rateDownload'] as num?)?.toInt() ?? 0,
        rateUpload = (json['rateUpload'] as num?)?.toInt() ?? 0,
        downloadedEver = (json['downloadedEver'] as num?)?.toInt() ?? 0,
        uploadedEver = (json['uploadedEver'] as num?)?.toInt() ?? 0,
        eta = (json['eta'] as num?)?.toInt() ?? -1,
        pieces = (() {
          final raw = json['pieces'];
          final rawCount = (json['pieceCount'] as num?)?.toInt() ?? 0;
          final count = rawCount < 0 ? 0 : rawCount;
          if (raw == null || raw.toString().isEmpty || count == 0) {
            return List<bool>.filled(count, false);
          }
          try {
            return convertBitfieldToBoolList(
              base64Decode(raw as String),
              count,
            );
          } catch (e, s) {
            if (kDebugMode) {
              debugPrint('Failed to decode torrent bitfield: $e\n$s');
            }
            return List<bool>.filled(count, false);
          }
        })(),
        pieceCount = (() {
          final rawCount = (json['pieceCount'] as num?)?.toInt() ?? 0;
          return rawCount < 0 ? 0 : rawCount;
        })(),
        pieceSize = (json['pieceSize'] as num?)?.toInt() ?? 0,
        errorString = json['errorString'] as String? ?? '',
        location = json['downloadDir'] as String? ?? '',
        isPrivate = json['isPrivate'] as bool? ?? false,
        addedDate = (json['addedDate'] as num?)?.toInt() ?? 0,
        creator = json['creator'] as String? ?? '',
        comment = json['comment'] as String? ?? '',
        files = (json['files'] as List<dynamic>?)
                ?.map<TransmissionTorrentFile>(
                  (j) => TransmissionTorrentFile.fromJson(
                    j as Map<String, dynamic>,
                  ),
                )
                .toList() ??
            [],
        fileStats = (json['fileStats'] as List<dynamic>?)
                ?.map<TransmissionTorrentFileStats>(
                  (j) => TransmissionTorrentFileStats.fromJson(
                    j as Map<String, dynamic>,
                  ),
                )
                .toList() ??
            [],
        labels =
            (json['labels'] as List<dynamic>?)?.whereType<String>().toList() ??
                [],
        peersConnected = (json['peersConnected'] as num?)?.toInt() ?? 0,
        magnetLink = json['magnetLink'] as String? ?? '',
        sequentialDownload = json['sequential_download'] as bool? ?? false,
        // Per-torrent bandwidth limits are returned under `download_limit(ed)`
        // / `upload_limit(ed)` (with `downloadLimit(ed)`/`uploadLimit(ed)` as
        // the legacy alias) — NOT the `speedLimit*` names used for the
        // session-level (global) settings.
        speedLimitDownEnabled =
            (json['download_limited'] ?? json['downloadLimited']) as bool? ??
                false,
        speedLimitUpEnabled =
            (json['upload_limited'] ?? json['uploadLimited']) as bool? ?? false,
        speedLimitDown =
            ((json['download_limit'] ?? json['downloadLimit']) as num?)
                    ?.toInt() ??
                0,
        speedLimitUp =
            ((json['upload_limit'] ?? json['uploadLimit']) as num?)?.toInt() ??
                0,
        doneDate = (() {
          try {
            return DateTime.fromMillisecondsSinceEpoch(
              ((json['doneDate'] as num?)?.toInt() ?? 0) * 1000,
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Invalid doneDate for torrent: $e');
            }
            return DateTime.utc(1970);
          }
        })(),
        leftUntilDone = (json['leftUntilDone'] as num?)?.toInt() ?? 0,
        sizeWhenDone = (json['sizeWhenDone'] as num?)?.toInt() ?? 0,
        seedRatioMode = (json['seedRatioMode'] as num?)?.toInt() ?? 0,
        seedRatioLimit = (json['seedRatioLimit'] as num?)?.toDouble() ?? 0.0,
        seedIdleMode = (json['seedIdleMode'] as num?)?.toInt() ?? 0,
        seedIdleLimit = (json['seedIdleLimit'] as num?)?.toInt() ?? 0,
        honorsSessionLimits = json['honorsSessionLimits'] as bool? ?? true,
        queuePosition = (json['queuePosition'] as num?)?.toInt() ?? -1;
}
