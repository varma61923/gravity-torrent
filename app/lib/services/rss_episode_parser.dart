class EpisodeInfo {
  final int? season;
  final int? episode;
  final int? year;
  final int? month;
  final int? day;
  final String? title;

  EpisodeInfo({
    this.season,
    this.episode,
    this.year,
    this.month,
    this.day,
    this.title,
  });

  String get key {
    final parts = <String>[];
    if (season != null) parts.add('S${season.toString().padLeft(2, '0')}');
    if (episode != null) parts.add('E${episode.toString().padLeft(2, '0')}');
    if (year != null) parts.add(year.toString());
    if (month != null) parts.add(month.toString().padLeft(2, '0'));
    if (day != null) parts.add(day.toString().padLeft(2, '0'));
    if (title != null) parts.add(title!);
    return parts.join('-');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EpisodeInfo &&
        other.season == season &&
        other.episode == episode &&
        other.year == year &&
        other.month == month &&
        other.day == day &&
        other.title == title;
  }

  @override
  int get hashCode => Object.hash(season, episode, year, month, day, title);
}

class RssEpisodeParser {
  static EpisodeInfo? parse(String text) {
    // Try S01E01 pattern
    final seasonEpMatch = RegExp(
      r'[sS](\d{1,2})[eE](\d{1,2})',
    ).firstMatch(text);
    if (seasonEpMatch != null) {
      return EpisodeInfo(
        season: int.tryParse(seasonEpMatch.group(1)!),
        episode: int.tryParse(seasonEpMatch.group(2)!),
      );
    }

    // Try 1x01 pattern
    final xMatch = RegExp(r'(\d{1,2})[xX](\d{1,2})').firstMatch(text);
    if (xMatch != null) {
      return EpisodeInfo(
        season: int.tryParse(xMatch.group(1)!),
        episode: int.tryParse(xMatch.group(2)!),
      );
    }

    // Try 2024.01.01 or 2024-01-01 pattern
    final dateMatch = RegExp(
      r'(\d{4})[.\-](\d{1,2})[.\-](\d{1,2})',
    ).firstMatch(text);
    if (dateMatch != null) {
      return EpisodeInfo(
        year: int.tryParse(dateMatch.group(1)!),
        month: int.tryParse(dateMatch.group(2)!),
        day: int.tryParse(dateMatch.group(3)!),
      );
    }

    // Try "Season X Episode Y" pattern
    final seasonEpWordMatch = RegExp(
      r'season\s*(\d{1,2})\s*episode\s*(\d{1,2})',
      caseSensitive: false,
    ).firstMatch(text);
    if (seasonEpWordMatch != null) {
      return EpisodeInfo(
        season: int.tryParse(seasonEpWordMatch.group(1)!),
        episode: int.tryParse(seasonEpWordMatch.group(2)!),
      );
    }

    return null;
  }

  static bool matchesFilter(String text, String filter) {
    if (filter.isEmpty) return true;

    final episodeInfo = parse(text);
    if (episodeInfo == null) return false;

    // Parse filter like "1x1-10;2x1-5;" meaning:
    // Season 1 episodes 1-10, Season 2 episodes 1-5
    final ranges = filter.split(';').where((r) => r.isNotEmpty);
    for (final range in ranges) {
      if (_matchesRange(episodeInfo, range)) {
        return true;
      }
    }
    return false;
  }

  static bool _matchesRange(EpisodeInfo info, String range) {
    // Parse range like "1x1-10" or "S01E01-E10"
    final seasonEpMatch = RegExp(
      r'[sS]?(\d{1,2})[xXeE](\d{1,2})(?:-[sS]?[eE]?(\d{1,2}))?',
    ).firstMatch(range);
    if (seasonEpMatch != null) {
      final rangeSeason = int.tryParse(seasonEpMatch.group(1)!);
      final rangeStart = int.tryParse(seasonEpMatch.group(2)!);
      final rangeEnd =
          int.tryParse(seasonEpMatch.group(3) ?? rangeStart.toString());

      if (info.season == rangeSeason &&
          info.episode != null &&
          rangeStart != null &&
          rangeEnd != null) {
        return info.episode! >= rangeStart && info.episode! <= rangeEnd;
      }
    }

    return false;
  }

  static List<String> parseEpisodeFilter(String filter) {
    // Extract all unique episode keys from a filter string
    final episodes = <String>[];
    final ranges = filter.split(';').where((r) => r.isNotEmpty);
    for (final range in ranges) {
      final seasonEpMatch = RegExp(
        r'[sS]?(\d{1,2})[xXeE](\d{1,2})(?:-[sS]?[eE]?(\d{1,2}))?',
      ).firstMatch(range);
      if (seasonEpMatch != null) {
        final season = int.tryParse(seasonEpMatch.group(1)!);
        final start = int.tryParse(seasonEpMatch.group(2)!);
        final end = int.tryParse(seasonEpMatch.group(3) ?? start.toString());

        if (season != null && start != null && end != null) {
          for (var ep = start; ep <= end; ep++) {
            episodes.add(
              'S${season.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}',
            );
          }
        }
      }
    }
    return episodes;
  }
}
