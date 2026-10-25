import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

/// Guard mode for [WifiGuardService].
enum WifiGuardMode {
  /// Pause downloads whenever the device is not on WiFi.
  wifiOnly,

  /// Pause downloads whenever the network interface IP address changes
  /// (e.g. VPN disconnects and ISP IP is exposed).
  vpnKillSwitch,
}

/// Service that pauses all active torrents when the network leaves WiFi
/// (WiFi-only mode) or when the bound network interface changes (VPN kill
/// switch mode).
///
/// Follows the same singleton / SharedPrefs pattern as [SchedulerService].
class WifiGuardService {
  WifiGuardService._();
  static final WifiGuardService instance = WifiGuardService._();

  static const _enabledKey = 'gravity_torrent_wifi_guard_enabled';
  static const _modeKey = 'gravity_torrent_wifi_guard_mode';

  bool _enabled = false;
  bool _loaded = false;
  WifiGuardMode _mode = WifiGuardMode.wifiOnly;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final Set<int> _pausedByGuard = {};

  /// The last known list of local IP addresses, used to detect interface changes.
  List<String> _lastIpAddresses = [];

  /// When true in VPN kill-switch mode, torrents were paused due to an IP
  /// change and must not auto-resume when the same (exposed) IP is seen again.
  /// Cleared only by an explicit user action ([setMode]/[setEnabled]).
  bool _vpnKillTripped = false;

  bool _disposed = false;
  Future<void>? _lock;

  bool get isEnabled => _enabled;
  WifiGuardMode get mode => _mode;

