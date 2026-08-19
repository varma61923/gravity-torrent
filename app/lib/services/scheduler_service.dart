import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/services/remote_config/remote_config_service.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/services/wifi_guard_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

/// A weekly schedule window during which downloads are allowed.
class ScheduleWindow {
  final ScheduleTime start;
  final ScheduleTime end;

  /// Bitmask: bit 0 = Mon, bit 1 = Tue, … bit 6 = Sun.
  final int dayBitmask;

  const ScheduleWindow({
    required this.start,
    required this.end,
    this.dayBitmask = 127, // all days
  });

  bool get allDays => dayBitmask == 127;

  Map<String, dynamic> toJson() => {
        'startHour': start.hour,
        'startMinute': start.minute,
        'endHour': end.hour,
        'endMinute': end.minute,
        'dayBitmask': dayBitmask,
      };

  factory ScheduleWindow.fromJson(Map<String, dynamic> json) => ScheduleWindow(
        start: ScheduleTime(
          hour: (json['startHour'] as num?)?.toInt() ?? 0,
          minute: (json['startMinute'] as num?)?.toInt() ?? 0,
        ),
        end: ScheduleTime(
          hour: (json['endHour'] as num?)?.toInt() ?? 0,
          minute: (json['endMinute'] as num?)?.toInt() ?? 0,
        ),
        dayBitmask: (json['dayBitmask'] as num?)?.toInt() ?? 127,
      );

  /// Returns true if [now] falls within this window.
  bool isActiveAt(DateTime now) {
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;

    if (startMinutes == endMinutes) {
      // 00:00 to 00:00 means the entire day
      final dayBit = 1 << ((now.weekday - 1) % 7);
      return (dayBitmask & dayBit) != 0;
    } else if (startMinutes < endMinutes) {
      // No wrap, so just check today's bit
      final dayBit = 1 << ((now.weekday - 1) % 7);
      if ((dayBitmask & dayBit) == 0) return false;
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    } else {
      // Window wraps midnight
      if (nowMinutes >= startMinutes) {
        // Before midnight, corresponds to today's schedule
        final dayBit = 1 << ((now.weekday - 1) % 7);
        return (dayBitmask & dayBit) != 0;
      } else if (nowMinutes < endMinutes) {
        // After midnight, corresponds to yesterday's schedule
        final yesterday = now.subtract(const Duration(days: 1));
        final yesterdayBit = 1 << ((yesterday.weekday - 1) % 7);
        return (dayBitmask & yesterdayBit) != 0;
      }
      return false;
    }
  }
}

/// Service that enforces download time windows.
///
/// When enabled, it checks every minute whether downloads should be running,
/// pausing or resuming torrents accordingly. The schedule is persisted locally
/// — no data leaves the device.
class SchedulerService {
  SchedulerService._();
  static final SchedulerService instance = SchedulerService._();

  static const _storageKey = 'gravity_torrent_scheduler';
  static const _enabledKey = 'gravity_torrent_scheduler_enabled';

  ScheduleWindow _window = const ScheduleWindow(
    start: ScheduleTime(hour: 23, minute: 0),
    end: ScheduleTime(hour: 7, minute: 0),
  );

  bool _enabled = false;
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _lock;
  Timer? _timer;
  final Set<int> _pausedByScheduler = {};

  bool get enabled => _enabled;
  ScheduleWindow get window => _window;

