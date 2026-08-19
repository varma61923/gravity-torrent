import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

class NotificationChannelService {
  NotificationChannelService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _keyDndRespect = 'notif_dnd_respect';
  static const _keyProgressEnabled = 'notif_channel_progress';
  static const _keyCompletionEnabled = 'notif_channel_completion';
  static const _keyErrorEnabled = 'notif_channel_error';
  static const _keyDataUsageEnabled = 'notif_channel_data_usage';

  static bool _initialized = false;
  static bool _initializing = false;
  static bool _disposed = false;
  static Future<void>? _lock;

  static bool get dndRespect => SharedPrefs.getBool(_keyDndRespect) ?? true;
  static bool get progressEnabled =>
      SharedPrefs.getBool(_keyProgressEnabled) ?? true;
  static bool get completionEnabled =>
      SharedPrefs.getBool(_keyCompletionEnabled) ?? true;
  static bool get errorEnabled => SharedPrefs.getBool(_keyErrorEnabled) ?? true;
  static bool get dataUsageEnabled =>
      SharedPrefs.getBool(_keyDataUsageEnabled) ?? true;

  /// Initialize all notification channels.
  ///
  /// The shared [FlutterLocalNotificationsPlugin] is already initialized by
  /// [initializeNotifications] in [utils/notifications.dart]; this method only
  /// ensures the new Android channels exist.
  static Future<void> initialize() async {
    if (_disposed || _initialized || _initializing) return;
    _initializing = true;
    try {
      // Create Android channels
      if (!kIsWeb && Platform.isAndroid) {
        await _createAndroidChannels();
      }
      _initialized = true;
    } finally {
      _initializing = false;
    }
  }

  static Future<void> _createAndroidChannels() async {
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    const channels = [
      AndroidNotificationChannel(
        'progress',
        'Download Progress',
        description: 'Shows download progress updates',
        importance: Importance.low,
        showBadge: false,
        playSound: false,
        enableVibration: false,
      ),
      AndroidNotificationChannel(
        'completion',
        'Download Complete',
        description: 'Notifies when a download finishes',
        importance: Importance.high,
        showBadge: true,
      ),
      AndroidNotificationChannel(
        'errors',
        'Errors',
        description: 'Error notifications',
        importance: Importance.high,
        showBadge: true,
      ),
      AndroidNotificationChannel(
        'data_usage',
        'Data Usage Alerts',
        description: 'Alerts when data usage approaches limits',
        importance: Importance.high,
        showBadge: true,
      ),
      AndroidNotificationChannel(
        'foreground_service_channel',
        'Background Service',
        description: 'Keeps the torrent engine running',
        importance: Importance.min,
        showBadge: false,
        playSound: false,
        enableVibration: false,
      ),
    ];

    for (final channel in channels) {
      await androidPlugin.createNotificationChannel(channel);
    }
  }

  // ── Show notifications ──────────────────────────────────────────────────

  static Future<void> showProgress({
    required int id,
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
  }) async {
    if (_disposed || !progressEnabled) return;

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'progress',
          'Download Progress',
          channelDescription: 'Shows download progress updates',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
        ),
      ),
      payload: 'progress:$id',
    );
  }

  static Future<void> showCompletion({
    required int id,
    required String title,
    required String body,
  }) async {
    if (_disposed || !completionEnabled) return;

    // Cancel any progress notification for this torrent
    await _plugin.cancel(id: id);

    await _plugin.show(
      id: id + 100000, // Offset to avoid collision with progress IDs
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'completion',
          'Download Complete',
          channelDescription: 'Notifies when a download finishes',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'completion:$id',
    );
  }

  static Future<void> showError({
    required int id,
    required String title,
    required String body,
  }) async {
    if (_disposed || !errorEnabled) return;

    await _plugin.show(
      id: id + 200000,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'errors',
          'Errors',
          channelDescription: 'Error notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'error:$id',
    );
  }

  static Future<void> showDataUsage({
    required int id,
    required String title,
    required String body,
  }) async {
    if (_disposed || !dataUsageEnabled) return;

    await _plugin.show(
      id: id + 300000,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'data_usage',
          'Data Usage Alerts',
          channelDescription: 'Alerts when data usage approaches limits',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'data_usage:$id',
    );
  }

  static Future<void> cancelAll() async {
    if (_disposed) return;
    await _plugin.cancelAll();
  }

  static Future<void> cancel(int id) async {
    if (_disposed) return;
    await _plugin.cancel(id: id);
  }

  // ── Settings ────────────────────────────────────────────────────────────

  static Future<void> setDndRespect(bool value) async =>
      _withLock(() => _setBool(_keyDndRespect, value));

  static Future<void> setProgressEnabled(bool value) async =>
      _withLock(() => _setBool(_keyProgressEnabled, value));

  static Future<void> setCompletionEnabled(bool value) async =>
      _withLock(() => _setBool(_keyCompletionEnabled, value));

  static Future<void> setErrorEnabled(bool value) async =>
      _withLock(() => _setBool(_keyErrorEnabled, value));

  static Future<void> setDataUsageEnabled(bool value) async =>
      _withLock(() => _setBool(_keyDataUsageEnabled, value));

  static Future<void> _setBool(String key, bool value) async {
    if (_disposed) return;
    await SharedPrefs.setBool(key, value);
  }

  static Future<T> _withLock<T>(Future<T> Function() task) {
    final previous = _lock;
    final current = Future<T>(() async {
      if (previous != null) await previous;
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

  static void dispose() {
    _disposed = true;
    _initialized = false;
    _initializing = false;
  }
}

// Expose a standalone helper that existing code (e.g. data_usage_alert_service)
// can call without knowing about the channel service internals.
Future<void> showLocalNotification({
  required int id,
  required String title,
  required String body,
  String channel = 'completion',
}) async {
  switch (channel) {
    case 'progress':
      await NotificationChannelService.showProgress(
        id: id,
        title: title,
        body: body,
        progress: 0,
        maxProgress: 100,
      );
      break;
    case 'errors':
      await NotificationChannelService.showError(
        id: id,
        title: title,
        body: body,
      );
      break;
    case 'data_usage':
      await NotificationChannelService.showDataUsage(
        id: id,
        title: title,
        body: body,
      );
      break;
    case 'completion':
    default:
      await NotificationChannelService.showCompletion(
        id: id,
        title: title,
        body: body,
      );
  }
}
