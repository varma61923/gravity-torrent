import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:gravity_torrent/storage/secure_storage.dart';

/// Thrown when the user has exceeded the maximum number of failed PIN attempts.
class PinLockoutException implements Exception {
  final Duration remaining;

  PinLockoutException(this.remaining);

  @override
  String toString() {
    if (remaining.inMinutes > 0) {
      return 'Too many failed attempts. Try again in ${remaining.inMinutes} minute${remaining.inMinutes > 1 ? 's' : ''}.';
    }
    final secs = remaining.inSeconds.clamp(1, 60);
    return 'Too many failed attempts. Try again in $secs second${secs > 1 ? 's' : ''}.';
  }
}

/// Secure PIN storage and verification.
///
/// PINs are never stored in plain text. A random salt is generated for each PIN
/// and the salted input is hashed with SHA-256. Verification uses a constant-
/// time comparison to mitigate timing attacks, and repeated failures trigger a
/// rate-limiting lockout that persists across app restarts.
class PinService {
  PinService._();
  static final PinService instance = PinService._();

  static const _pinHashKey = 'gravity_torrent_app_lock_pin_hash';
  static const _pinSaltKey = 'gravity_torrent_app_lock_pin_salt';
  static const _failedAttemptsKey =
      'gravity_torrent_app_lock_pin_failed_attempts';
  static const _lockoutUntilKey = 'gravity_torrent_app_lock_pin_lockout_until';

  /// Legacy single-key storage used by earlier versions (format: "salt:hash").
  static const _legacyPinKey = 'gravity_torrent_app_lock_pin';

