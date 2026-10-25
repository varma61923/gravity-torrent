import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:gravity_torrent/engine/file.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/widgets/torrent_player/torrent_player.dart';
import 'package:pretty_bytes/pretty_bytes.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:mime/mime.dart';

class FilesTab extends StatefulWidget {
  final Torrent torrent;
  final String location;
  final bool showOnlyPlayable;

  const FilesTab({
    super.key,
    required this.torrent,
    required this.location,
    this.showOnlyPlayable = false,
  });

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  late bool _showOnlyPlayable;

  @override
  void initState() {
    super.initState();
    _showOnlyPlayable = widget.showOnlyPlayable;
  }

  @override
  void didUpdateWidget(covariant FilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showOnlyPlayable != widget.showOnlyPlayable) {
      setState(() => _showOnlyPlayable = widget.showOnlyPlayable);
    }
  }

  bool _isFilePlayable(String filename) {
    final mimeType = lookupMimeType(filename);
    return mimeType != null &&
        (mimeType.startsWith('video') || mimeType.startsWith('audio'));
  }

  Future<void> _openFile(String filepath) async {
    final l = AppLocalizations.of(context);
    try {
      final result = await OpenFile.open(path.join(widget.location, filepath));
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.openFileError(
                result.message.isNotEmpty ? result.message : l.unknown,
              ),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.openFileError(e.toString())),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _handleWantedChange(int fileIndex, bool wanted) async {
    await widget.torrent.toggleFileWanted(fileIndex, wanted);
    if (mounted) {
      // Refresh torrents
      await Provider.of<TorrentsModel>(context, listen: false).fetchTorrents();
    }
  }

  Future<void> _handleAllWantedChange(bool wanted) async {
    await widget.torrent.toggleAllFilesWanted(wanted);
    if (mounted) {
      // Refresh torrents
      await Provider.of<TorrentsModel>(context, listen: false).fetchTorrents();
    }
  }

  // See docs/streaming.md
  void _handlePlayClick(BuildContext context, File file) {
    final String filePath = path.join(widget.location, file.name);

    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'player'),
        builder: (BuildContext context) {
          return TorrentPlayer(
            filePath: filePath,
            torrent: widget.torrent,
            file: file,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    final files = widget.torrent.files;

    // Preserve the original index through filtering so the wanted-toggle RPC
    // targets the correct file even when the filtered subset is shown and
    // `File` instances are rebuilt on every 5s poll.
    final displayedWithIndex = _showOnlyPlayable
        ? files.indexed.where((e) => _isFilePlayable(e.$2.name)).toList()
        : files.indexed.toList();

    final bool areAllFilesWanted = files.every((f) => f.wanted);
    final bool areAllFilesSkipped = files.none((f) => f.wanted);
    final globalWantedState = areAllFilesWanted
        ? true
        : areAllFilesSkipped
            ? false
            : null;

    return Column(
      children: [
        if (files.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.play_circle_outlined),
            title: Text(localizations.showOnlyPlayableFiles),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: _showOnlyPlayable,
                  onChanged: (value) {
                    setState(() {
                      _showOnlyPlayable = value;
                    });
                  },
                ),
              ],
            ),
          ),
        if (files.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.checklist),
            title: Text(
              areAllFilesWanted
                  ? localizations.deselectAllFiles
                  : localizations.selectAllFiles,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: globalWantedState,
                  tristate: true,
                  onChanged: (_) => _handleAllWantedChange(!areAllFilesWanted),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: displayedWithIndex.length,
            itemBuilder: (context, index) {
              final file = displayedWithIndex[index].$2;
              final originalIndex = displayedWithIndex[index].$1;

              final percent = file.length > 0
                  ? (file.bytesCompleted / file.length * 100).floor()
                  : null;

              final completed = file.bytesCompleted == file.length;

              final bool isPlayable = _isFilePlayable(file.name);

              return ListTile(
                leading: Icon(getFileIcon(file.name)),
                title: Text(file.name),
                subtitle: Row(
                  children: [
                    percent == null
                        ? const Text('—')
                        : percent < 100
                            ? Text('$percent %')
                            : const Icon(Icons.download_done, size: 16),
                    Text(
                      ' • ${prettyBytes(file.length.toDouble(), locale: localizations.localeName)}',
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    if (isPlayable)
                      IconButton(
                        onPressed: () {
                          _handlePlayClick(context, file);
                        },
                        icon: const Icon(Icons.play_circle_outlined),
                        tooltip: localizations.play,
                      ),
                    if (completed)
                      PopupMenuButton<String>(
                        onSelected: (value) async {
                          final filePath = path.join(
                            widget.location,
                            file.name,
                          );
                          if (value == 'open') {
                            await _openFile(file.name);
                          } else if (value == 'share') {
                            await SharePlus.instance.share(
                              ShareParams(files: [XFile(filePath)]),
                            );
                          } else if (value == 'play_in_app') {
                            _handlePlayClick(context, file);
                          }
                        },
                        itemBuilder: (context) {
                          return [
                            PopupMenuItem(
                              value: 'open',
                              child: Text(localizations.openExternally),
                            ),
                            PopupMenuItem(
                              value: 'share',
                              child: Text(localizations.share),
                            ),
                            if (lookupMimeType(
                                  file.name,
                                )?.startsWith('video/') ==
                                true)
                              PopupMenuItem(
                                value: 'play_in_app',
                                child: Text(localizations.playInApp),
                              ),
                          ];
                        },
                      ),
                    Checkbox(
                      value: file.wanted,
                      onChanged: file.bytesCompleted == file.length
                          ? null
                          : (_) => _handleWantedChange(
                                originalIndex,
                                !file.wanted,
                              ),
                    ),
                  ],
                ),
                onTap: completed
                    ? () async {
                        try {
                          await _openFile(file.name);
                        } catch (e) {
                          if (!context.mounted) return;
                          final l = AppLocalizations.of(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l.openFileError(e.toString())),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        }
                      }
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

IconData getFileIcon(String filename) {
  final mimeType = lookupMimeType(filename);

  if (mimeType != null) {
    if (mimeType.startsWith('video')) {
      return Icons.movie;
    }

    if (mimeType.startsWith('image')) {
      return Icons.image;
    }

    if (mimeType.startsWith('audio')) {
      return Icons.audiotrack;
    }
  }

  return Icons.description;
}
