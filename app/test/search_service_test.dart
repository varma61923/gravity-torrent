import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/services/search_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPrefsStorage.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await (await SharedPreferences.getInstance()).reload();
    SearchService.instance.resetForTest();
    SearchService.hostLookupForTest = (host) async {
      final base = InternetAddress.tryParse(host);
      if (base != null) return [base];
      if (host == '127.1' ||
          host == '0x7f.0.0.1' ||
          host == '0127.0.0.1' ||
          host == 'localhost' ||
          host == 'localtest.me') {
        return [InternetAddress.loopbackIPv4];
      }
      return [InternetAddress('8.8.8.8')];
    };
  });

  tearDown(() async {
    SharedPrefsStorage.resetForTest();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    SearchService.instance.resetForTest();
    SearchService.hostLookupForTest = null;
  });

  group('SearchResult & SearchEngine Models', () {
    test('SearchResult JSON round-trip and defaults', () {
      final result = SearchResult(
        title: 'Ubuntu 24.04 LTS',
        magnetLink:
            'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        torrentUrl: 'https://example.com/ubuntu.torrent',
        size: 2147483648,
        seeders: 500,
        leechers: 25,
        source: 'The Pirate Bay',
      );

      final json = result.toJson();
      final fromJson = SearchResult.fromJson(json);

      expect(fromJson.title, equals(result.title));
      expect(fromJson.magnetLink, equals(result.magnetLink));
      expect(fromJson.torrentUrl, equals(result.torrentUrl));
      expect(fromJson.size, equals(result.size));
      expect(fromJson.seeders, equals(result.seeders));
      expect(fromJson.leechers, equals(result.leechers));
      expect(fromJson.source, equals(result.source));
    });

    test('SearchResult handles missing/null json fields', () {
      final emptyResult = SearchResult.fromJson({});
      expect(emptyResult.title, isEmpty);
      expect(emptyResult.magnetLink, isEmpty);
      expect(emptyResult.torrentUrl, isNull);
      expect(emptyResult.size, equals(0));
      expect(emptyResult.seeders, equals(0));
      expect(emptyResult.leechers, equals(0));
      expect(emptyResult.source, isEmpty);
    });

    test('SearchEngine JSON round-trip', () {
      final engine = SearchEngine(
        name: 'Custom Tracker',
        baseUrl: 'https://customtracker.org',
        searchPath: '/search?q={query}',
        enabled: true,
      );
      final json = engine.toJson();
      final restored = SearchEngine.fromJson(json);
      expect(restored.name, equals(engine.name));
      expect(restored.baseUrl, equals(engine.baseUrl));
      expect(restored.searchPath, equals(engine.searchPath));
      expect(restored.enabled, isTrue);
    });
  });

  group('SearchEngine URL Validation (SSRF & Scheme Checks)', () {
    test('accepts valid public HTTP/HTTPS URLs', () async {
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: 'TPB',
            baseUrl: 'https://thepiratebay.org',
            searchPath: '',
          ),
        ),
        isTrue,
      );
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: '1337x',
            baseUrl: 'https://1337x.to',
            searchPath: '',
          ),
        ),
        isTrue,
      );
    });

    test('rejects loopback, private IPs, credentials, and non-http schemes',
        () async {
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: 'Local',
            baseUrl: 'http://127.0.0.1:8080',
            searchPath: '',
          ),
        ),
        isFalse,
      );
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: 'Private',
            baseUrl: 'http://192.168.1.1',
            searchPath: '',
          ),
        ),
        isFalse,
      );
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: 'UserInfo',
            baseUrl: 'https://admin:pass@thepiratebay.org',
            searchPath: '',
          ),
        ),
        isFalse,
      );
      expect(
        await SearchService.isValidEngineUrl(
          SearchEngine(
            name: 'FTP',
            baseUrl: 'ftp://thepiratebay.org',
            searchPath: '',
          ),
        ),
        isFalse,
      );
    });
  });

  group('SearchService Engine & History Management', () {
    test('loads default engines on fresh start', () async {
      await SearchService.instance.load();
      expect(SearchService.instance.engines.length, equals(3));
      expect(
        SearchService.instance.engines.map((e) => e.name),
        contains('The Pirate Bay'),
      );
    });

    test('adds and removes engines', () async {
      await SearchService.instance.load();
      final custom = SearchEngine(
        name: 'TorrentGalaxy',
        baseUrl: 'https://torrentgalaxy.to',
        searchPath: '/torrents.php?search={query}',
      );
      await SearchService.instance.addEngine(custom);
      expect(SearchService.instance.engines.length, equals(4));
      expect(SearchService.instance.engines.last.name, equals('TorrentGalaxy'));

      await SearchService.instance.removeEngineAt(3);
      expect(SearchService.instance.engines.length, equals(3));
    });

    test('tracks search history with max limit of 50', () async {
      await SearchService.instance.load();
      await SearchService.instance.addToHistory('ubuntu');
      await SearchService.instance.addToHistory('debian');
      await SearchService.instance.addToHistory('ubuntu'); // moves to front

      expect(
        SearchService.instance.searchHistory,
        equals(['ubuntu', 'debian']),
      );

      for (int i = 0; i < 60; i++) {
        await SearchService.instance.addToHistory('query $i');
      }
      expect(SearchService.instance.searchHistory.length, equals(50));
      expect(SearchService.instance.searchHistory.first, equals('query 59'));

      await SearchService.instance.clearHistory();
      expect(SearchService.instance.searchHistory, isEmpty);
    });
  });

  group('HTML Table Scraper (_parseResults)', () {
    test('parses The Pirate Bay search results', () {
      const tpbHtml = '''
<table id="searchResult">
  <tr class="header">
    <th>Type</th><th>Name</th><th>Uploaded</th><th>Icons</th><th>Size</th><th>SE</th><th>LE</th>
  </tr>
  <tr>
    <td class="vertTh"><center><a href="/browse/200">Video</a></center></td>
    <td>
      <div class="detName">
        <a href="/torrent/3516528/Ubuntu_22_04_LTS" class="detLink" title="Details for Ubuntu 22.04 LTS">Ubuntu 22.04 LTS (Jammy Jellyfish)</a>
      </div>
      <a href="magnet:?xt=urn:btih:d3b07384d113edec49eaa6238ad5ff00abcdef01&dn=Ubuntu+22.04+LTS" title="Download this torrent using magnet">
        <img src="/static/img/icon-magnet.gif" alt="Magnet" />
      </a>
      <font class="detDesc">Uploaded 04-21 2022, Size 1.45 GiB, ULed by official</font>
    </td>
    <td align="right">250</td>
    <td align="right">15</td>
  </tr>
</table>
''';
      final results = SearchService.instance
          .parseResultsForTesting('The Pirate Bay', tpbHtml);
      expect(results.length, equals(1));
      final res = results.first;
      expect(res.title, equals('Ubuntu 22.04 LTS (Jammy Jellyfish)'));
      expect(
        res.magnetLink,
        contains('urn:btih:d3b07384d113edec49eaa6238ad5ff00abcdef01'),
      );
      expect(res.size, equals((1.45 * 1024 * 1024 * 1024).round()));
      expect(res.seeders, equals(250));
      expect(res.leechers, equals(15));
      expect(res.source, equals('The Pirate Bay'));
    });

    test('parses 1337x search results with nested tags', () {
      const x1337Html = '''
<table class="table-list table table-responsive table-striped">
  <tbody>
    <tr>
      <td class="name">
        <a href="/sub/54/0/"><i class="flaticon-movie"></i></a>
        <a href="/torrent/5123456/Arch-Linux-2024-x64/">Arch Linux 2024 x86_64 ISO</a>
      </td>
      <td class="seeds">340</td>
      <td class="leeches">12</td>
      <td class="coll-date">Jan. 15th '24</td>
      <td class="size coll-4">850.5 MB<span class="seeds">340</span></td>
      <td class="coll-5"><a href="magnet:?xt=urn:btih:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678&dn=Arch+Linux">Download</a></td>
    </tr>
  </tbody>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('1337x', x1337Html);
      expect(results.length, equals(1));
      final res = results.first;
      expect(res.title, equals('Arch Linux 2024 x86_64 ISO'));
      expect(
        res.magnetLink,
        contains('a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'),
      );
      expect(res.size, equals((850.5 * 1024 * 1024).round()));
      expect(res.seeders, equals(340));
      expect(res.leechers, equals(12));
    });

    test('parses RARBG table with color fonts and hex infohash fallback', () {
      const rarbgHtml = '''
<table class="lista2t">
  <tr class="lista2">
    <td class="lista"><a href="/torrent/0123456789abcdef0123456789abcdef01234567">Big Buck Bunny 4K Remaster</a></td>
    <td class="lista"><a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Big+Buck+Bunny">DL</a></td>
    <td class="lista">2.1 GB</td>
    <td class="lista"><font color="green">120</font></td>
    <td class="lista"><font color="red">4</font></td>
  </tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('RARBG', rarbgHtml);
      expect(results.length, equals(1));
      final res = results.first;
      expect(res.title, equals('Big Buck Bunny 4K Remaster'));
      expect(res.size, equals((2.1 * 1024 * 1024 * 1024).round()));
      expect(res.seeders, equals(120));
      expect(res.leechers, equals(4));
    });

    test('extracts .torrent download URL if present', () {
      const html = '''
<table>
  <tr>
    <td><a href="/details/123">Fedora Workstation 39</a></td>
    <td><a href="https://download.fedoraproject.org/pub/fedora/linux/releases/39/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-39-1.5.iso.torrent">Download Torrent</a></td>
    <td>2.0 GB</td>
    <td><span class="seeds">80</span></td>
    <td><span class="leech">5</span></td>
  </tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Fedora', html);
      expect(results.length, equals(1));
      expect(results.first.torrentUrl, contains('.iso.torrent'));
      expect(results.first.title, equals('Fedora Workstation 39'));
    });

    test('decodes HTML entities and strips inner tags', () {
      const html = '''
<table>
  <tr>
    <td><a class="detLink">Rick &amp; Morty &lt;S07E01&gt; &#39;1080p&#39; &quot;WEBRip&quot;</a></td>
    <td><a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111">Magnet</a></td>
    <td>Size: 450 MB</td>
    <td><span class="green">90</span></td>
    <td><span class="red">2</span></td>
  </tr>
</table>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Test', html);
      expect(results.length, equals(1));
      expect(
        results.first.title,
        equals("Rick & Morty <S07E01> '1080p' \"WEBRip\""),
      );
    });
  });

  group('JSON Search Response Parser', () {
    test('parses Apibay style JSON array', () {
      const jsonStr = '''
[
  {
    "id": "12345",
    "name": "Debian 12.5 DVD ISO",
    "info_hash": "2222222222222222222222222222222222222222",
    "leechers": "10",
    "seeders": "450",
    "num_files": "1",
    "size": "3974103040"
  }
]
''';
      final results =
          SearchService.instance.parseResultsForTesting('Apibay', jsonStr);
      expect(results.length, equals(1));
      final res = results.first;
      expect(res.title, equals('Debian 12.5 DVD ISO'));
      expect(
        res.magnetLink,
        contains('2222222222222222222222222222222222222222'),
      );
      expect(res.size, equals(3974103040));
      expect(res.seeders, equals(450));
      expect(res.leechers, equals(10));
    });

    test('parses JSON wrapper object with results key', () {
      const jsonStr = '''
{
  "results": [
    {
      "title": "Alpine Linux 3.19",
      "magnetLink": "magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=Alpine",
      "size": 209715200,
      "seeders": 150,
      "leechers": 2
    }
  ]
}
''';
      final results =
          SearchService.instance.parseResultsForTesting('API', jsonStr);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Alpine Linux 3.19'));
      expect(results.first.size, equals(209715200));
    });
  });

  group('XML / RSS / Torznab Parser', () {
    test('parses Torznab RSS feed with custom attributes', () {
      const xmlStr = '''
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <title>Torznab Indexer</title>
    <item>
      <title>Kubuntu 23.10 x64</title>
      <link>https://example.com/download/kubuntu.torrent</link>
      <size>3221225472</size>
      <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:4444444444444444444444444444444444444444&amp;dn=Kubuntu" />
      <torznab:attr name="seeders" value="300" />
      <torznab:attr name="peers" value="18" />
    </item>
  </channel>
</rss>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Torznab', xmlStr);
      expect(results.length, equals(1));
      final res = results.first;
      expect(res.title, equals('Kubuntu 23.10 x64'));
      expect(
        res.magnetLink,
        contains('4444444444444444444444444444444444444444'),
      );
      expect(res.size, equals(3221225472));
      expect(res.seeders, equals(300));
      expect(res.leechers, equals(18));
    });
  });

  group('HTML Card & Fallback Scraper', () {
    test('parses modern card layout', () {
      const cardHtml = '''
<div class="container">
  <div class="torrent-item">
    <h3>Tails OS 6.0</h3>
    <a href="magnet:?xt=urn:btih:5555555555555555555555555555555555555555&dn=Tails+6.0">Magnet</a>
    <span class="size">1.2 GB</span>
    <span class="seeds">210</span>
    <span class="peers">11</span>
  </div>
</div>
''';
      final results =
          SearchService.instance.parseResultsForTesting('CardEngine', cardHtml);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Tails OS 6.0'));
      expect(results.first.seeders, equals(210));
      expect(results.first.leechers, equals(11));
    });

    test('fallback extracts standalone magnet links and dn parameter', () {
      const rawHtml = '''
<div>Random markup without table or cards</div>
<a href="magnet:?xt=urn:btih:6666666666666666666666666666666666666666&dn=Standalone+Torrent+Test">Click to download</a>
<span>Size 500 MB</span>
''';
      final results =
          SearchService.instance.parseResultsForTesting('Fallback', rawHtml);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Standalone Torrent Test'));
      expect(results.first.size, equals(500 * 1024 * 1024));
    });
  });

  group('Edge Cases & ReDoS Resilience', () {
    test('returns empty on empty or whitespace html', () {
      expect(
        SearchService.instance.parseResultsForTesting('Empty', ''),
        isEmpty,
      );
      expect(
        SearchService.instance.parseResultsForTesting('Blank', '   \n\t  '),
        isEmpty,
      );
    });

    test('handles malformed unclosed tags gracefully', () {
      const malformed =
          '<tr><td><a href="magnet:?xt=urn:btih:7777777777777777777777777777777777777777&dn=Broken">Broken HTML<td>100 MB<td>10';
      final results =
          SearchService.instance.parseResultsForTesting('Broken', malformed);
      expect(results.length, equals(1));
      expect(results.first.title, equals('Broken'));
    });

    test(
        'executes in linear time without catastrophic backtracking on repetitive input',
        () {
      final repetitive =
          '<tr><td>${'<a href="#">nested</a>' * 500}</td><td><a href="magnet:?xt=urn:btih:8888888888888888888888888888888888888888&dn=ReDoS+Test">Test</a></td></tr>';
      final stopwatch = Stopwatch()..start();
      final results =
          SearchService.instance.parseResultsForTesting('ReDoS', repetitive);
      stopwatch.stop();
      expect(results.length, equals(1));
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });
}
