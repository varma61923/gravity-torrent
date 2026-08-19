import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

/// Manages in-app review prompts respecting platform quotas and user fatigue.
///
/// Trigger conditions:
///   • After the 3rd successful download (lifetime).
///   • After the 10th app launch.
///   • No more than once every 90 days.
///   • Never on Windows/Linux (no native API); uses [openStoreListing] fallback.
class InAppReviewService {
  InAppReviewService._();

  static const _keyLaunchCount = 'review_launch_count';
  static const _keyDownloadCount = 'review_download_count';
  static const _keyLastPromptMs = 'review_last_prompt_ms';
  static const _keyUserDeclined = 'review_user_declined';

  static const int _launchThreshold = 10;
  static const int _downloadThreshold = 3;
  static const Duration _cooldown = Duration(days: 90);

  static final InAppReview _inAppReview = InAppReview.instance;

  // Guards against concurrent/duplicate review prompts from async hooks.
  static bool _prompting = false;

  // ── Lifecycle hooks ──────────────────────────────────────────────────────

  /// Call once per app cold-start.
  static Future<void> recordLaunch() async {
    final count = (SharedPrefs.getInt(_keyLaunchCount) ?? 0) + 1;
    await SharedPrefs.setInt(_keyLaunchCount, count);
    if (count == _launchThreshold) {
      await _maybePrompt();
    }
  }

  /// Call after every torrent finishes downloading.
  static Future<void> recordSuccessfulDownload() async {
    final count = (SharedPrefs.getInt(_keyDownloadCount) ?? 0) + 1;
    await SharedPrefs.setInt(_keyDownloadCount, count);
    if (count == _downloadThreshold) {
      await _maybePrompt();
    }
  }

  // ── Core logic ───────────────────────────────────────────────────────────

  static Future<void> _maybePrompt() async {
    if (_prompting) return;
    _prompting = true;
    try {
      if (SharedPrefs.getBool(_keyUserDeclined) == true) return;

      final lastMs = SharedPrefs.getInt(_keyLastPromptMs) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastMs < _cooldown.inMilliseconds) return;

      if (_isDesktopWithoutNativeSupport) {
        // Windows / Linux have no native modal in-app review API.
        // Do not automatically launch external browser/store windows without user interaction.
        return;
      }

      try {
        if (await _inAppReview.isAvailable()) {
          await _inAppReview.requestReview();
          await SharedPrefs.setInt(_keyLastPromptMs, now);
        }
      } catch (e, st) {
        debugPrint('InAppReviewService: requestReview failed — $e\n$st');
      }
    } finally {
      _prompting = false;
    }
  }

  /// Opens the platform store listing. Safe to call from a settings button.
  static Future<void> openStoreListing() => _openStoreListing();

  // TODO: Replace the default placeholder store IDs with your real listings
  // before release. Pass real IDs at build time, e.g.:
  //   --dart-define=GRAVITY_APP_STORE_ID=1234567890
  //   --dart-define=GRAVITY_MICROSOFT_STORE_ID=9XXXXXXXXXXXX
  static const String _appStoreId = String.fromEnvironment(
    'GRAVITY_APP_STORE_ID',
    defaultValue: '6446908518', // replace with real Apple App Store ID
  );
  static const String _microsoftStoreId = String.fromEnvironment(
    'GRAVITY_MICROSOFT_STORE_ID',
    defaultValue: '9XXXXXXXXXXXX', // replace with real Microsoft Store ID
  );

  static Future<void> _openStoreListing() async {
    try {
      await _inAppReview.openStoreListing(
        appStoreId: _appStoreId,
        microsoftStoreId: _microsoftStoreId,
      );
    } catch (e, st) {
      debugPrint('InAppReviewService: openStoreListing failed — $e\n$st');
    }
  }

  /// Let user permanently suppress review prompts.
  static Future<void> declineReviews() async {
    await SharedPrefs.setBool(_keyUserDeclined, true);
  }

  static bool get _isDesktopWithoutNativeSupport =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);
}