  static const int maxFailedAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 5);

  String _pinHash = '';
  String? _pinSalt;
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;

  /// Whether a PIN has been set.
  bool get hasPin => _pinHash.isNotEmpty;

  /// Loads the stored PIN hash, salt, and rate-limiting state from secure
  /// storage. Migrates the legacy combined key format if needed.
  Future<void> load() async {
    _pinHash = await SecureStorage.getString(_pinHashKey) ?? '';
    _pinSalt = await SecureStorage.getString(_pinSaltKey);

    // Migrate old "salt:hash" single-key format to the separated key format.
    final saltIsMissing = _pinSalt == null || _pinSalt!.isEmpty;
    if (_pinHash.isEmpty || saltIsMissing) {
      final legacy = await SecureStorage.getString(_legacyPinKey);
      if (legacy != null && legacy.contains(':')) {
        final parts = legacy.split(':');
        if (parts.length == 2) {
          _pinSalt = parts[0];
          _pinHash = parts[1];
          await Future.wait([
            SecureStorage.setString(_pinSaltKey, _pinSalt!),
            SecureStorage.setString(_pinHashKey, _pinHash),
            SecureStorage.remove(_legacyPinKey),
          ]);
        }
      } else if (_pinHash.isNotEmpty) {
        _pinHash = '';
        await SecureStorage.remove(_pinHashKey);
      }
    }

    final attemptsStr = await SecureStorage.getString(_failedAttemptsKey);
    _failedAttempts = int.tryParse(attemptsStr ?? '0') ?? 0;

    final lockoutStr = await SecureStorage.getString(_lockoutUntilKey);
    _lockoutUntil = lockoutStr == null ? null : DateTime.tryParse(lockoutStr);
  }

  /// Stores a new [pin] securely.
  ///
  /// Throws [ArgumentError] if the PIN is not 4-8 digits.
  Future<void> setPin(String pin) async {
    if (pin.length < 4 || pin.length > 8) {
      throw ArgumentError('PIN must be 4-8 digits');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain only digits');
    }

    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);

    _pinSalt = salt;
    _pinHash = hash;
    _failedAttempts = 0;
    _lockoutUntil = null;

    await Future.wait([
      SecureStorage.setString(_pinSaltKey, salt),
      SecureStorage.setString(_pinHashKey, hash),
      SecureStorage.setString(_failedAttemptsKey, '0'),
      SecureStorage.remove(_lockoutUntilKey),
      SecureStorage.remove(_legacyPinKey),
    ]);
  }

  /// Verifies [pin] against the stored hash.
  ///
  /// Returns `true` if correct, `false` if wrong, and throws
  /// [PinLockoutException] when the account is temporarily locked.
  Future<bool> verifyPin(String pin) async {
    final lockoutUntil = _lockoutUntil;
    if (lockoutUntil != null && DateTime.now().isBefore(lockoutUntil)) {
      throw PinLockoutException(lockoutUntil.difference(DateTime.now()));
    }

    // Clear an expired lockout before attempting verification.
    if (lockoutUntil != null) {
      _lockoutUntil = null;
      _failedAttempts = 0;
      await _persistLockoutState();
    }

    if (_pinHash.isEmpty || pin.isEmpty) return false;

    final salt = _pinSalt ?? await SecureStorage.getString(_pinSaltKey);
    if (salt == null || salt.isEmpty) return false;
    _pinSalt = salt;

    final hash = _hashPin(pin, salt);

    if (!_constantTimeCompare(hash, _pinHash)) {
      _failedAttempts++;
      if (_failedAttempts >= maxFailedAttempts) {
        _lockoutUntil = DateTime.now().add(lockoutDuration);
        await _persistLockoutState();
        throw PinLockoutException(lockoutDuration);
      }
      await _persistLockoutState();
      return false;
    }

    _failedAttempts = 0;
    _lockoutUntil = null;
    await _persistLockoutState();
    return true;
  }

  /// Clears the stored PIN and rate-limiting state.
  Future<void> clearPin() async {
    _pinHash = '';
    _pinSalt = null;
    _failedAttempts = 0;
    _lockoutUntil = null;

    await Future.wait([
      SecureStorage.remove(_pinHashKey),
      SecureStorage.remove(_pinSaltKey),
      SecureStorage.remove(_failedAttemptsKey),
      SecureStorage.remove(_lockoutUntilKey),
      SecureStorage.remove(_legacyPinKey),
    ]);
  }

  Future<void> _persistLockoutState() async {
    await Future.wait([
      SecureStorage.setString(_failedAttemptsKey, '$_failedAttempts'),
      _lockoutUntil == null
          ? SecureStorage.remove(_lockoutUntilKey)
          : SecureStorage.setString(
              _lockoutUntilKey,
              _lockoutUntil!.toIso8601String(),
            ),
    ]);
  }

  String _hashPin(String pin, String salt) {
    final saltBytes = utf8.encode(salt);
    final pinBytes = utf8.encode(pin);
    final derivedKey = _pbkdf2HmacSha256(
      password: pinBytes,
      salt: saltBytes,
      iterations: 100000,
      keyLength: 32,
    );
    return base64Url.encode(derivedKey);
  }

  List<int> _pbkdf2HmacSha256({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyLength,
  }) {
    const blockSize = 32; // SHA-256 output size
    final blocks = (keyLength + blockSize - 1) ~/ blockSize;
    final derivedKey = <int>[];

    for (var i = 1; i <= blocks; i++) {
      final block = _pbkdf2Block(password, salt, i, iterations);
      derivedKey.addAll(block);
    }

    return derivedKey.sublist(0, keyLength);
  }

  List<int> _pbkdf2Block(
    List<int> password,
    List<int> salt,
    int blockIndex,
    int iterations,
  ) {
    final hmac = Hmac(sha256, password);
    final blockIndexBytes = [
      (blockIndex >> 24) & 0xff,
      (blockIndex >> 16) & 0xff,
      (blockIndex >> 8) & 0xff,
      blockIndex & 0xff,
    ];
    final saltWithIndex = [...salt, ...blockIndexBytes];

    var u = hmac.convert(saltWithIndex).bytes;
    final result = List<int>.from(u);

    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return result;
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  bool _constantTimeCompare(String a, String b) {
    // Constant-time even when lengths differ so the caller cannot learn the
    // secret length via a fast-path. Tokens and hashes are fixed-length in
    // practice, but we still avoid the early-return timing leak.
    var result = a.length ^ b.length;
    final maxLen = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < maxLen; i++) {
      final ca = i < a.length ? a.codeUnitAt(i) : 0;
      final cb = i < b.length ? b.codeUnitAt(i) : 0;
      result |= ca ^ cb;
    }
    return result == 0;
  }
}
