import 'package:flutter/material.dart';
import 'package:gravity_torrent/services/rss_service.dart';
import 'package:gravity_torrent/utils/device.dart';
import 'package:gravity_torrent/widgets/window_title_bar.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';

class RssScreen extends StatefulWidget {
  const RssScreen({super.key});

  @override
  State<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends State<RssScreen> {
  bool _loaded = false;
  List<RssFeed> _feeds = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await RssService.instance.load();
    if (mounted) {
      setState(() {
        _feeds = List.from(RssService.instance.feeds);
        _loaded = true;
      });
    }
  }

  Future<void> _showAddDialog() async {
    final result = await showDialog<RssFeed>(
      context: context,
      builder: (ctx) => const _AddFeedDialog(),
    );
    if (result != null) {
      await RssService.instance.addFeed(result);
      await _load();
    }
  }

  Future<void> _pollNow() async {
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.pollingRssFeeds)));
    await RssService.instance.pollNow();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.pollComplete)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: isDesktop()
          ? const WindowTitleBar()
          : AppBar(
              title: Text(l.rssAutoDownload),
              actions: [
                if (_loaded)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: l.pollNow,
                    onPressed: _pollNow,
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        tooltip: l.addRssFeed,
        child: const Icon(Icons.add),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.rssAutoDownload,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(l.rssAutoDownloadDescription),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _feeds.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.rss_feed,
                                size: 64,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l.noFeedsYet,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                l.tapToAddFirstRssFeed,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: _feeds.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final feed = _feeds[index];
                            return Dismissible(
                              key: Key(feed.url),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: Theme.of(context).colorScheme.error,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 16),
                                child: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                ),
                              ),
                              confirmDismiss: (_) async {
                                try {
                                  await RssService.instance.removeFeed(feed);
                                  return true;
                                } catch (e) {
                                  if (!context.mounted) return false;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l.removeTorrentsError(e.toString()),
                                      ),
                                    ),
                                  );
                                  return false;
                                }
                              },
                              onDismissed: (_) {
                                // `confirmDismiss` awaits an async removal
                                // first, so `_feeds` (and therefore the
                                // position of `feed` within it) may have
                                // changed by the time this fires. Remove by
                                // identity rather than the build-time
                                // `index`, which could now point at a
                                // different feed or be out of bounds.
                                setState(() {
                                  _feeds.removeWhere(
                                    (f) =>
                                        f.url == feed.url &&
                                        f.keyword == feed.keyword,
                                  );
                                });
                              },
                              child: SwitchListTile(
                                secondary: const Icon(Icons.rss_feed),
                                title: Text(
                                  feed.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: feed.keyword.isNotEmpty
                                    ? Text(l.filter(feed.keyword))
                                    : Text(l.allItems),
                                value: feed.enabled,
                                onChanged: (v) async {
                                  final currentIndex = _feeds.indexWhere(
                                    (f) =>
                                        f.url == feed.url &&
                                        f.keyword == feed.keyword,
                                  );
                                  if (currentIndex == -1) return;

                                  final updated = RssFeed(
                                    url: feed.url,
                                    keyword: feed.keyword,
                                    enabled: v,
                                  );
                                  setState(
                                    () => _feeds[currentIndex] = updated,
                                  );

                                  final serviceIndex =
                                      RssService.instance.feeds.indexWhere(
                                    (f) =>
                                        f.url == feed.url &&
                                        f.keyword == feed.keyword,
                                  );
                                  if (serviceIndex != -1) {
                                    await RssService.instance.updateFeedAt(
                                      serviceIndex,
                                      updated,
                                    );
                                  }
                                  await _load();
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _AddFeedDialog extends StatefulWidget {
  const _AddFeedDialog();

  @override
  State<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<_AddFeedDialog> {
  final _urlController = TextEditingController();
  final _keywordController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    _keywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.addRssFeed),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: l.feedUrl,
              hintText: l.feedUrlHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.rss_feed),
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keywordController,
            decoration: InputDecoration(
              labelText: l.keywordFilter,
              hintText: l.keywordFilterHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.filter_list),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () {
            final url = _urlController.text.trim();
            if (url.isEmpty) return;
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !uri.hasAbsolutePath ||
                (!url.startsWith('http://') && !url.startsWith('https://'))) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l.validUrlRequired)));
              return;
            }
            final feed = RssFeed(
              url: url,
              keyword: _keywordController.text.trim(),
            );
            Navigator.of(context).pop(feed);
          },
          child: Text(l.add),
        ),
      ],
    );
  }
}
