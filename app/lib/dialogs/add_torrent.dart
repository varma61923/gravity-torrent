import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:content_resolver/content_resolver.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/models/session.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/services/recent_download_directories_service.dart';
import 'package:gravity_torrent/utils/app_links.dart';
import 'package:provider/provider.dart';
import 'package:gravity_torrent/services/ads/ad_service_provider.dart';
import 'package:gravity_torrent/utils/bencode.dart';
import 'package:path_provider/path_provider.dart';

class AddTorrentDialog extends StatefulWidget {
  final String? initialMagnetLink;
  final String? initialContentPath;

  const AddTorrentDialog({
    super.key,
    this.initialMagnetLink,
    this.initialContentPath,
  });

  @override
  State<AddTorrentDialog> createState() => _AddTorrentDialogState();
}

class _AddTorrentDialogState extends State<AddTorrentDialog> {
  late TextEditingController _torrentLinkController;
  String? _filename;
  String? pickedDownloadDir;
  String _torrentLink = ''; // Track a state to trigger updates
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _torrentLinkController = TextEditingController();

    _torrentLinkController.addListener(() {
      setState(() {
        _torrentLink = _torrentLinkController.text;
      });
    });

    if (widget.initialMagnetLink != null) {
      _torrentLinkController.text = widget.initialMagnetLink!;
    }

    setState(() {
      _filename = widget.initialContentPath;
    });