  Future<void> load() async {
    if (_disposed || _loaded) return;
    _enabled = await SharedPrefsStorage.getBool(_enabledKey) ?? false;
    final modeStr = await SharedPrefsStorage.getString(_modeKey);
    if (_disposed) return;
    _mode = modeStr == 'vpnKillSwitch'
        ? WifiGuardMode.vpnKillSwitch
        : WifiGuardMode.wifiOnly;
    _loaded = true;
    if (_enabled) _subscribe();
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) return;
    return _withLock(() => _setEnabledImpl(value));
  }

  Future<void> _setEnabledImpl(bool value) async {
    _enabled = value;
    await SharedPrefsStorage.setBool(_enabledKey, value);
    if (_disposed) return;
    if (value) {
      _subscribe();
    } else {
      _unsubscribe();
      await _resumeAll();
      _vpnKillTripped = false;
    }
  }

  Future<void> setMode(WifiGuardMode mode) async {
    if (_disposed) return;
    return _withLock(() => _setModeImpl(mode));
  }

  Future<void> _setModeImpl(WifiGuardMode mode) async {
    _mode = mode;
    await SharedPrefsStorage.setString(
      _modeKey,
      mode == WifiGuardMode.vpnKillSwitch ? 'vpnKillSwitch' : 'wifiOnly',
    );
    if (_disposed) return;
    // Re-seed the IP snapshot when switching modes.
    _lastIpAddresses = await _currentIpAddresses();
    _vpnKillTripped = false;
    _pausedByGuard.clear();
  }

  void _subscribe() {
    _unsubscribe();
    // Start with an empty IP snapshot. The first connectivity event will seed
    // the baseline inside the lock, avoiding a race with the listener.
    _lastIpAddresses = [];
    _vpnKillTripped = false;
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
          _onConnectivityChanged,
        );
  }

  void _unsubscribe() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_disposed) return;
    unawaited(
      _withLock(() => _onConnectivityChangedImpl(results)).catchError((
        Object e,
      ) {
        if (kDebugMode) {
          debugPrint('WifiGuardService connectivity handler error: $e');
        }
      }),
    );
  }

  Future<void> _onConnectivityChangedImpl(
    List<ConnectivityResult> results,
  ) async {
    if (!_enabled || _disposed) return;
    final hasWifi = results.contains(ConnectivityResult.wifi);
    final hasAny = results.isNotEmpty &&
        !results.every((r) => r == ConnectivityResult.none);

    if (_mode == WifiGuardMode.wifiOnly) {
      if (!hasWifi) {
        await _pauseAll();
      } else {
        await _resumeAll();
      }
    } else {
      // VPN kill switch: pause on any IP address change.
      if (!hasAny) {
        // No network at all — definitely pause.
        await _pauseAll();
        _lastIpAddresses = [];
      } else {
        final currentIps = await _currentIpAddresses();
        final changed = !_ipListsEqual(_lastIpAddresses, currentIps);
        if (changed && _lastIpAddresses.isNotEmpty) {
          // Interface change detected — trip the kill switch.
          if (kDebugMode) {
            debugPrint(
              'WifiGuardService: interface change detected '
              '$_lastIpAddresses -> $currentIps',
            );
          }
          _vpnKillTripped = true;
          await _pauseAll();
        } else if (_lastIpAddresses.isEmpty && currentIps.isNotEmpty) {
          // Network restored after a full disconnect — resume only if the
          // kill switch has not been tripped.
          if (!_vpnKillTripped) {
            await _resumeAll();
          }
        } else if (!changed && _lastIpAddresses.isNotEmpty) {
          // Same IPs as before — do NOT auto-resume if kill switch was
          // tripped, otherwise the exposed IP would resume traffic.
          if (!_vpnKillTripped) {
            await _resumeAll();
          }
        }
        _lastIpAddresses = currentIps;
      }
    }
  }

  Future<List<String>> _currentIpAddresses() async {
    if (kIsWeb) return [];
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces
          .expand((iface) => iface.addresses)
          .map((addr) => addr.address)
          .where((ip) => !ip.startsWith('127.'))
          .toList()
        ..sort();
    } catch (e) {
      if (kDebugMode) debugPrint('WifiGuardService: failed to list IPs: $e');
      return [];
    }
  }

  bool _ipListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pauseAll() async {
    if (_disposed) return;
    try {
      if (!getIt.isRegistered<Engine>()) return;
      final engine = getIt<Engine>();
      final torrents = await engine.fetchTorrents();
      if (_disposed) return;

      final futures = <Future<void>>[];
      for (final torrent in torrents) {
        if (torrent.status == TorrentStatus.downloading ||
            torrent.status == TorrentStatus.seeding ||
            torrent.status == TorrentStatus.queuedToDownload ||
            torrent.status == TorrentStatus.queuedToSeed ||
            torrent.status == TorrentStatus.queuedToCheck ||
            torrent.status == TorrentStatus.checking) {
          futures.add(() async {
            try {
              await engine.pauseTorrent(torrent.id);
              _pausedByGuard.add(torrent.id);
            } catch (e) {
              if (kDebugMode) {
                debugPrint(
                  'WifiGuardService: failed to pause ${torrent.id}: $e',
                );
              }
            }
          }());
        }
      }
      await Future.wait(futures);

      if (kDebugMode) {
        debugPrint(
          'WifiGuardService: paused ${_pausedByGuard.length} torrents',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('WifiGuardService _pauseAll error: $e');
    }
  }

  Future<void> _resumeAll() async {
    if (_disposed) return;
    if (_pausedByGuard.isEmpty) return;
    if (!getIt.isRegistered<Engine>()) {
      _pausedByGuard.clear();
      return;
    }

    final idsToResume = List<int>.from(_pausedByGuard);
    if (getIt.isRegistered<TorrentsModel>() &&
        getIt<TorrentsModel>().isQuotaPauseEnforced) {
      return;
    }

    try {
      final engine = getIt<Engine>();
      final torrents = await engine.fetchTorrents();
      if (_disposed) return;
      final existingIds = {for (final t in torrents) t.id};
      final futures = <Future<void>>[];

      for (final id in idsToResume) {
        if (!existingIds.contains(id)) {
          _pausedByGuard.remove(id);
          continue;
        }

        futures.add(() async {
          try {
            await engine.resumeTorrent(id);
            _pausedByGuard.remove(id);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('WifiGuardService: failed to resume $id: $e');
            }
          }
        }());
      }

      await Future.wait(futures);

      if (kDebugMode) {
        final resumedCount = idsToResume.length - _pausedByGuard.length;
        debugPrint('WifiGuardService: resumed $resumedCount torrents');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('WifiGuardService _resumeAll error: $e');
    }
  }

  /// Serialize async guard operations so pause/resume do not overlap.
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _unsubscribe();
  }
}
