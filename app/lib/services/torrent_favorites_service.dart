import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';

/// Stores user-pinned (favorite) torrent IDs locally.
///
/// Favorites are kept in shared preferences and are never uploaded.
/// This works on every platform the app supports (Linux, Windows, macOS,
/// Android, iOS and web).
class TorrentFavoritesService {
  TorrentFavoritesService._();
  static final TorrentFavoritesService instance = TorrentFavoritesService._();

  static const _storageKey = 'gravity_torrent_favorites_v1';

  final Set<int> _favorites = {};
  bool _loaded = false;
  Future<void>? _lock;

  /// Serializes loads/saves so overlapping calls (e.g. two rapid toggles)
  /// can't complete their persistence writes out of order and silently
  /// drop an earlier update.
  Future<T> _withLock<T>(Future<T> Function() task) {
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

  Future<void> load() => _withLock(_loadImpl);

  Future<void> _loadImpl() async {
    if (_loaded) return;
    final raw = await SharedPrefsStorage.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _favorites.clear();
          for (final value in decoded) {
            if (value is int) {
              _favorites.add(value);
            } else if (value is String) {
              final parsed = int.tryParse(value);
              if (parsed != null) _favorites.add(parsed);
            }
          }
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('TorrentFavoritesService failed to load: $e\n$s');
        }
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    await SharedPrefsStorage.setString(
      _storageKey,
      jsonEncode(_favorites.toList()),
    );
  }

  /// Whether [torrentId] is currently pinned/favorited.
  bool isFavorite(int torrentId) {
    return _favorites.contains(torrentId);
  }

  /// All favorited torrent IDs.
  Set<int> get favoriteIds => Set.unmodifiable(_favorites);

  /// Sets the favorite state for [torrentId].
  Future<void> setFavorite(int torrentId, bool favorite) =>
      _withLock(() => _setFavoriteImpl(torrentId, favorite));

  Future<void> _setFavoriteImpl(int torrentId, bool favorite) async {
    await _loadImpl();
    if (favorite) {
      _favorites.add(torrentId);
    } else {
      _favorites.remove(torrentId);
    }
    await _save();
  }

  /// Toggles the favorite state for [torrentId].
  Future<bool> toggle(int torrentId) => _withLock(() => _toggleImpl(torrentId));

  Future<bool> _toggleImpl(int torrentId) async {
    await _loadImpl();
    final isFavorite = _favorites.contains(torrentId);
    if (isFavorite) {
      _favorites.remove(torrentId);
    } else {
      _favorites.add(torrentId);
    }
    await _save();
    return !isFavorite;
  }

  /// Removes all favorites.
  Future<void> clear() => _withLock(_clearImpl);

  Future<void> _clearImpl() async {
    _favorites.clear();
    await _save();
  }

  /// For tests.
  void reset() {
    _favorites.clear();
    _loaded = false;
  }
}
