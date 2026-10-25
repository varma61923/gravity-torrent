import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

/// Daily data-usage snapshot.
class DataUsageSnapshot {
  final DateTime day;
  final int downloadedBytes;
  final int uploadedBytes;

  DataUsageSnapshot({
    required this.day,
    required this.downloadedBytes,
    required this.uploadedBytes,
  });

  Map<String, dynamic> toJson() => {
        'day': day.toIso8601String(),
        'downloadedBytes': downloadedBytes,
        'uploadedBytes': uploadedBytes,
      };

  factory DataUsageSnapshot.fromJson(Map<String, dynamic> json) {
    final dayRaw = json['day'];
    if (dayRaw is! String) {
      throw const FormatException('Missing or invalid day');
    }
    final day = DateTime.tryParse(dayRaw);
    if (day == null) {
      throw FormatException('Invalid day: $dayRaw');
    }
    return DataUsageSnapshot(
      day: day,
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      uploadedBytes: (json['uploadedBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// On-device data-usage analytics.
///
/// Keeps a rolling window of daily upload/download totals in local storage.
/// New samples are upscaled from [Engine] session/torrent totals and merged
/// with the existing history so the dashboard always reflects recent activity.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  static const _storageKey = 'gravity_torrent_analytics_history';
  static const _baselinesKey = 'gravity_torrent_analytics_baselines';
  static const _maxDays = 90;

  List<DataUsageSnapshot> _history = [];
  bool _loaded = false;
  Map<int, int> _lastDownloadedByTorrent = {};
  Map<int, int> _lastUploadedByTorrent = {};
  int? _lastDownloadedTotal;
  int? _lastUploadedTotal;

  Future<void>? _lock;

  @visibleForTesting
  void reset() {
    _loaded = false;
    _history = [];
    _lastDownloadedByTorrent = {};
    _lastUploadedByTorrent = {};
    _lastDownloadedTotal = null;
    _lastUploadedTotal = null;
  }

  /// Clears all stored analytics history and per-torrent baselines.
  Future<void> clearHistory() async => _withLock(() => _clearHistoryImpl());

  Future<void> _clearHistoryImpl() async {
    _history = [];
    _lastDownloadedByTorrent = {};
    _lastUploadedByTorrent = {};
    _lastDownloadedTotal = null;
    _lastUploadedTotal = null;
    await SharedPrefsStorage.remove(_storageKey);
    await SharedPrefsStorage.remove(_baselinesKey);
  }

  Future<void> load() async => _withLock(() => _loadImpl());

  Future<void> _loadImpl() async {
    if (_loaded) return;
    try {
      final raw = await SharedPrefsStorage.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List<dynamic>) {
          _history = decoded
              .whereType<Map<String, dynamic>>()
              .map((e) {
                try {
                  return DataUsageSnapshot.fromJson(
                    Map<String, dynamic>.from(e),
                  );
                } catch (e, s) {
                  if (kDebugMode) {
                    debugPrint('Skipping invalid analytics snapshot: $e\n$s');
                  }
                  return null;
                }
              })
              .whereType<DataUsageSnapshot>()
              .toList();
        }
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('Failed to load analytics history: $e\n$s');
      }
      _history = [];
    }
    _history.sort((a, b) => a.day.compareTo(b.day));
    await _loadBaselinesImpl();
    _loaded = true;
  }

  Future<void> save() async => _withLock(() => _saveImpl());

  Future<void> _saveImpl() async {
    final raw = jsonEncode(_history.map((e) => e.toJson()).toList());
    await SharedPrefsStorage.setString(_storageKey, raw);
  }

  /// Record the latest cumulative session totals. The delta since the last
  /// sample is added to today's bucket.
  Future<void> recordTotals({
    required int downloadedBytes,
    required int uploadedBytes,
  }) async =>
      _withLock(
        () => _recordTotalsImpl(
          downloadedBytes: downloadedBytes,
          uploadedBytes: uploadedBytes,
        ),
      );

  Future<void> _recordTotalsImpl({
    required int downloadedBytes,
    required int uploadedBytes,
  }) async {
    await _loadImpl();

    int deltaDown = 0;
    int deltaUp = 0;

    final lastD = _lastDownloadedTotal;
    final lastU = _lastUploadedTotal;

    if (lastD == null) {
      // First sample for this session, establish the baseline.
    } else if (downloadedBytes >= lastD) {
      deltaDown = downloadedBytes - lastD;
    } else {
      // Counter reset: treat the new total as fresh progress.
      deltaDown = downloadedBytes;
    }

    if (lastU == null) {
      // First sample for this session, establish the baseline.
    } else if (uploadedBytes >= lastU) {
      deltaUp = uploadedBytes - lastU;
    } else {
      // Counter reset: treat the new total as fresh progress.
      deltaUp = uploadedBytes;
    }

    _lastDownloadedTotal = downloadedBytes;
    _lastUploadedTotal = uploadedBytes;

    await _recordDeltasImpl(deltaDown, deltaUp);
  }

  /// Record the latest cumulative per-torrent totals. The aggregate delta since
  /// the last sample is added to today's bucket.
  Future<void> recordTorrentStats(List<Torrent> torrents) async =>
      _withLock(() => _recordTorrentStatsImpl(torrents));

  Future<void> _recordTorrentStatsImpl(List<Torrent> torrents) async {
    await _loadImpl();
    int deltaDown = 0;
    int deltaUp = 0;

    for (final t in torrents) {
      final id = t.id;
      final down = t.downloadedEver;
      final up = t.uploadedEver;

      final lastD = _lastDownloadedByTorrent[id];
      final lastU = _lastUploadedByTorrent[id];

      if (lastD == null) {
        // First time seeing this torrent this session, don't count existing
      } else if (down >= lastD) {
        deltaDown += down - lastD;
      } else {
        deltaDown += down;
      }

      if (lastU == null) {
        // First time seeing this torrent
      } else if (up >= lastU) {
        deltaUp += up - lastU;
      } else {
        deltaUp += up;
      }

      _lastDownloadedByTorrent[id] = down;
      _lastUploadedByTorrent[id] = up;
    }

    final currentIds = torrents.map((t) => t.id).toSet();
    _lastDownloadedByTorrent.removeWhere((id, _) => !currentIds.contains(id));
    _lastUploadedByTorrent.removeWhere((id, _) => !currentIds.contains(id));

    await _recordDeltasImpl(deltaDown, deltaUp);
    await _saveBaselinesImpl();
  }

  Future<void> _recordDeltasImpl(int deltaDown, int deltaUp) async {
    await _loadImpl();
    final now = DateTime.now();
    final key = DateTime(now.year, now.month, now.day);

    // Skip writing if both deltas are zero to avoid spurious entries,
    // but still ensure trimming if we are over capacity.
    if (deltaDown == 0 && deltaUp == 0) {
      if (_history.length > _maxDays) {
        _history.removeRange(0, _history.length - _maxDays);
        await _saveImpl();
      }
      return;
    }

    final existing = _history.where((s) => s.day == key).toList();
    if (existing.isNotEmpty) {
      final last = existing.last;
      final index = _history.indexOf(last);
      _history[index] = DataUsageSnapshot(
        day: key,
        downloadedBytes: last.downloadedBytes + deltaDown,
        uploadedBytes: last.uploadedBytes + deltaUp,
      );
    } else {
      _history.add(
        DataUsageSnapshot(
          day: key,
          downloadedBytes: deltaDown,
          uploadedBytes: deltaUp,
        ),
      );
      // `today` / getLastDays() / the trim step above all assume `_history`
      // stays sorted oldest-first with today last. That only holds if `key`
      // is >= every existing entry, which a backward clock change (DST
      // correction, manual clock adjustment, crossing the date line) can
      // violate, so re-sort after appending rather than assuming it.
      _history.sort((a, b) => a.day.compareTo(b.day));
    }

    // Trim after insert/merge to guarantee bound.
    if (_history.length > _maxDays) {
      _history.removeRange(0, _history.length - _maxDays);
    }

    await _saveImpl();
  }

  Future<void> _loadBaselinesImpl() async {
    try {
      final raw = await SharedPrefsStorage.getString(_baselinesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final down = decoded['down'];
      final up = decoded['up'];
      _lastDownloadedByTorrent = {};
      _lastUploadedByTorrent = {};
      if (down is Map) {
        for (final entry in down.entries) {
          final id = int.tryParse(entry.key.toString());
          final value = (entry.value as num?)?.toInt();
          if (id != null && value != null) {
            _lastDownloadedByTorrent[id] = value;
          }
        }
      }
      if (up is Map) {
        for (final entry in up.entries) {
          final id = int.tryParse(entry.key.toString());
          final value = (entry.value as num?)?.toInt();
          if (id != null && value != null) {
            _lastUploadedByTorrent[id] = value;
          }
        }
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('Failed to load analytics baselines: $e\n$s');
      }
      _lastDownloadedByTorrent = {};
      _lastUploadedByTorrent = {};
    }
  }

  Future<void> _saveBaselinesImpl() async {
    final payload = {
      'down': {
        for (final e in _lastDownloadedByTorrent.entries)
          e.key.toString(): e.value,
      },
      'up': {
        for (final e in _lastUploadedByTorrent.entries)
          e.key.toString(): e.value,
      },
    };
    await SharedPrefsStorage.setString(_baselinesKey, jsonEncode(payload));
  }

  List<DataUsageSnapshot> get history => List.unmodifiable(_history);

  List<DataUsageSnapshot> getLastDays(int count) {
    if (_history.length <= count) return List.unmodifiable(_history);
    return List.unmodifiable(_history.sublist(_history.length - count));
  }

  DataUsageSnapshot? get today {
    if (_history.isEmpty) return null;
    // History is kept sorted by day and trimmed to [_maxDays], so today's
    // bucket — if it exists — is always the last element. Days are normalized
    // to midnight, so a direct DateTime comparison is safe.
    final last = _history.last;
    final now = DateTime.now();
    final key = DateTime(now.year, now.month, now.day);
    return last.day == key ? last : null;
  }

  /// Serialize async operations so loads, saves and recordings do not overlap.
  Future<T> _withLock<T>(Future<T> Function() task) {
    final previous = _lock;
    final current = Future<T>(() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      return task();
    });
    _lock = current;
    unawaited(
      current.whenComplete(() {
        if (_lock == current) _lock = null;
      }),
    );
    return current;
  }
}