  Future<void> load() async {
    if (_disposed || _loaded) return;

    _enabled = await SharedPrefsStorage.getBool(_enabledKey) ?? false;
    if (_disposed) return;

    final raw = await SharedPrefsStorage.getString(_storageKey);
    if (_disposed) return;

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _window = ScheduleWindow.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('Failed to load scheduler window: $e\n$s');
        }
      }
    }

    _loaded = true;
    if (_enabled && !_disposed) _startTimer();
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) return;

    _enabled = value;
    await SharedPrefsStorage.setBool(_enabledKey, value);
    if (_disposed) return;

    if (value) {
      _startTimer();
    } else {
      _stopTimer();
      await _resumeAll();
    }
  }

  Future<void> setWindow(ScheduleWindow window) async {
    if (_disposed) return;

    _window = window;
    await SharedPrefsStorage.setString(
      _storageKey,
      jsonEncode(window.toJson()),
    );
    if (_disposed) return;

    await _enforce();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _enforce());
    unawaited(_enforce()); // run immediately
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _enforce() async {
    return _withLock(_enforceImpl);
  }

  Future<void> _enforceImpl() async {
    if (_disposed) return;
    if (!_enabled) return;
    if (!RemoteConfigService.instance.isFeatureEnabled('enableScheduler')) {
      return;
    }
    if (!getIt.isRegistered<Engine>()) return;

    final now = DateTime.now();
    final shouldDownload = _window.isActiveAt(now);

    try {
      final engine = getIt<Engine>();
      final torrents = await engine.fetchTorrents();
      if (_disposed || !_enabled) return;

      if (shouldDownload) {
        // Determine whether resuming is currently allowed at all. Checked
        // up front (rather than clearing toResume afterwards) so that ids
        // blocked by quota/Wi-Fi guard stay in _pausedByScheduler and get
        // retried on a later tick instead of being forgotten forever.
        bool resumeAllowed = true;
        if (getIt.isRegistered<TorrentsModel>() &&
            getIt<TorrentsModel>().isQuotaPauseEnforced) {
          resumeAllowed = false;
        }
        if (resumeAllowed && WifiGuardService.instance.isEnabled) {
          final connectivity = await Connectivity().checkConnectivity();
          if (connectivity.contains(ConnectivityResult.mobile) ||
              !connectivity.contains(ConnectivityResult.wifi)) {
            resumeAllowed = false;
          }
        }

        // Resume torrents paused by the scheduler
        final toResume = <int>[];
        for (final id in List<int>.from(_pausedByScheduler)) {
          final t = torrents.firstWhereOrNull((t) => t.id == id);
          if (t == null) {
            // Torrent no longer exists; drop it from the set.
            _pausedByScheduler.remove(id);
            continue;
          }
          if (t.status != TorrentStatus.stopped) {
            // Already active; remove from scheduler-managed set.
            _pausedByScheduler.remove(id);
            continue;
          }
          if (resumeAllowed) {
            toResume.add(id);
            _pausedByScheduler.remove(id);
          }
          // else: leave it tracked so a later tick retries the resume once
          // quota/Wi-Fi guard allow it again.
        }
        if (toResume.isNotEmpty) {
          try {
            await engine.resumeTorrents(toResume);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('SchedulerService failed to resume torrents: $e');
            }
          }
        }
      } else {
        // Pause active torrents and remember them
        final toPause = <int>[];
        for (final torrent in torrents) {
          if (torrent.status == TorrentStatus.downloading ||
              torrent.status == TorrentStatus.seeding ||
              torrent.status == TorrentStatus.queuedToDownload ||
              torrent.status == TorrentStatus.queuedToSeed ||
              torrent.status == TorrentStatus.queuedToCheck ||
              torrent.status == TorrentStatus.checking) {
            toPause.add(torrent.id);
            _pausedByScheduler.add(torrent.id);
          }
        }
        if (toPause.isNotEmpty) {
          try {
            await engine.pauseTorrents(toPause);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('SchedulerService failed to pause torrents: $e');
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('SchedulerService _enforce error: $e');
    }
  }

  Future<void> _resumeAll() async {
    if (_disposed) return;
    if (_pausedByScheduler.isEmpty) return;
    if (!getIt.isRegistered<Engine>()) {
      _pausedByScheduler.clear();
      return;
    }

    try {
      final engine = getIt<Engine>();
      final torrents = await engine.fetchTorrents();
      if (_disposed) return;

      final existingIds = {for (final t in torrents) t.id};
      final toResume = <int>[];
      for (final id in List<int>.from(_pausedByScheduler)) {
        if (!existingIds.contains(id)) {
          _pausedByScheduler.remove(id);
          continue;
        }
        toResume.add(id);
      }
      if (getIt.isRegistered<TorrentsModel>() &&
          getIt<TorrentsModel>().isQuotaPauseEnforced) {
        toResume.clear();
      }
      if (toResume.isNotEmpty && WifiGuardService.instance.isEnabled) {
        final connectivity = await Connectivity().checkConnectivity();
        if (connectivity.contains(ConnectivityResult.mobile) ||
            !connectivity.contains(ConnectivityResult.wifi)) {
          toResume.clear();
        }
      }
      if (toResume.isNotEmpty) {
        try {
          await engine.resumeTorrents(toResume);
          _pausedByScheduler.clear();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('SchedulerService failed to resume torrents: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('SchedulerService _resumeAll error: $e');
    }
  }

  void dispose() {
    if (_disposed) return;
    _stopTimer();
    _disposed = true;
  }

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

/// Simple hour/minute value for use in non-widget service code.
/// Do not confuse with Flutter's [material.TimeOfDay].
class ScheduleTime {
  final int hour;
  final int minute;

  const ScheduleTime({required this.hour, required this.minute});

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
