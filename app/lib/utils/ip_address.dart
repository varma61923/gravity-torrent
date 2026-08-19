import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// IP address scope classification for SSRF and local-binding decisions.
///
/// The public/private/global checks are intentionally stricter than the basic
/// `InternetAddress.isLoopback` / `isLinkLocal` flags and are aligned with the
/// ranges used by libtorrent-rasterbar (`is_global` / `is_local`) plus
/// additional documentation / reserved ranges that must not be treated as
/// publicly routable.
enum AddressScope {
  loopback,
  linkLocal,
  uniqueLocal,
  multicast,
  private,
  cgnat,
  documentation,
  reserved,
  unspecified,
  global,
}

/// IP address helpers shared across the app.
///
/// Use [isPubliclyRoutable] / [isPubliclyRoutableHost] to decide whether a
/// remote URL is safe to fetch. Use [isPrivate] / [isPrivateHost] when
/// selecting a local address to bind to or validating a local-network peer.
class IpAddressScope {
  IpAddressScope._();

  /// Returns the scope of [address].
  static AddressScope classify(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return _classifyV4(bytes);
    if (bytes.length == 16) return _classifyV6(bytes);
    return AddressScope.reserved;
  }

  static bool isPubliclyRoutable(InternetAddress address) =>
      classify(address) == AddressScope.global;

  static bool isPrivate(InternetAddress address) {
    final scope = classify(address);
    return scope == AddressScope.loopback ||
        scope == AddressScope.linkLocal ||
        scope == AddressScope.uniqueLocal ||
        scope == AddressScope.private ||
        scope == AddressScope.cgnat;
  }

  /// Synchronous, conservative check for a publicly-routable host.
  ///
  /// Returns `false` for obvious local/reserved IP literals and malformed
  /// shorthand/hex/octal IPv4 addresses. Returns `true` for hostnames that
  /// cannot be classified without DNS; those should be validated with
  /// [isPubliclyRoutableHost] when async context is available.
  static bool isPubliclyRoutableHostSync(String host) {
    final normalized = _stripTrailingDot(host).toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost') return false;
    if (normalized.endsWith('.localhost')) return false;
    if (normalized.endsWith('.local')) return false;
    if (_looksLikeMalformedIpv4(normalized)) return false;
    final address = InternetAddress.tryParse(normalized);
    if (address != null) return isPubliclyRoutable(address);
    return true;
  }

  /// Validates [host] by resolving it and ensuring every returned address is
  /// publicly routable.
  static Future<bool> isPubliclyRoutableHost(
    String host, {
    Future<List<InternetAddress>> Function(String)? lookup,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!isPubliclyRoutableHostSync(host)) return false;
    if (InternetAddress.tryParse(_stripTrailingDot(host)) != null) {
      return true;
    }
    final lower = _stripTrailingDot(host).toLowerCase();
    if (lower.endsWith('.local')) return false;
    try {
      final resolver = lookup ?? InternetAddress.lookup;
      final addresses =
          await resolver(_stripTrailingDot(host)).timeout(timeout);
      if (addresses.isEmpty) return true;
      return addresses.every(isPubliclyRoutable);
    } on TimeoutException {
      // This is the only SSRF gate before a link is handed to the torrent
      // engine (no further address-scope validation happens downstream), so
      // a timeout must fail closed: an attacker-controlled DNS server could
      // otherwise deliberately stall past the timeout here to slip past this
      // check, then resolve to a private/internal address for the real
      // connection moments later when the engine itself looks it up.
      return false;
    } on SocketException {
      // Offline or unresolvable. Defer to fetch time rather than blocking a
      // legitimate URL when DNS is unavailable.
      return true;
    }
  }

  /// Synchronous, conservative check for a private/local host.
  ///
  /// Returns `true` for `localhost`, `.local`, link-local/private IP literals,
  /// and `false` for public hostnames that cannot be classified without DNS.
  /// Use [isPrivateHost] for full hostname resolution.
  static bool isPrivateHostSync(String host) {
    final normalized = _stripTrailingDot(host).toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost') return true;
    if (normalized.endsWith('.localhost')) return true;
    if (normalized.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(normalized);
    if (address != null) return isPrivate(address);
    return false;
  }

  /// Validates [host] by resolving it and accepting it only when at least one
  /// address is private/local and none are publicly routable.
  static Future<bool> isPrivateHost(
    String host, {
    Future<List<InternetAddress>> Function(String)? lookup,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (isPrivateHostSync(host)) return true;
    try {
      final resolver = lookup ?? InternetAddress.lookup;
      final addresses =
          await resolver(_stripTrailingDot(host)).timeout(timeout);
      if (addresses.isEmpty) return false;
      return addresses.any(isPrivate) && !addresses.any(isPubliclyRoutable);
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    }
  }

  /// Returns `true` when [link] is a magnet URI or an HTTP(S) .torrent URL
  /// whose host (and any tracker hosts in a magnet URI) are publicly routable.
  static Future<bool> isPubliclyRoutableLink(
    String link, {
    Future<List<InternetAddress>> Function(String)? lookup,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();

    if (lower.startsWith('magnet:')) {
      return _isPublicMagnet(trimmed, lookup: lookup, timeout: timeout);
    }

    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null ||
          uri.host.isEmpty ||
          !uri.path.toLowerCase().endsWith('.torrent')) {
        return false;
      }
      return isPubliclyRoutableHost(uri.host, lookup: lookup, timeout: timeout);
    }

    return false;
  }

  static AddressScope _classifyV4(Uint8List bytes) {
    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];

    if (a == 0) return AddressScope.unspecified; // 0.0.0.0/8
    if (a == 127) return AddressScope.loopback; // 127.0.0.0/8
    if (a == 10) return AddressScope.private; // 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) {
      return AddressScope.private; // 172.16/12
    }
    if (a == 192 && b == 168) return AddressScope.private; // 192.168/16
    if (a == 169 && b == 254) return AddressScope.linkLocal; // 169.254/16
    if (a == 100 && b >= 64 && b <= 127) return AddressScope.cgnat; // 100.64/10
    if (a >= 224 && a <= 239) return AddressScope.multicast; // 224/4
    if (a >= 240) return AddressScope.reserved; // 240/4 + broadcast

