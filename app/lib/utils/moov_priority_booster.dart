import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/utils/torrent_utils.dart';

class _BoosterSession {
  int activeCount = 0;
  final bool originalLimitDownEnabled;
  final int originalLimitDown;

  _BoosterSession({
    required this.originalLimitDownEnabled,
    required this.originalLimitDown,
  });
}

/// Intelligent priority booster for video streaming.
///
/// Automatically prioritizes the first 1% (header) and last 1% (moov atom)
/// of pieces for a video file before starting sequential playback.
class MoovPriorityBooster {
  MoovPriorityBooster._();

  static final Map<int, _BoosterSession> _activeSessions = {};

  @visibleForTesting
  static void resetForTest() {
    _activeSessions.clear();
  }

  @visibleForTesting
  static Map<int, dynamic> get activeSessionsForTest => _activeSessions;

  static Future<void> boostForStreaming({
    required Torrent torrent,
    required torrent_file.File file,
  }) async {
    try {
      final engine = getIt<Engine>();

      // 1. Enable sequential download mode for the torrent
      await engine.setTorrentSequentialDownload(torrent.id, true);

      final pieceSize = torrent.pieceSize;
      if (pieceSize <= 0) return;

      // 2. Validate piece boundaries
      final startPiece = file.beginPiece;
      final endPiece = file.endPiece;
      if (startPiece < 0 || endPiece < startPiece) return;
      if (torrent.pieceCount > 0 && startPiece >= torrent.pieceCount) return;

      final clampedEnd = torrent.pieceCount > 0
          ? endPiece.clamp(0, torrent.pieceCount - 1)
          : endPiece;

      if (kDebugMode) {
        debugPrint(
          'MoovPriorityBooster: boosting torrent ${torrent.id} (${file.name}): '
          'pieces [$startPiece..$clampedEnd]',
        );
      }

      // 3. Set high priority on the file
      final fileIndex = torrent.files.indexWhere((f) => f.name == file.name);
      if (fileIndex != -1) {
        await torrent.setFilesPriority(priorityHigh: [fileIndex]);
      }

      // 4. Update sequential download start piece to ensure correct order
      await torrent.setSequentialDownloadFromPiece(startPiece);

      // 5. Track speed limit state across concurrent boost calls
      final session = _activeSessions.putIfAbsent(torrent.id, () {
        return _BoosterSession(
          originalLimitDownEnabled: torrent.speedLimitDownEnabled,
          originalLimitDown: torrent.speedLimitDown,
        );
      });

      session.activeCount++;

      // Only disable speed limit if a download limit was actually active and this is the first active session
      if (session.activeCount == 1 &&
          session.originalLimitDownEnabled &&
          session.originalLimitDown > 0) {
        try {
          await engine.setTorrentSpeedLimit(
            torrent.id,
            downloadLimit: 0, // unlimited while buffering header
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              'MoovPriorityBooster: failed to disable speed limit: $e',
            );
          }
        }
      }

      // 6. Restore the speed limit once the moov atom and header pieces are ready
      unawaited(() async {
        try {
          final neededPieces = startPiece == clampedEnd
              ? [startPiece]
              : [startPiece, clampedEnd];

          await waitForPiecesList(
            torrent: torrent,
            neededPieces: neededPieces,
          );
        } catch (_) {
          // Cancellation or piece wait error
        } finally {
          try {
            session.activeCount--;
            if (session.activeCount <= 0) {
              _activeSessions.remove(torrent.id);

              // Only attempt restoration if a limit was originally active
              if (session.originalLimitDownEnabled &&
                  session.originalLimitDown > 0) {
                // Fetch the live torrent state from engine to avoid clobbering
                // user-configured limits modified during buffering.
                final currentTorrent = await engine.fetchTorrent(torrent.id);
                // If the speed limit was re-enabled or manually changed by the user
                // during buffering, do NOT overwrite it with stale original limit.
                if (!currentTorrent.speedLimitDownEnabled) {
                  await engine.setTorrentSpeedLimit(
                    torrent.id,
                    downloadLimit: session.originalLimitDown,
                  );
                }
              }
            }
          } catch (_) {
            // Safe ignore if engine is closed or torrent was removed
          }
        }
      }());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('MoovPriorityBooster error: $e');
      }
    }
  }
}
