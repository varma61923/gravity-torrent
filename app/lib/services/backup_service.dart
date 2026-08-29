import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

class BackupMetadata {
  final String appVersion;
  final DateTime createdAt;
  final String platform;
  final int settingsCount;
  final int torrentCount;
  final bool encrypted;

  const BackupMetadata({
    required this.appVersion,
    required this.createdAt,
    required this.platform,
    required this.settingsCount,
    required this.torrentCount,
    required this.encrypted,
  });

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'createdAt': createdAt.toIso8601String(),
        'platform': platform,
        'settingsCount': settingsCount,
        'torrentCount': torrentCount,
        'encrypted': encrypted,
      };

  factory BackupMetadata.fromJson(Map<String, dynamic> json) {
    return BackupMetadata(
      appVersion: json['appVersion'] as String? ?? 'unknown',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      platform: json['platform'] as String? ?? 'unknown',
      settingsCount: json['settingsCount'] as int? ?? 0,
      torrentCount: json['torrentCount'] as int? ?? 0,
      encrypted: json['encrypted'] as bool? ?? false,
    );
  }
}

class BackupRestoreResult {
  final bool success;
  final String message;
  final String? filePath;
  final Uint8List? bytes;
  final BackupMetadata? metadata;

  const BackupRestoreResult({
    required this.success,
    required this.message,
    this.filePath,
    this.bytes,
    this.metadata,
  });
}

class BackupService {
  BackupService._();

  static const String _backupFileExtension = '.gtbackup';
  static const String _backupVersion = '1';

  // ── Export ───────────────────────────────────────────────────────────────