    if (a == 192 && b == 0) return AddressScope.reserved; // 192.0.0/24
    if (a == 192 && b == 88 && c == 99) {
      return AddressScope.reserved; // 192.88.99.0/24 (deprecated 6to4 anycast)
    }
    if (a == 198 && b >= 18 && b <= 19) {
      return AddressScope.reserved; // 198.18.0.0/15 (benchmarking)
    }
    if (a == 198 && b == 51 && c == 100) {
      return AddressScope.documentation; // 198.51.100.0/24 (TEST-NET-2)
    }
    if (a == 203 && b == 0 && c == 113) {
      return AddressScope.documentation; // 203.0.113.0/24 (TEST-NET-3)
    }

    return AddressScope.global;
  }

  static AddressScope _classifyV6(Uint8List bytes) {
    var allZero = true;
    for (var i = 0; i < 16; i++) {
      if (bytes[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) return AddressScope.unspecified;

    var loopback = true;
    for (var i = 0; i < 15; i++) {
      if (bytes[i] != 0) {
        loopback = false;
        break;
      }
    }
    if (loopback && bytes[15] == 1) return AddressScope.loopback;

    // IPv4-mapped (and IPv4-compatible) addresses: classify the embedded v4.
    if (bytes.length == 16) {
      var v4MappedPrefix = true;
      for (var i = 0; i < 10; i++) {
        if (bytes[i] != 0) {
          v4MappedPrefix = false;
          break;
        }
      }
      if (v4MappedPrefix && bytes[10] == 0xff && bytes[11] == 0xff) {
        final v4 = Uint8List(4)..setRange(0, 4, bytes, 12);
        return _classifyV4(v4);
      }

      var v4CompatiblePrefix = true;
      for (var i = 0; i < 12; i++) {
        if (bytes[i] != 0) {
          v4CompatiblePrefix = false;
          break;
        }
      }
      if (v4CompatiblePrefix) {
        final v4 = Uint8List(4)..setRange(0, 4, bytes, 12);
        final v4Scope = _classifyV4(v4);
        // ::/96 is deprecated; if the embedded v4 is global, treat the whole
        // address as reserved rather than public.
        return v4Scope == AddressScope.global ? AddressScope.reserved : v4Scope;
      }
    }

    final first = bytes[0];
    if (first == 0xff) return AddressScope.multicast; // ff00::/8
    if (first == 0xfe && (bytes[1] & 0xc0) == 0x80) {
      return AddressScope.linkLocal; // fe80::/10
    }
    if ((first & 0xfe) == 0xfc) return AddressScope.uniqueLocal; // fc00::/7
    if (first == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8) {
      return AddressScope.documentation; // 2001:db8::/32
    }
    // libtorrent-rasterbar is_global for IPv6.
    if ((first & 0xe0) == 0x20) return AddressScope.global; // 2000::/3
    return AddressScope.reserved;
  }

  static String _stripTrailingDot(String host) {
    if (host.endsWith('.') && host.length > 1) {
      return host.substring(0, host.length - 1);
    }
    return host;
  }

  /// Detects strings that look like IPv4 literals but are not strict dotted
  /// decimal quads, such as `127.1`, `0x7f.0.0.1`, `0127.0.0.1` or `256.0.0.0`.
  static bool _looksLikeMalformedIpv4(String host) {
    final parts = host.split('.');
    if (parts.length < 2 || parts.length > 4) return false;

    final allNumericOrHex = parts.every(
      (p) => RegExp(r'^[0-9A-Fa-fx]+$').hasMatch(p),
    );
    if (!allNumericOrHex) return false;

    if (parts.length != 4) return true;

    for (final p in parts) {
      if (p.isEmpty) return true;
      if (p.length > 1 && p.startsWith('0')) return true; // octal
      if (p.contains('x') || p.contains('X')) return true; // hex
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return true;
    }
    return false;
  }

  static Future<bool> _isPublicMagnet(
    String trimmed, {
    Future<List<InternetAddress>> Function(String)? lookup,
    required Duration timeout,
  }) async {
    Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      return false;
    }
    if (uri.scheme != 'magnet') return false;

    final trackers = uri.queryParametersAll['tr'] ?? const [];
    if (trackers.isEmpty) return true;

    for (final tr in trackers) {
      final trUri = Uri.tryParse(tr.trim());
      if (trUri == null || trUri.host.isEmpty) continue;
      final scheme = trUri.scheme.toLowerCase();
      if (scheme != 'http' &&
          scheme != 'https' &&
          scheme != 'udp' &&
          scheme != 'wss' &&
          scheme != 'ws') {
        return false;
      }
      if (!await isPubliclyRoutableHost(
        trUri.host,
        lookup: lookup,
        timeout: timeout,
      )) {
        return false;
      }
    }
    return true;
  }
}
