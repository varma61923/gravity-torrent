import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gravity_torrent/dialogs/remove_torrent.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/models/app.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/screens/torrents/sheets/torrent_details/torrent_details.dart';
import 'package:gravity_torrent/screens/torrents/torrent_list_tile/torrent_status.dart';
import 'package:gravity_torrent/services/ads/ad_service_provider.dart';
import 'package:gravity_torrent/widgets/torrent_health_badge.dart';
import 'package:gravity_torrent/utils/app_links.dart';
import 'package:gravity_torrent/utils/device.dart';
import 'package:pretty_bytes/pretty_bytes.dart';
import 'package:provider/provider.dart';

enum _TorrentCopyAction { magnetLink, infoHash, name }

class TorrentListTile extends StatelessWidget {
  const TorrentListTile({
    super.key,
    required this.torrent,
    required this.percent,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.compact = false,
    this.onLongPress,
    this.onSelectionChanged,
  });

  final Torrent torrent;
  final double percent;
  final bool isSelectionMode;
  final bool isSelected;
  final bool compact;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final showHealthBadge = context.watch<AppModel>().showTorrentHealthBadge;

    return Consumer<TorrentsModel>(
      builder: (context, torrentsModel, child) {
        return ListTile(
          dense: compact,
          visualDensity:
              compact ? VisualDensity.compact : VisualDensity.standard,
          contentPadding: !isMobileSize(context)
              ? const EdgeInsets.only(left: 16, right: 16)
              : null,
          onTap: () {
            if (isSelectionMode) {
              onSelectionChanged?.call();
            } else {
              AdServiceProvider.instance.showInterstitialIfReady();
              showDeviceSheet(
                context,
                torrent.name,
                TorrentDetailsModalSheet(id: torrent.id),
              );
            }
          },
          onLongPress: onLongPress,
          leading: (isSelectionMode)
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => onSelectionChanged?.call(),
                )
              : FittedBox(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: torrent.progress,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
                        strokeWidth: 4,
                      ),
                      Center(
                        child: IconButton(
                          onPressed: () async {
                            try {
                              if (torrent.status == TorrentStatus.stopped) {
                                await torrentsModel.resumeSelected({torrent.id});
                              } else {
                                await torrentsModel.pauseSelected({torrent.id});
                              }
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(localizations.error),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                            }
                          },
                          icon: torrent.status == TorrentStatus.stopped
                              ? const Icon(Icons.play_arrow)
                              : const Icon(Icons.pause),
                          tooltip: torrent.status == TorrentStatus.stopped
                              ? localizations.resume
                              : localizations.pause,
                        ),
                      ),
                    ],
                  ),
                ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  torrent.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: Icon(
                  torrentsModel.isFavorite(torrent.id)
                      ? Icons.star
                      : Icons.star_border,
                  color: torrentsModel.isFavorite(torrent.id)
                      ? Colors.amber
                      : null,
                ),
                tooltip: torrentsModel.isFavorite(torrent.id)
                    ? localizations.unfavorite
                    : localizations.favorite,
                onPressed: () => torrentsModel.toggleFavorite(torrent.id),
              ),
              if (showHealthBadge) TorrentHealthBadge(torrent: torrent),
            ],
          ),
          trailing: (!isMobileSize(context))
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: localizations.play,
                      onPressed: () {
                        AdServiceProvider.instance.showInterstitialIfReady();
                        showDeviceSheet(
                          context,
                          torrent.name,
                          TorrentDetailsModalSheet(
                            id: torrent.id,
                            initialTab: 0,
                            showOnlyPlayableFiles: true,
                          ),
                        );
                      },
                      icon: const Icon(Icons.play_circle_outlined),
                    ),
                    IconButton(
                      tooltip: localizations.share,
                      onPressed: () => shareLink(context, torrent.magnetLink),
                      icon: const Icon(Icons.share),
                    ),
                    PopupMenuButton<_TorrentCopyAction>(
                      icon: const Icon(Icons.copy),
                      tooltip: localizations.copy,
                      onSelected: (action) async {
                        if (!context.mounted) return;
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        final text = switch (action) {
                          _TorrentCopyAction.magnetLink => torrent.magnetLink,
                          _TorrentCopyAction.infoHash => torrent.hash ?? '-',
                          _TorrentCopyAction.name => torrent.name,
                        };
                        await Clipboard.setData(ClipboardData(text: text));
                        if (!scaffoldMessenger.mounted) return;
                        final copiedMessage = switch (action) {
                          _TorrentCopyAction.magnetLink =>
                            localizations.magnetLinkCopied,
                          _TorrentCopyAction.infoHash =>
                            localizations.hashCopied,
                          _TorrentCopyAction.name =>
                            localizations.copiedToClipboard,
                        };
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(copiedMessage),
                            backgroundColor: Colors.lightGreen,
                          ),
                        );
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: _TorrentCopyAction.magnetLink,
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.copy),
                            title: Text(localizations.copyMagnetLink),
                          ),
                        ),
                        PopupMenuItem(
                          value: _TorrentCopyAction.infoHash,
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.tag),
                            title: Text(
                              '${localizations.copy} ${localizations.hash.toLowerCase()}',
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: _TorrentCopyAction.name,
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.text_snippet),
                            title: Text(
                              '${localizations.copy} ${localizations.name.toLowerCase()}',
                            ),
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: localizations.openFolder,
                      onPressed: () => torrent.openFolder(context),
                      icon: const Icon(Icons.folder_outlined),
                    ),
                    IconButton(
                      tooltip: localizations.remove,
                      onPressed: () => showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return RemoveTorrentDialog(torrent: torrent);
                        },
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                )
              : null,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 16.0,
                runSpacing: 4.0,
                children: [
                  TorrentStatusText(torrent: torrent, percent: percent),
                  Text(
                    prettyBytes(
                      torrent.size.toDouble(),
                      locale: localizations.localeName,
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  if (torrent.progress != 1)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_circle_down,
                          size: 16,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.lightGreenAccent
                              : Colors.green.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${prettyBytes(torrent.rateDownload.toDouble(), locale: localizations.localeName)}/s',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_circle_up,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${prettyBytes(torrent.rateUpload.toDouble(), locale: localizations.localeName)}/s',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (context.watch<AppModel>().showTorrentLabels &&
                  (torrent.labels?.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Wrap(
                    spacing: 4.0,
                    runSpacing: 4.0,
                    children: torrent.labels!
                        .map(
                          (label) => Chip(
                            label: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