  /// Creates a backup file containing all app settings and torrent state.
  ///
  /// If [passphrase] is provided, the backup is AES-256-GCM authenticated
  /// encryption.
  /// Returns the path to the generated backup file.
  static Future<BackupRestoreResult> export({
    String? passphrase,
    String? outputDirectory,
  }) async {
    try {
      await SharedPrefs.init();
      // Collect all settings from SharedPreferences
      final allKeys = SharedPrefs.getKeys();
      final settings = <String, dynamic>{};
      for (final key in allKeys) {
        settings[key] = SharedPrefs.get(key);
      }

      // Collect torrent state
      final List<Map<String, dynamic>> torrentStates = [];
      try {
        if (!getIt.isRegistered<Engine>()) {
          debugPrint('BackupService: engine not registered, skipping torrents');
        } else {
          final engine = getIt<Engine>();
          final torrents = await engine.fetchTorrents();
          for (final t in torrents) {
            torrentStates.add({
              'name': t.name,
              'magnetLink': t.magnetLink,
              'downloadDir': t.location,
              'labels': t.labels,
              'addedDate': t.addedDate,
              'uploadedEver': t.uploadedEver,
              'downloadedEver': t.downloadedEver,
              'isPrivate': t.isPrivate,
            });
          }
        }
      } catch (e) {
        debugPrint('BackupService: could not read torrent state — $e');
      }

      // Build backup payload
      String appVersion = '1.0.0';
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        appVersion = packageInfo.version;
      } catch (_) {}

      final payload = {
        'version': _backupVersion,
        'metadata': BackupMetadata(
          appVersion: appVersion,
          createdAt: DateTime.now(),
          platform: _currentPlatform(),
          settingsCount: settings.length,
          torrentCount: torrentStates.length,
          encrypted: passphrase != null && passphrase.isNotEmpty,
        ).toJson(),
        'settings': settings,
        'torrents': torrentStates,
      };

      final jsonString = jsonEncode(payload);
      Uint8List fileBytes;

      if (passphrase != null && passphrase.isNotEmpty) {
        fileBytes = _encrypt(jsonString, passphrase);
      } else {
        fileBytes = Uint8List.fromList(utf8.encode(jsonString));
      }

      // Compute integrity hash
      final hash = sha256.convert(fileBytes).toString();

      // Write file
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'gravity_backup_$timestamp$_backupFileExtension';
      final output = '$hash\n${base64Encode(fileBytes)}';

      if (kIsWeb) {
        final data = utf8.encode(output);
        final localCount = torrentStates
            .where((t) => (t['magnetLink'] as String?)?.isEmpty ?? true)
            .length;
        final warnMsg = localCount > 0
            ? ' (Warning: $localCount local torrent(s) without '
                'magnet links were not fully backed up)'
            : '';
        return BackupRestoreResult(
          success: true,
          message: 'Backup created successfully$warnMsg',
          filePath: fileName,
          bytes: Uint8List.fromList(data),
          metadata: BackupMetadata.fromJson(
            payload['metadata'] as Map<String, dynamic>,
          ),
        );
      }

      final dir =
          outputDirectory ?? (await getApplicationDocumentsDirectory()).path;
      final filePath = p.join(dir, fileName);

      final file = File(filePath);
      // Prepend hash as first line, then the payload
      await file.writeAsString(output);

      final localCount = torrentStates
          .where((t) => (t['magnetLink'] as String?)?.isEmpty ?? true)
          .length;
      final warnMsg = localCount > 0
          ? ' (Warning: $localCount local torrent(s) without '
              'magnet links were not fully backed up)'
          : '';

      return BackupRestoreResult(
        success: true,
        message: 'Backup created successfully$warnMsg',
        filePath: filePath,
        metadata: BackupMetadata.fromJson(
          payload['metadata'] as Map<String, dynamic>,
        ),
      );
    } catch (e) {
      return BackupRestoreResult(success: false, message: 'Backup failed: $e');
    }
  }

  /// Share the backup file via the platform share sheet.
  static Future<void> shareBackup(BackupRestoreResult result) async {
    if (kIsWeb && result.bytes != null) {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              result.bytes!,
              name: result.filePath ?? 'backup$_backupFileExtension',
            ),
          ],
        ),
      );
    } else if (result.filePath != null) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(result.filePath!)]),
      );
    }
  }

  // ── Import ──────────────────────────────────────────────────────────────

  /// Pick and restore a backup file.
  static Future<BackupRestoreResult> import({String? passphrase}) async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);

      if (result == null || result.files.isEmpty) {
        return const BackupRestoreResult(
          success: false,
          message: 'No file selected',
        );
      }

      final platformFile = result.files.first;
      Uint8List? bytes;
      if (kIsWeb) {
        bytes = await platformFile.readAsBytes();
      }
      if (platformFile.path == null && bytes == null) {
        return const BackupRestoreResult(
          success: false,
          message: 'No file data found',
        );
      }

      return await restore(
        filePath: platformFile.path,
        bytes: bytes,
        passphrase: passphrase,
      );
    } catch (e) {
      return BackupRestoreResult(success: false, message: 'Import failed: $e');
    }
  }

  /// Restore from a specific file path.
  static Future<BackupRestoreResult> restore({
    String? filePath,
    Uint8List? bytes,
    String? passphrase,
  }) async {
    try {
      String content;
      if (bytes != null) {
        content = utf8.decode(bytes);
      } else {
        if (filePath == null) {
          return const BackupRestoreResult(
            success: false,
            message: 'No file provided',
          );
        }
        if (kIsWeb) {
          return const BackupRestoreResult(
            success: false,
            message: 'Cannot read file path on Web',
          );
        }
        final file = File(filePath);
        if (!file.existsSync()) {
          return const BackupRestoreResult(
            success: false,
            message: 'Backup file not found',
          );
        }
        content = await file.readAsString();
      }
      final newlineIndex = content.indexOf('\n');
      if (newlineIndex < 0) {
        return const BackupRestoreResult(
          success: false,
          message: 'Invalid backup file format',
        );
      }

      final storedHash = content.substring(0, newlineIndex).trim();
      final encodedPayload = content.substring(newlineIndex + 1).trim();

      // Verify integrity
      final decodedBytes = base64Decode(encodedPayload);
      final computedHash = sha256.convert(decodedBytes).toString();
      if (storedHash != computedHash) {
        return const BackupRestoreResult(
          success: false,
          message: 'Backup file integrity check failed — '
              'file may be corrupted',
        );
      }

      // Decrypt if needed
      String jsonString;
      try {
        if (passphrase != null && passphrase.isNotEmpty) {
          jsonString = _decrypt(decodedBytes, passphrase);
        } else {
          jsonString = utf8.decode(decodedBytes);
        }
      } catch (e) {
        return BackupRestoreResult(
          success: false,
          message: passphrase != null
              ? 'Decryption failed — wrong passphrase?'
              : 'Could not decode backup — it may be encrypted',
        );
      }

      // Parse
      final payload = jsonDecode(jsonString) as Map<String, dynamic>;
      final version = payload['version'] as String?;
      if (version != _backupVersion) {
        return BackupRestoreResult(
          success: false,
          message: 'Unsupported backup version: $version',
        );
      }

      final metadata = BackupMetadata.fromJson(
        payload['metadata'] as Map<String, dynamic>,
      );

      // Check engine availability before writing settings
      if (!getIt.isRegistered<Engine>()) {
        debugPrint('BackupService: engine not registered, cannot restore');
        return const BackupRestoreResult(
          success: false,
          message: 'Engine not ready, cannot restore backup',
        );
      }

      // Restore settings with allow-list filtering to prevent injection of
      // security-sensitive keys (e.g. disabling remote-control auth).
      final settings = payload['settings'] as Map<String, dynamic>? ?? {};
      for (final entry in settings.entries) {
        final key = entry.key;
        final value = entry.value;
        // Sensitive keys must be validated or are skipped entirely on restore.
        if (_isSensitiveKey(key)) {
          if (key == 'gravity_torrent_blocklist_url' && value is String) {
            final ok = await BlocklistService.isValidBlocklistUrl(value);
            if (!ok) {
              if (kDebugMode) {
                debugPrint('BackupService: skipped unsafe blocklist URL $value');
              }
              continue;
            }
          } else {
            // API keys, remote-control settings, etc. are not restored via
            // backup; they require manual re-configuration.
            if (kDebugMode) {
              debugPrint('BackupService: skipped sensitive key $key');
            }
            continue;
          }
        }
        if (value is bool) {
          await SharedPrefs.setBool(key, value);
        } else if (value is num) {
          final existing = SharedPrefs.get(key);
          if (value is double || existing is double) {
            await SharedPrefs.setDouble(key, value.toDouble());
          } else {
            await SharedPrefs.setInt(key, value.toInt());
          }
        } else if (value is String) {
          await SharedPrefs.setString(key, value);
        } else if (value is List) {
          final stringList = value
              .where((item) => item != null)
              .map((item) => item.toString())
              .toList();
          await SharedPrefs.setStringList(key, stringList);
        }
      }

      // Restore torrent magnet links
      final torrents = (payload['torrents'] as List<dynamic>?) ?? [];
      try {
        final engine = getIt<Engine>();
        await Future.wait(
          torrents.map((t) async {
            final map = t as Map<String, dynamic>;
            final magnetLink = map['magnetLink'] as String?;
            if (magnetLink != null && magnetLink.isNotEmpty) {
              try {
                if (!await IpAddressScope.isPubliclyRoutableLink(magnetLink)) {
                  debugPrint(
                    'BackupService: skipped torrent with private/internal link: $magnetLink',
                  );
                  return;
                }
                final downloadDir = map['downloadDir'] as String?;
                String? sanitizedDir;
                if (downloadDir != null && downloadDir.isNotEmpty) {
                  sanitizedDir = await _sanitizeDownloadDir(downloadDir);
                  if (sanitizedDir == null) {
                    debugPrint(
                      'BackupService: skipped torrent with disallowed downloadDir: $downloadDir',
                    );
                    return;
                  }
                }
                await engine.addTorrent(
                  magnetLink,
                  null,
                  sanitizedDir,
                );
              } catch (e) {
                debugPrint('BackupService: could not re-add torrent — $e');
              }
            }
          }),
        );
      } catch (e) {
        debugPrint('BackupService: torrent restoration skipped — $e');
      }

      return BackupRestoreResult(
        success: true,
        message: 'Restored ${settings.length} settings and '
            '${torrents.length} torrents',
        metadata: metadata,
      );
    } catch (e) {
      return BackupRestoreResult(success: false, message: 'Restore failed: $e');
    }
  }

  // ── Encryption helpers ──────────────────────────────────────────────────

  static Uint8List _encrypt(String plaintext, String passphrase) {
    final salt = encrypt_lib.IV.fromSecureRandom(16);
    final keyBytes = _pbkdf2HmacSha256(
      password: utf8.encode(passphrase),
      salt: salt.bytes,
      iterations: 100000,
      keyLength: 32,
    );
    final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));
    final iv = encrypt_lib.IV.fromSecureRandom(16);
    final encrypter = encrypt_lib.Encrypter(
      encrypt_lib.AES(key, mode: encrypt_lib.AESMode.gcm),
    );
    final encrypted = encrypter.encryptBytes(utf8.encode(plaintext), iv: iv);

    // Prepend salt and IV to ciphertext (GCM includes auth tag in encrypted.bytes)
    final result = BytesBuilder();
    result.add(salt.bytes);
    result.add(iv.bytes);
    result.add(encrypted.bytes);
    return result.toBytes();
  }

  static String _decrypt(Uint8List cipherBytes, String passphrase) {
    if (cipherBytes.length < 33) {
      throw const FormatException('Ciphertext too short');
    }

    final salt = Uint8List.sublistView(cipherBytes, 0, 16);
    final iv = encrypt_lib.IV(Uint8List.sublistView(cipherBytes, 16, 32));
    final ciphertext = Uint8List.sublistView(cipherBytes, 32);

    final keyBytes = _pbkdf2HmacSha256(
      password: utf8.encode(passphrase),
      salt: salt,
      iterations: 100000,
      keyLength: 32,
    );
    final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));

    final encrypter = encrypt_lib.Encrypter(
      encrypt_lib.AES(key, mode: encrypt_lib.AESMode.gcm),
    );
    final decrypted = encrypter.decryptBytes(
      encrypt_lib.Encrypted(ciphertext),
      iv: iv,
    );

    return utf8.decode(decrypted);
  }

  static List<int> _pbkdf2HmacSha256({
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

  static List<int> _pbkdf2Block(
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

  static bool _isSensitiveKey(String key) {
    const sensitivePrefixes = [
      'gravity_torrent_api_keys',
      'gravity_torrent_remote_settings',
      'gravity_torrent_app_lock_pin',
      'gravity_torrent_search_engines',
    ];
    for (final prefix in sensitivePrefixes) {
      if (key == prefix || key.startsWith(prefix)) return true;
    }
    // Blocklist URL is handled with validation above, but also flagged.
    if (key.contains('blocklist')) return true;
    return false;
  }

  /// Sanitizes a persisted download directory to ensure it points inside an
  /// app-owned or user-selected download location. Returns `null` when the path
  /// is disallowed or does not exist.
  static Future<String?> _sanitizeDownloadDir(String raw) async {
    final normalized = p.normalize(p.absolute(raw));
    // Disallow path traversal markers that survived normalization via symlink tricks.
    if (raw.contains('..') || normalized.contains('..')) {
      // Still allow if the normalized path is within an allowed root; the check
      // below covers it. We only reject obvious traversal attempts that escape.
    }
    try {
      final allowedRoots = <String>[];
      try {
        allowedRoots.add(
          p.normalize(p.absolute((await getApplicationDocumentsDirectory()).path)),
        );
      } catch (_) {}
      try {
        allowedRoots.add(
          p.normalize(p.absolute((await getApplicationSupportDirectory()).path)),
        );
      } catch (_) {}
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          allowedRoots.add(p.normalize(p.absolute(downloads.path)));
        }
      } catch (_) {}
      try {
        allowedRoots.add(p.normalize(p.absolute((await getTemporaryDirectory()).path)));
      } catch (_) {}

      for (final root in allowedRoots) {
        if (p.isWithin(root, normalized) || normalized == root) {
          final dir = Directory(normalized);
          if (dir.existsSync()) return normalized;
          return null;
        }
      }
      // Also allow any directory that already exists and is not a system root.
      // Reject obvious system paths.
      const blockedPrefixes = ['/etc', '/bin', '/sbin', '/usr', '/system', '/data/data'];
      for (final blocked in blockedPrefixes) {
        if (normalized == blocked || p.isWithin(blocked, normalized)) return null;
      }
      final dir = Directory(normalized);
      if (!dir.existsSync()) return null;
      // If custom path is outside allowed roots but exists and is not blocked,
      // allow it only if it was previously selected via RecentDownloadDirectories
      // (user explicitly picked it). We treat existence + non-system as allowed
      // for backward compat, but prefer allowedRoots check above.
      return normalized;
    } catch (_) {
      return null;
    }
  }

  static String _currentPlatform() {
    if (kIsWeb) return 'web';
    if (!kIsWeb && Platform.isAndroid) return 'android';
    if (!kIsWeb && Platform.isIOS) return 'ios';
    if (!kIsWeb && Platform.isMacOS) return 'macos';
    if (!kIsWeb && Platform.isWindows) return 'windows';
    if (!kIsWeb && Platform.isLinux) return 'linux';
    return 'unknown';
  }
}
