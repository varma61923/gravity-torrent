import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/session.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

class BandwidthHeatmapService extends ChangeNotifier {
  // 7 days x 24 hours. Value is speed limit in KB/s. 0 means unlimited, -1 means pause.
  final List<List<int>> _schedule = List.generate(7, (_) => List.filled(24, 0));
  Timer? _timer;
  int _lastAppliedLimit = 0;
  bool _loaded = false;
  bool _disposed = false;
  bool _isEnforcing = false;

  final Set<int> _pausedByHeatmap = {};

  static const _storageKey = 'gravity_torrent_bandwidth_heatmap';

  List<List<int>> get schedule => _schedule;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  BandwidthHeatmapService() {
    // Load asynchronously; until then the default all-unlimited schedule is
    // safe and the timer will re-evaluate once persistence is restored.
    unawaited(load().then((_) => _startTimer()));
  }

  /// Loads the persisted 7x24 schedule. Safe to call repeatedly.
  Future<void> load() async {
    if (_disposed || _loaded) return;
    try {
      final raw = await SharedPrefsStorage.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List && decoded.length == 7) {
          for (var d = 0; d < 7; d++) {
            final dayList = decoded[d];
            if (dayList is List && dayList.length == 24) {
              for (var h = 0; h < 24; h++) {
                final value = dayList[h];
                _schedule[d][h] = (value as num?)?.toInt() ?? 0;
              }
            }
          }
        }
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('BandwidthHeatmapService load failed: $e\n$s');
      }
    }
    _loaded = true;
    _safeNotify();
    // Re-evaluate with restored schedule.
    await _enforceLimit();
  }

  /// Clears in-memory state and persisted storage. Intended for tests.
  @visibleForTesting
  Future<void> reset() async {
    if (_disposed) return;
    _loaded = false;
    _lastAppliedLimit = 0;
    for (var d = 0; d < 7; d++) {
      _schedule[d].fillRange(0, 24, 0);
    }
    _pausedByHeatmap.clear();
    await SharedPrefsStorage.remove(_storageKey);
    _safeNotify();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_isEnforcing) return;
      _isEnforcing = true;
      _enforceLimit().whenComplete(() => _isEnforcing = false);
    });
    unawaited(_enforceLimit());
  }

  void setScheduleLimit(int day, int hour, int limit) {
    if (_disposed) return;
    if (day >= 0 && day < 7 && hour >= 0 && hour < 24) {
      _schedule[day][hour] = limit;
      unawaited(_save());
      _safeNotify();
      if (!_isEnforcing) {
        _isEnforcing = true;
        _enforceLimit().whenComplete(() => _isEnforcing = false);
      }
    }
  }

  Future<void> _save() async {
    final payload = _schedule.map((day) => List<int>.from(day)).toList();
    await SharedPrefsStorage.setString(_storageKey, jsonEncode(payload));
  }

  int getLimitForCurrentTime() {
    final now = DateTime.now();
    // DateTime.weekday is 1 (Monday) to 7 (Sunday). Map to 0-6.
    final day = now.weekday - 1;
    final hour = now.hour;
    return _schedule[day][hour];
  }

  Future<void> _enforceLimit() async {
    if (_disposed) return;
    try {
      final currentLimit = getLimitForCurrentTime();
      // Always re-evaluate the -1 "pause" slot so newly active torrents are
      // paused even when the limit hasn't changed.
      if (currentLimit == _lastAppliedLimit && currentLimit != -1) return;

      if (!getIt.isRegistered<Engine>()) return;
      final engine = getIt<Engine>();
      if (_disposed) return;

      if (currentLimit == -1) {
        // -1 means pause all active torrents. Do not touch alt-speed while
        // paused; resume is handled when leaving the -1 slot.
        final torrents = await engine.fetchTorrents();
        if (_disposed) return;
        final activeIds = torrents
            .where(
              (t) =>
                  t.status == TorrentStatus.downloading ||
                  t.status == TorrentStatus.seeding,
            )
            .map((t) => t.id)
            .toList();
        if (activeIds.isNotEmpty) {
          await engine.pauseTorrents(activeIds);
          _pausedByHeatmap.addAll(activeIds);
        }
      } else {
        // Leaving/entering a non-pause slot: resume anything the heatmap
        // paused, respecting quota throttling.
        if (_pausedByHeatmap.isNotEmpty) {
          final isQuotaEnforced = getIt.isRegistered<TorrentsModel>() &&
              getIt<TorrentsModel>().isQuotaPauseEnforced;
          if (!isQuotaEnforced) {
            try {
              await engine.resumeTorrents(_pausedByHeatmap.toList());
              _pausedByHeatmap.clear();
            } catch (_) {
              // Keep _pausedByHeatmap for retry on next tick.
            }
          }
        }

        final session = await engine.fetchSession();
        if (_disposed) return;

        if (currentLimit == 0) {
          // 0 means unlimited — disable heatmap-driven alt-speed.
          // If BatteryService is currently throttling, it controls alt-speed
          // independently; we defer to it and skip the update here.
          await session.update(SessionBase(altSpeedEnabled: false));
        } else if (currentLimit > 0) {
          // specific limit
          await session.update(
            SessionBase(
              altSpeedEnabled: true,
              altSpeedDown: currentLimit,
              altSpeedUp: currentLimit,
            ),
          );
        }
      }

      _lastAppliedLimit = currentLimit;
      if (kDebugMode) {
        debugPrint('BandwidthHeatmapService: Enforced limit $currentLimit');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('BandwidthHeatmapService Error enforcing limit: $e');
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