    unawaited(_loadRecentDirectories());
  }

  Future<void> _loadRecentDirectories() async {
    await RecentDownloadDirectoriesService.instance.load();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _torrentLinkController.dispose();
    super.dispose();
  }

  Future<void> _handleAddTorrent() async {
    try {
      String? metainfo;
      Uint8List? rawBytes;
      TorrentMetadata? parsedMetadata;

      if (_filename != null) {
        // From a .torrent file
        if (_filename!.startsWith('content:')) {
          // Android
          final Content content = await ContentResolver.resolveContent(
            _filename!,
          );
          rawBytes = content.data;
        } else {
          final file = File(_filename!);
          rawBytes = await file.readAsBytes();
        }

        if (rawBytes.isEmpty) {
          throw TorrentAddError();
        }

        metainfo = base64Encode(rawBytes);

        try {
          parsedMetadata = Bencode.decodeTorrent(rawBytes);
        } catch (e) {
          throw TorrentAddError();
        }
      }

      String? magnet;
      if (_filename == null) {
        // From a link (either app link or magnet)
        magnet = isAppLink(_torrentLinkController.text)
            ? getTorrentLink(_torrentLinkController.text)
            : _torrentLinkController.text;
        if (magnet == null || magnet.isEmpty) {
          throw TorrentAddError();
        }
      }

      if (!mounted) return;
      String? effectiveDownloadDir = pickedDownloadDir ??
          Provider.of<SessionModel>(
            context,
            listen: false,
          ).session?.downloadDir;
      if (effectiveDownloadDir == null || effectiveDownloadDir.isEmpty) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          effectiveDownloadDir = dir.path;
        } catch (_) {}
      }

      int freeSpace = 0;
      final downloadDirToCheck = effectiveDownloadDir;
      if (downloadDirToCheck != null) {
        try {
          if (!kIsWeb && Platform.isWindows && downloadDirToCheck.length >= 2) {
            final drive = downloadDirToCheck.substring(0, 2);
            try {
              final result = await Process.run('powershell', [
                '-NoProfile',
                '-Command',
                '(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID=\'$drive\'").FreeSpace',
              ]);
              final output = result.stdout.toString().trim();
              if (output.isNotEmpty) {
                freeSpace =
                    int.tryParse(output.split(RegExp(r'\s+')).first) ?? 0;
              }
            } on ProcessException catch (e) {
              if (kDebugMode) {
                debugPrint('PowerShell free space check failed: $e');
              }
            } catch (_) {}

            if (freeSpace == 0) {
              try {
                final result = await Process.run('wmic', [
                  'logicaldisk',
                  'where',
                  'deviceid="$drive"',
                  'get',
                  'freespace',
                ]);
                final lines = result.stdout.toString().split('\n');
                if (lines.length > 1) {
                  freeSpace = int.tryParse(lines[1].trim()) ?? 0;
                }
              } on ProcessException catch (e) {
                if (kDebugMode) debugPrint('WMIC process failed: $e');
              } catch (_) {}
            }
          } else if (!kIsWeb && (Platform.isLinux || Platform.isMacOS)) {
            final result = await Process.run('df', ['-k', downloadDirToCheck]);
            final lines = result.stdout.toString().split('\n');
            if (lines.length > 1) {
              final parts = lines[1].trim().split(RegExp(r'\s+'));
              if (parts.length > 3) {
                freeSpace = (int.tryParse(parts[3]) ?? 0) * 1024;
              }
            }
          }
        } catch (e, s) {
          if (kDebugMode) {
            debugPrint('Failed to check free space: $e\n$s');
          }
        }
      }

      // Compute exact predicted size from parsed .torrent metadata
      int predictedSize = 0;
      if (parsedMetadata != null) {
        predictedSize = parsedMetadata.totalSize;
      }

      if (!mounted) return;
      final localizations = AppLocalizations.of(context);

      if (freeSpace > 0 && predictedSize > 0 && freeSpace < predictedSize) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(localizations.lowStorageWarning),
            content: Text(localizations.lowStorageMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(localizations.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(localizations.proceed),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }

      if (!mounted) return;
      final status = await Provider.of<TorrentsModel>(
        context,
        listen: false,
      ).addTorrent(magnet, metainfo, effectiveDownloadDir);

      final dirToRemember = pickedDownloadDir ?? effectiveDownloadDir;
      if (dirToRemember?.isNotEmpty == true) {
        await RecentDownloadDirectoriesService.instance.add(dirToRemember!);
      }

      if (!mounted) return;

      if (status == TorrentAddedResponse.duplicated) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizations.torrentAlreadyAdded),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizations.torrentAdded),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
        // Show an interstitial ad occasionally when a torrent is added successfully
        AdServiceProvider.instance.showInterstitialIfReady();
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final localizations = AppLocalizations.of(context);
      final message =
          (e is TorrentAddError && e.message != null && e.message!.isNotEmpty)
              ? e.message!
              : localizations.invalidTorrent;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _handleSelectTorrentFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['torrent'],
    );
    if (result == null ||
        result.files.isEmpty ||
        result.files.first.path == null) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _filename = result.files.first.path!;
    });
  }

  Future<void> _handlePickDirectory() async {
    final localizations = AppLocalizations.of(context);
    final String? selectedDirectory = await FilePicker.getDirectoryPath(
      dialogTitle: localizations.downloadDirectoryPickerTitle,
    );

    if (selectedDirectory == null) return;
    await RecentDownloadDirectoriesService.instance.add(selectedDirectory);
    if (!mounted) return;
    setState(() {
      pickedDownloadDir = selectedDirectory;
    });
  }

  Future<void> _handlePasteFromClipboard() async {
    final localizations = AppLocalizations.of(context);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizations.clipboardEmpty),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      _torrentLinkController.text = text.trim();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(localizations.clipboardEmpty),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Widget _buildRecentDirectoriesChipRow() {
    final localizations = AppLocalizations.of(context);
    final recentDirs = RecentDownloadDirectoriesService.instance.directories;

    if (recentDirs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localizations.recentDownloadDirectories),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ...recentDirs.map((dir) {
              return ActionChip(
                label: Text(dir, overflow: TextOverflow.ellipsis),
                onPressed: () {
                  setState(() {
                    pickedDownloadDir = dir;
                  });
                },
              );
            }),
            ActionChip(
              avatar: const Icon(Icons.clear_all, size: 18),
              label: Text(localizations.clearRecentDownloadDirectories),
              onPressed: () async {
                await RecentDownloadDirectoriesService.instance.clear();
                if (!mounted) return;
                setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTorrentLinkInput() {
    final localizations = AppLocalizations.of(context);
    return TextFormField(
      enabled: _filename == null || _filename!.isEmpty,
      controller: _torrentLinkController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.link),
        hintText: localizations.torrentLinkHint,
        label: Text(localizations.torrentLinkLabel),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: localizations.pasteTorrentLink,
              onPressed: _handlePasteFromClipboard,
              icon: const Icon(Icons.paste),
            ),
            if (_torrentLinkController.text.isNotEmpty)
              IconButton(
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onPressed: () => _torrentLinkController.clear(),
                icon: const Icon(Icons.clear),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileInput(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: FilledButton(
            onPressed:
                _torrentLink.isEmpty ? () => _handleSelectTorrentFile() : null,
            child: Text(
              _filename != null ? _filename! : localizations.selectTorrentFile,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (_filename != null)
          Row(
            children: [
              const SizedBox(width: 8),
              IconButton(
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onPressed: () {
                  setState(() {
                    _filename = null;
                  });
                },
                icon: const Icon(Icons.clear),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildInputsSeparator() {
    final localizations = AppLocalizations.of(context);
    return Column(
      children: [
        const SizedBox(height: 16),
        Text(localizations.addTorrentOr),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final downloadDir = pickedDownloadDir ??
        Provider.of<SessionModel>(context, listen: true).session?.downloadDir ??
        '';

    final String? decodedLink =
        isAppLink(_torrentLink) ? getTorrentLink(_torrentLink) : null;
    final String? link = isAppLink(_torrentLink) ? decodedLink : _torrentLink;
    final effectiveLink = _filename ?? link;
    final isValid = effectiveLink != null && effectiveLink.isNotEmpty;

    return AlertDialog(
      title: Text(localizations.addTorrentTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTorrentLinkInput(),
                _buildInputsSeparator(),
                _buildFileInput(context),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(localizations.addTorrentDestination),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextButton(
                        onPressed: _handlePickDirectory,
                        child: Text(
                          downloadDir,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildRecentDirectoriesChipRow(),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: Text(localizations.cancel),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        TextButton(
          onPressed: isValid
              ? () {
                  if (_formKey.currentState!.validate()) {
                    _handleAddTorrent();
                  }
                }
              : null,
          child: Text(localizations.download),
        ),
      ],
    );
  }
}
