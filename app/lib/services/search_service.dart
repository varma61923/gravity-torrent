import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:http/http.dart' as http;

class SearchResult {
  final String title;
  final String magnetLink;
  final String? torrentUrl;
  final int size;
  final int seeders;
  final int leechers;
  final String source;

  SearchResult({
    required this.title,
    required this.magnetLink,
    this.torrentUrl,
    required this.size,
    required this.seeders,
    required this.leechers,
    required this.source,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      title: json['title'] as String? ?? '',
      magnetLink: json['magnetLink'] as String? ?? '',
      torrentUrl: json['torrentUrl'] as String?,
      size: (json['size'] as num?)?.toInt() ?? 0,
      seeders: (json['seeders'] as num?)?.toInt() ?? 0,
      leechers: (json['leechers'] as num?)?.toInt() ?? 0,
      source: json['source'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'magnetLink': magnetLink,
      'torrentUrl': torrentUrl,
      'size': size,
      'seeders': seeders,
      'leechers': leechers,
      'source': source,
    };
  }
}

class SearchEngine {
  final String name;
  final String baseUrl;
  final String searchPath;
  final bool enabled;

  SearchEngine({
    required this.name,
    required this.baseUrl,
    required this.searchPath,
    this.enabled = true,
  });

  factory SearchEngine.fromJson(Map<String, dynamic> json) {
    return SearchEngine(
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      searchPath: json['searchPath'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'baseUrl': baseUrl,
      'searchPath': searchPath,
      'enabled': enabled,
    };
  }
}

class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();

  static const _enginesKey = 'gravity_torrent_search_engines';
  static const _historyKey = 'gravity_torrent_search_history';
  static const _maxHistory = 50;

  List<SearchEngine> _engines = [];
  List<String> _searchHistory = [];
  bool _loaded = false;

  List<SearchEngine> get engines => List.unmodifiable(_engines);
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  Future<void> load() async {
    if (_loaded) return;

    // Load custom engines
    final rawEngines = await _getString(_enginesKey);
    if (rawEngines != null && rawEngines.isNotEmpty) {
      try {
        final list = jsonDecode(rawEngines) as List<dynamic>;
        _engines = list
            .whereType<Map<String, dynamic>>()
            .map((e) => SearchEngine.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('Failed to load search engines: $e\n$s');
        }
        _engines = [];
      }
    }

    // Load search history
    final rawHistory = await _getString(_historyKey);
    if (rawHistory != null && rawHistory.isNotEmpty) {
      try {
        final list = jsonDecode(rawHistory) as List<dynamic>;
        _searchHistory = list.map((e) => e.toString()).toList();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('Failed to load search history: $e\n$s');
        }
        _searchHistory = [];
      }
    }

    // Filter out persisted engines that now fail the public-host gate
    // (e.g. a legacy entry pointing at a private host).
    if (_engines.isNotEmpty) {
      final filtered = <SearchEngine>[];
      for (final e in _engines) {
        final uri = Uri.tryParse(e.baseUrl);
        if (uri == null ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        if (!IpAddressScope.isPubliclyRoutableHostSync(uri.host)) {
          if (kDebugMode) {
            debugPrint('SearchService: dropping private engine ${e.baseUrl}');
          }
          continue;
        }
        filtered.add(e);
      }
      // Persist the filtered list so the bad entry does not keep reloading.
      if (filtered.length != _engines.length) {
        _engines = filtered;
        await _saveEngines();
      }
    }

    // Add default engines if none exist
    if (_engines.isEmpty) {
      _engines = _getDefaultEngines();
    }

    _loaded = true;
  }

  Future<String?> _getString(String key) async {
    return SharedPrefsStorage.getString(key);
  }

  Future<void> _setString(String key, String value) async {
    await SharedPrefsStorage.setString(key, value);
  }

  List<SearchEngine> _getDefaultEngines() {
    return [
      SearchEngine(
        name: 'The Pirate Bay',
        baseUrl: 'https://thepiratebay.org',
        searchPath: '/search/{query}/0/99/0',
      ),
      SearchEngine(
        name: '1337x',
        baseUrl: 'https://1337x.to',
        searchPath: '/search/{query}/1/',
      ),
      SearchEngine(
        name: 'RARBG',
        baseUrl: 'https://rarbg.to',
        searchPath: '/torrents.php?search={query}',
      ),
    ];
  }

  /// Validates that [engine]'s URLs are safe, public HTTP(S) endpoints.
  static Future<bool> isValidEngineUrl(SearchEngine engine) async {
    final uri = Uri.tryParse(engine.baseUrl);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false;
    return IpAddressScope.isPubliclyRoutableHost(uri.host);
  }

  Future<void> addEngine(SearchEngine engine) async {
    await load();
    if (!await isValidEngineUrl(engine)) {
      throw ArgumentError('Invalid or unsafe search engine URL: ${engine.baseUrl}');
    }
    _engines.add(engine);
    await _saveEngines();
  }

  Future<void> removeEngineAt(int index) async {
    await load();
    if (index >= 0 && index < _engines.length) {
      _engines.removeAt(index);
      await _saveEngines();
    }
  }

  Future<void> updateEngineAt(int index, SearchEngine engine) async {
    await load();
    if (index >= 0 && index < _engines.length) {
      if (!await isValidEngineUrl(engine)) {
        throw ArgumentError('Invalid or unsafe search engine URL: ${engine.baseUrl}');
      }
      _engines[index] = engine;
      await _saveEngines();
    }
  }

  Future<void> _saveEngines() async {
    await _setString(
      _enginesKey,
      jsonEncode(_engines.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> addToHistory(String query) async {
    await load();
    _searchHistory.remove(query);
    _searchHistory.insert(0, query);
    if (_searchHistory.length > _maxHistory) {
      _searchHistory = _searchHistory.sublist(0, _maxHistory);
    }
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    await load();
    _searchHistory.clear();
    await _saveHistory();
  }

  Future<void> _saveHistory() async {
    await _setString(
      _historyKey,
      jsonEncode(_searchHistory),
    );
  }

  Future<List<SearchResult>> search(String query) async {
    await load();
    await addToHistory(query);

    final results = <SearchResult>[];
    final enabledEngines = _engines.where((e) => e.enabled).toList();

    for (final engine in enabledEngines) {
      try {
        final engineResults = await _searchEngine(engine, query);
        results.addAll(engineResults);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Search failed for ${engine.name}: $e');
        }
      }
    }

    return results;
  }

  Future<List<SearchResult>> _searchEngine(
    SearchEngine engine,
    String query,
  ) async {
    final uri = Uri.tryParse(
      engine.baseUrl +
          engine.searchPath.replaceAll('{query}', Uri.encodeComponent(query)),
    );
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError('Invalid search engine URL: ${engine.baseUrl}');
    }
    if (!await IpAddressScope.isPubliclyRoutableHost(uri.host)) {
      throw ArgumentError('Search engine host is not publicly routable: ${uri.host}');
    }

    final response = await http.get(uri).timeout(
          const Duration(seconds: 15),
        );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    // Guard against huge / XML-bomb bodies.
    if (response.bodyBytes.length > 512 * 1024) {
      throw Exception('Search response too large');
    }

    return _parseResults(engine.name, response.body);
  }

  List<SearchResult> _parseResults(String source, String html) {
    // Basic HTML parsing - in production, use a proper HTML parser
    final results = <SearchResult>[];

    // This is a placeholder implementation
    // Real implementation would parse HTML specific to each search engine
    // and extract torrent information

    return results;
  }
}
