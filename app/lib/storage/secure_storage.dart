import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:gravity_torrent/storage/shared_preferences.dart';

/// Thrown when secure storage (Keystore/Keychain) is unavailable and storing
/// the value in plain [SharedPreferences] would be unsafe.
class SecureStorageException implements Exception {
  final String message;
  SecureStorageException(this.message);

  @override
  String toString() => 'SecureStorageException: $message';
}

/// Keystore/Keychain-backed secure storage.
///
/// Uses [FlutterSecureStorage] on non-web platforms. On web it falls back to
/// [SharedPrefsStorage] because browsers do not provide a secure keychain.
///
/// By default a failure on a non-web platform throws [SecureStorageException]
/// rather than silently writing sensitive data to plain [SharedPreferences].
/// Tests can call [enableTestMode] to use [SharedPrefsStorage] instead.
class SecureStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static bool _testMode = false;

  /// Use [SharedPreferences] as the backing store. Intended for tests only.
  @visibleForTesting
  static void enableTestMode() => _testMode = true;

  /// Restore the real secure storage backend. Intended for tests only.
  @visibleForTesting
  static void disableTestMode() => _testMode = false;

  static bool get _useSharedPrefs => kIsWeb || _testMode;

  static Future<String?> getString(String key) async {
    if (_useSharedPrefs) return SharedPrefsStorage.getString(key);

    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SecureStorage.getString failed for $key: $e\n$st');
      }
      // Deliberately not deleting the entry here: the read failure may be
      // transient (e.g. Keystore not yet unlocked after a reboot), and
      // deleting it would permanently destroy a legitimate value on what
      // could be a one-off failure.
    }

    // Fall back to a legacy plaintext value written by an older app version,
    // if any (this class used to fall back to SharedPreferences on write
    // failure; new writes never do that, see setString).
    try {
      return await SharedPrefsStorage.getString(key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setString(String key, String value) async {
    if (_useSharedPrefs) {
      await SharedPrefsStorage.setString(key, value);
      return;
    }

    try {
      await _storage.write(key: key, value: value);
      return;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SecureStorage.setString failed for $key: $e\n$st');
      }
    }

    // Retry once after clearing a possibly invalidated hardware key entry
    // (e.g. an Android Keystore key invalidated by a biometric enrollment
    // change).
    try {
      await _storage.delete(key: key);
      await _storage.write(key: key, value: value);
    } catch (e) {
      // Never silently downgrade to plaintext SharedPreferences: callers
      // rely on this throwing rather than sensitive data being written
      // unencrypted.
      throw SecureStorageException('Unable to write to secure storage: $e');
    }
  }

  static Future<void> remove(String key) async {
    if (_useSharedPrefs) {
      await SharedPrefsStorage.remove(key);
      return;
    }

    try {
      await _storage.delete(key: key);
      try {
        await SharedPrefsStorage.remove(key);
      } catch (_) {}
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SecureStorage.remove failed for $key: $e\n$st');
      }
      try {
        await SharedPrefsStorage.remove(key);
      } catch (_) {}
    }
  }
}
