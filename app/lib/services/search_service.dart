import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/utils/ip_address.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

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

  @visibleForTesting
  static Future<List<InternetAddress>> Function(String)? hostLookupForTest;

  List<SearchEngine> get engines => List.unmodifiable(_engines);
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  @visibleForTesting
  void resetForTest() {
    _engines = [];
    _searchHistory = [];
    _loaded = false;
  }

  @visibleForTesting
  List<SearchResult> parseResultsForTesting(String source, String html) =>
      _parseResults(source, html);

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
  static Future<bool> isValidEngineUrl(
    SearchEngine engine, {
    Future<List<InternetAddress>> Function(String)? lookup,
  }) async {
    final uri = Uri.tryParse(engine.baseUrl);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false;
    return IpAddressScope.isPubliclyRoutableHost(
      uri.host,
      lookup: lookup ?? hostLookupForTest,
    );
  }

  Future<void> addEngine(SearchEngine engine) async {
    await load();
    if (!await isValidEngineUrl(engine)) {
      throw ArgumentError(
        'Invalid or unsafe search engine URL: ${engine.baseUrl}',
      );
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
        throw ArgumentError(
          'Invalid or unsafe search engine URL: ${engine.baseUrl}',
        );
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
    if (!await IpAddressScope.isPubliclyRoutableHost(
      uri.host,
      lookup: hostLookupForTest,
    )) {
      throw ArgumentError(
        'Search engine host is not publicly routable: ${uri.host}',
      );
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
    if (html.isEmpty) return const [];

    final trimmed = html.trim();

    // 1. Try JSON API parsing (Apibay, Torznab JSON, custom provider APIs)
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        final jsonResults = _parseJsonResults(source, decoded);
        if (jsonResults.isNotEmpty) return jsonResults;
      } catch (_) {
        // Fall through to XML / HTML on JSON decode failure
      }
    }

    // 2. Try XML / RSS / Torznab parsing
    if (trimmed.startsWith('<') &&
        (trimmed.contains('<rss') ||
            trimmed.contains('<feed') ||
            trimmed.contains('<channel>'))) {
      try {
        final xmlDoc = XmlDocument.parse(trimmed);
        final xmlResults = _parseXmlResults(source, xmlDoc);
        if (xmlResults.isNotEmpty) return xmlResults;
      } catch (_) {
        // Fall through to HTML table / card parsing
      }
    }

    // 3. Try HTML Table row parsing (The Pirate Bay, 1337x, RARBG, LimeTorrents, etc.)
    final tableResults = _parseHtmlTableRows(source, html);
    if (tableResults.isNotEmpty) return tableResults;

    // 4. Try HTML Card / Block parsing (modern card-based layouts)
    final cardResults = _parseHtmlCards(source, html);
    if (cardResults.isNotEmpty) return cardResults;

    // 5. Fallback: Generic Magnet & InfoHash link extraction
    return _parseFallbackMagnets(source, html);
  }

  List<SearchResult> _parseJsonResults(String source, dynamic decoded) {
    final List<dynamic> items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map) {
      final possibleList = decoded['results'] ??
          decoded['data'] ??
          decoded['torrents'] ??
          decoded['items'] ??
          decoded['list'];
      if (possibleList is List) {
        items = possibleList;
      } else if (possibleList is Map) {
        final nestedList = possibleList['torrents'] ??
            possibleList['results'] ??
            possibleList['data'] ??
            possibleList['items'] ??
            possibleList['list'];
        if (nestedList is List) {
          items = nestedList;
        } else {
          return const [];
        }
      } else {
        return const [];
      }
    } else {
      return const [];
    }

    final results = <SearchResult>[];
    for (final item in items) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);

      final title = _cleanHtmlText(
        (map['title'] ??
                map['name'] ??
                map['filename'] ??
                map['release_name'] ??
                '')
            .toString(),
      );

      var magnet = (map['magnetLink'] ??
              map['magnet_link'] ??
              map['magnet'] ??
              map['magnetUrl'] ??
              map['magnet_uri'] ??
              '')
          .toString()
          .trim();

      final infoHash = (map['info_hash'] ??
              map['infoHash'] ??
              map['hash'] ??
              map['info_hash_hex'] ??
              '')
          .toString()
          .trim();

      if (magnet.isEmpty && infoHash.isNotEmpty) {
        final encodedName =
            Uri.encodeComponent(title.isNotEmpty ? title : 'Torrent');
        magnet = 'magnet:?xt=urn:btih:$infoHash&dn=$encodedName';
      }

      final torrentUrl = (map['torrentUrl'] ??
              map['torrent_url'] ??
              map['download_url'] ??
              map['link'] ??
              map['url'])
          ?.toString()
          .trim();

      if (magnet.isEmpty &&
          (torrentUrl == null || !torrentUrl.contains('.torrent'))) {
        continue;
      }

      final size = _parseSizeDynamic(
        map['size'] ?? map['sizeBytes'] ?? map['length'],
      );
      final seeders =
          _parseCount(map['seeders'] ?? map['seeds'] ?? map['seed']);
      final leechers = _parseCount(
        map['leechers'] ?? map['leeches'] ?? map['peers'] ?? map['leech'],
      );

      results.add(
        SearchResult(
          title: title.isNotEmpty ? title : 'Torrent',
          magnetLink: magnet,
          torrentUrl:
              (torrentUrl != null && torrentUrl.isNotEmpty) ? torrentUrl : null,
          size: size,
          seeders: seeders,
          leechers: leechers,
          source: source,
        ),
      );
    }
    return results;
  }

  List<SearchResult> _parseXmlResults(String source, XmlDocument doc) {
    final results = <SearchResult>[];
    final items = [
      ...doc.findAllElements('item'),
      ...doc.findAllElements('entry'),
    ];

    for (final item in items) {
      final title = _cleanHtmlText(
        item.findElements('title').firstOrNull?.innerText ?? '',
      );

      String magnet = '';
      String? torrentUrl;
      int size = 0;
      int seeders = 0;
      int leechers = 0;

      for (final attr in item.findAllElements('torznab:attr')) {
        final name = (attr.getAttribute('name') ?? '').toLowerCase();
        final value = attr.getAttribute('value') ?? '';
        if (name == 'magneturl') {
          magnet = value;
        } else if (name == 'seeders') {
          seeders = int.tryParse(value) ?? 0;
        } else if (name == 'peers' || name == 'leechers') {
          leechers = int.tryParse(value) ?? 0;
        } else if (name == 'size') {
          size = int.tryParse(value) ?? 0;
        } else if (name == 'infohash' || name == 'hash') {
          if (magnet.isEmpty && value.isNotEmpty) {
            magnet =
                'magnet:?xt=urn:btih:$value&dn=${Uri.encodeComponent(title.isNotEmpty ? title : 'Torrent')}';
          }
        }
      }

      for (final enc in item.findElements('enclosure')) {
        final url = enc.getAttribute('url') ?? '';
        final length = enc.getAttribute('length');
        if (url.startsWith('magnet:?')) {
          magnet = url;
        } else if (url.contains('.torrent') || url.isNotEmpty) {
          torrentUrl = url;
        }
        if (length != null && size == 0) {
          size = int.tryParse(length) ?? 0;
        }
      }

      final link = item.findElements('link').firstOrNull?.innerText ?? '';
      if (link.startsWith('magnet:?')) {
        magnet = link;
      } else if (link.contains('.torrent')) {
        torrentUrl = link;
      }

      if (size == 0) {
        final sizeText = item.findElements('size').firstOrNull?.innerText ??
            item.findAllElements('size').firstOrNull?.innerText;
        if (sizeText != null) {
          size = _parseSizeDynamic(sizeText);
        }
      }

      if (magnet.isEmpty && torrentUrl == null) {
        final magnetMatch =
            RegExp(r'''magnet:\?xt=urn:btih:[a-zA-Z0-9]+[^<"\s]*''')
                .firstMatch(item.innerText);
        if (magnetMatch != null) {
          magnet = magnetMatch.group(0)!;
        }
      }

      if (magnet.isNotEmpty || torrentUrl != null) {
        results.add(
          SearchResult(
            title: title.isNotEmpty ? title : 'Torrent',
            magnetLink: magnet,
            torrentUrl: torrentUrl,
            size: size < 0 ? 0 : size,
            seeders: seeders < 0 ? 0 : seeders,
            leechers: leechers < 0 ? 0 : leechers,
            source: source,
          ),
        );
      }
    }
    return results;
  }

  List<SearchResult> _parseHtmlTableRows(String source, String html) {
    final results = <SearchResult>[];
    final rowRegex = RegExp(
      r'''<tr\b[^>]*>(.*?)</tr>''',
      caseSensitive: false,
      dotAll: true,
    );
    final rows = rowRegex.allMatches(html);

    for (final rowMatch in rows) {
      final rowHtml = rowMatch.group(1) ?? '';
      if (rowHtml.isEmpty) continue;

      // Skip pure header rows
      if (rowHtml.contains('<th') && !rowHtml.contains('<td')) continue;

      // 1. Extract magnet link or infohash
      String magnet = '';
      final magnetMatch = RegExp(
        r'''href=["'](magnet:\?[^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(rowHtml);

      if (magnetMatch != null) {
        magnet = magnetMatch.group(1)!;
      } else {
        final hashMatch = RegExp(
          r'''href=["'][^"']*(?:/torrent/|[?&]hash=)([0-9a-fA-F]{40})\b''',
          caseSensitive: false,
        ).firstMatch(rowHtml);
        if (hashMatch != null) {
          final hash = hashMatch.group(1)!;
          magnet = 'magnet:?xt=urn:btih:$hash';
        }
      }

      // Check for .torrent URL
      String? torrentUrl;
      final torrentUrlMatch = RegExp(
        r'''href=["']([^"']+\.torrent(?:\?[^"']*)?)["']''',
        caseSensitive: false,
      ).firstMatch(rowHtml);
      if (torrentUrlMatch != null) {
        torrentUrl = torrentUrlMatch.group(1);
      }

      if (magnet.isEmpty && torrentUrl == null) {
        continue;
      }

      // 2. Extract Title
      String title = '';
      final titleAnchorMatch = RegExp(
        r'''<a\b[^>]*class=["'][^"']*(?:detLink|torrent-name|title|name)[^"']*["'][^>]*>(.*?)</a>''',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(rowHtml);

      if (titleAnchorMatch != null) {
        title = _cleanHtmlText(titleAnchorMatch.group(1)!);
      }

      if (title.isEmpty) {
        final torrentLinkMatch = RegExp(
          r'''<a\b[^>]*href=["'][^"']*(?:/torrent/|/details/|/view/)[^"']*["'][^>]*>(.*?)</a>''',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(rowHtml);
        if (torrentLinkMatch != null) {
          title = _cleanHtmlText(torrentLinkMatch.group(1)!);
        }
      }

      if (title.isEmpty) {
        final titleAttrMatch = RegExp(
          r'''title=["'](?:Details for )?([^"']{3,})["']''',
          caseSensitive: false,
        ).firstMatch(rowHtml);
        if (titleAttrMatch != null) {
          title = _cleanHtmlText(titleAttrMatch.group(1)!);
        }
      }

      if (title.isEmpty) {
        final allAnchors = RegExp(
          r'''<a\b[^>]*>(.*?)</a>''',
          caseSensitive: false,
          dotAll: true,
        ).allMatches(rowHtml);
        for (final a in allAnchors) {
          final text = _cleanHtmlText(a.group(1)!);
          if (text.length >= 3 &&
              !text.toLowerCase().contains('download') &&
              !text.toLowerCase().contains('magnet') &&
              !text.toLowerCase().contains('vip') &&
              !text.startsWith('http')) {
            title = text;
            break;
          }
        }
      }

      if (title.isEmpty && magnet.isNotEmpty) {
        try {
          final uri = Uri.parse(magnet);
          final dn = uri.queryParameters['dn'];
          if (dn != null && dn.isNotEmpty) {
            title = dn;
          }
        } catch (_) {}
      }

      if (title.isEmpty) {
        title = 'Torrent';
      }

      if (magnet.startsWith('magnet:?') && !magnet.contains('dn=')) {
        magnet = '$magnet&dn=${Uri.encodeComponent(title)}';
      }

      // 3. Extract Size
      final size = _extractSizeFromHtml(rowHtml);

      // 4. Extract Seeders & Leechers
      final (seeders, leechers) = _extractSeedsAndLeechers(rowHtml);

      results.add(
        SearchResult(
          title: title,
          magnetLink: magnet,
          torrentUrl: torrentUrl,
          size: size,
          seeders: seeders,
          leechers: leechers,
          source: source,
        ),
      );
    }

    return results;
  }

  List<SearchResult> _parseHtmlCards(String source, String html) {
    final results = <SearchResult>[];
    final blockRegex = RegExp(
      r'''<(?:div|article|li)\b[^>]*class=["'][^"']*(?:card|item|torrent-item|tgxtablerow|list-entry|result-item)[^"']*["'][^>]*>(.*?)</(?:div|article|li)>''',
      caseSensitive: false,
      dotAll: true,
    );

    final blocks = blockRegex.allMatches(html);
    for (final blockMatch in blocks) {
      final blockHtml = blockMatch.group(1) ?? '';
      if (blockHtml.isEmpty) continue;

      String magnet = '';
      final magnetMatch = RegExp(
        r'''href=["'](magnet:\?[^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(blockHtml);
      if (magnetMatch != null) {
        magnet = magnetMatch.group(1)!;
      } else {
        final hashMatch = RegExp(
          r'''href=["'][^"']*(?:/torrent/|[?&]hash=)([0-9a-fA-F]{40})\b''',
          caseSensitive: false,
        ).firstMatch(blockHtml);
        if (hashMatch != null) {
          magnet = 'magnet:?xt=urn:btih:${hashMatch.group(1)}';
        }
      }

      String? torrentUrl;
      final torrentUrlMatch = RegExp(
        r'''href=["']([^"']+\.torrent(?:\?[^"']*)?)["']''',
        caseSensitive: false,
      ).firstMatch(blockHtml);
      if (torrentUrlMatch != null) {
        torrentUrl = torrentUrlMatch.group(1);
      }

      if (magnet.isEmpty && torrentUrl == null) continue;

      String title = '';
      final hMatch = RegExp(
        r'''<h[1-6]\b[^>]*>(.*?)</h[1-6]>''',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(blockHtml);
      if (hMatch != null) {
        title = _cleanHtmlText(hMatch.group(1)!);
      }
      if (title.isEmpty) {
        final aMatch = RegExp(
          r'''<a\b[^>]*class=["'][^"']*(?:title|name)[^"']*["'][^>]*>(.*?)</a>''',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(blockHtml);
        if (aMatch != null) {
          title = _cleanHtmlText(aMatch.group(1)!);
        }
      }
      if (title.isEmpty && magnet.isNotEmpty) {
        try {
          final uri = Uri.parse(magnet);
          title = uri.queryParameters['dn'] ?? '';
        } catch (_) {}
      }
      if (title.isEmpty) title = 'Torrent';

      final size = _extractSizeFromHtml(blockHtml);
      final (seeders, leechers) = _extractSeedsAndLeechers(blockHtml);

      results.add(
        SearchResult(
          title: title,
          magnetLink: magnet,
          torrentUrl: torrentUrl,
          size: size,
          seeders: seeders,
          leechers: leechers,
          source: source,
        ),
      );
    }
    return results;
  }

  List<SearchResult> _parseFallbackMagnets(String source, String html) {
    final results = <SearchResult>[];
    final magnetRegex = RegExp(
      r'''href=["'](magnet:\?[^"']+)["']''',
      caseSensitive: false,
    );

    final matches = magnetRegex.allMatches(html);
    final seenMagnets = <String>{};

    for (final match in matches) {
      final magnet = match.group(1)!;
      if (seenMagnets.contains(magnet)) continue;
      seenMagnets.add(magnet);

      String title = '';
      try {
        final uri = Uri.parse(magnet);
        title = uri.queryParameters['dn'] ?? '';
      } catch (_) {}

      final start = (match.start - 300).clamp(0, html.length);
      final end = (match.end + 300).clamp(0, html.length);
      final window = html.substring(start, end);

      if (title.isEmpty) {
        final titleMatch = RegExp(
          r'''<a\b[^>]*>(.*?)</a>''',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(window);
        if (titleMatch != null) {
          final t = _cleanHtmlText(titleMatch.group(1)!);
          if (t.length >= 3) title = t;
        }
      }
      if (title.isEmpty) title = 'Torrent';

      final size = _extractSizeFromHtml(window);
      final (seeders, leechers) = _extractSeedsAndLeechers(window);

      results.add(
        SearchResult(
          title: title,
          magnetLink: magnet,
          torrentUrl: null,
          size: size,
          seeders: seeders,
          leechers: leechers,
          source: source,
        ),
      );
    }
    return results;
  }

  int _extractSizeFromHtml(String text) {
    final pureInt = int.tryParse(text.trim());
    if (pureInt != null && pureInt >= 0) return pureInt;

    final explicitMatch = RegExp(
      r'''(?:size|bytes?)\s*[:\s]*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)\b''',
      caseSensitive: false,
    ).firstMatch(text);
    if (explicitMatch != null) {
      return _parseSizeValues(
        explicitMatch.group(1)!,
        explicitMatch.group(2)!,
      );
    }

    final cellMatch = RegExp(
      r'''>\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)\s*<''',
      caseSensitive: false,
    ).firstMatch(text);
    if (cellMatch != null) {
      return _parseSizeValues(cellMatch.group(1)!, cellMatch.group(2)!);
    }

    final genericMatch = RegExp(
      r'''\b([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)\b''',
      caseSensitive: false,
    ).firstMatch(text);
    if (genericMatch != null) {
      return _parseSizeValues(genericMatch.group(1)!, genericMatch.group(2)!);
    }

    return 0;
  }

  int _parseSizeValues(String numStr, String unitStr) {
    final numValue = double.tryParse(numStr) ?? 0.0;
    final unit = unitStr.toUpperCase();
    if (unit.startsWith('K')) return (numValue * 1024).round();
    if (unit.startsWith('M')) return (numValue * 1024 * 1024).round();
    if (unit.startsWith('G')) {
      return (numValue * 1024 * 1024 * 1024).round();
    }
    if (unit.startsWith('T')) {
      return (numValue * 1024 * 1024 * 1024 * 1024).round();
    }
    if (unit.startsWith('P')) {
      return (numValue * 1024 * 1024 * 1024 * 1024 * 1024).round();
    }
    return numValue.round();
  }

  int _parseSizeDynamic(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt() >= 0 ? value.toInt() : 0;
    if (value is String) {
      final trimmed = value.trim();
      final intVal = int.tryParse(trimmed);
      if (intVal != null) return intVal >= 0 ? intVal : 0;
      return _extractSizeFromHtml(trimmed);
    }
    return 0;
  }

  int _parseCount(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt() >= 0 ? value.toInt() : 0;
    if (value is String) {
      final clean = value.replaceAll(RegExp(r'[^0-9]'), '');
      return int.tryParse(clean) ?? 0;
    }
    return 0;
  }

  (int, int) _extractSeedsAndLeechers(String text) {
    int seeders = 0;
    int leechers = 0;

    final seedMatch = RegExp(
      r'''class=["'][^"']*(?:seeds?|seeders|green)[^"']*["'][^>]*>\s*(?:<[^>]+>\s*)*([0-9,]+)''',
      caseSensitive: false,
    ).firstMatch(text);
    if (seedMatch != null) {
      seeders = _parseCount(seedMatch.group(1));
    }

    final leechMatch = RegExp(
      r'''class=["'][^"']*(?:leech|leeches|leechers|peers|red)[^"']*["'][^>]*>\s*(?:<[^>]+>\s*)*([0-9,]+)''',
      caseSensitive: false,
    ).firstMatch(text);
    if (leechMatch != null) {
      leechers = _parseCount(leechMatch.group(1));
    }

    if (seeders == 0) {
      final fontGreen = RegExp(
        r'''color=["']green["'][^>]*>\s*([0-9,]+)''',
        caseSensitive: false,
      ).firstMatch(text);
      if (fontGreen != null) seeders = _parseCount(fontGreen.group(1));
    }
    if (leechers == 0) {
      final fontRed = RegExp(
        r'''color=["']red["'][^>]*>\s*([0-9,]+)''',
        caseSensitive: false,
      ).firstMatch(text);
      if (fontRed != null) leechers = _parseCount(fontRed.group(1));
    }

    if (seeders == 0 && leechers == 0) {
      final rightCells = RegExp(
        r'''<td\b[^>]*align=["']right["'][^>]*>\s*([0-9,]+)\s*</td>''',
        caseSensitive: false,
      ).allMatches(text).toList();
      if (rightCells.length >= 2) {
        seeders = _parseCount(rightCells[0].group(1));
        leechers = _parseCount(rightCells[1].group(1));
      }
    }

    return (seeders, leechers);
  }

  String _cleanHtmlText(String text) {
    var cleaned = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) {
        final val = int.tryParse(m.group(1)!);
        if (val == null || val < 0 || val > 0x10FFFF) return ' ';
        return String.fromCharCode(val);
      },
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) {
        final val = int.tryParse(m.group(1)!, radix: 16);
        if (val == null || val < 0 || val > 0x10FFFF) return ' ';
        return String.fromCharCode(val);
      },
    );

    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
