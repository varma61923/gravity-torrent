import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/services/torrent_creator_service.dart';
import 'package:path/path.dart' as p;

class CreateTorrentDialog extends StatefulWidget {
  const CreateTorrentDialog({super.key});

  @override
  State<CreateTorrentDialog> createState() => _CreateTorrentDialogState();
}

class _CreateTorrentDialogState extends State<CreateTorrentDialog> {
  String? _inputPath;
  String? _outputDirectory;
  final _trackersController = TextEditingController();
  bool _addForSeeding = true;
  bool _isPrivate = false;
  bool _creating = false;
  double _progress = 0;

  @override
  void dispose() {
    _trackersController.dispose();
    super.dispose();
  }

  void _safeSetState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _pickInputFile() async {
    final l = AppLocalizations.of(context);
    final result = await FilePicker.pickFiles(dialogTitle: l.selectSourceFile);
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    setState(() => _inputPath = result.files.first.path);
  }

  Future<void> _pickInputDirectory() async {
    final l = AppLocalizations.of(context);
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: l.selectSourceDirectory,
    );
    if (dir == null) return;
    if (!mounted) return;
    setState(() => _inputPath = dir);
  }

  Future<void> _pickOutputDirectory() async {
    final l = AppLocalizations.of(context);
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: l.selectOutputDirectory,
    );
    if (dir == null) return;
    if (!mounted) return;
    setState(() => _outputDirectory = dir);
  }

  Future<void> _create() async {
    if (_inputPath == null || _outputDirectory == null) return;

    final inputPath = _inputPath!;
    final outputDirectory = _outputDirectory!;

    final trackers =
        TorrentCreatorService.parseTrackerTiers(_trackersController.text);

    setState(() {
      _creating = true;
      _progress = 0;
    });

    try {
      final outputPath = await TorrentCreatorService.create(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        trackers: trackers,
        isPrivate: _isPrivate,
        onProgress: (progress) {
          _safeSetState(() => _progress = progress.fraction);
        },
      );

      if (!mounted) return;

      if (_addForSeeding) {
        await TorrentCreatorService.addForSeeding(outputPath, null);
      }

      if (!mounted) return;
      Navigator.of(context).pop(outputPath);
    } catch (e) {
      if (kDebugMode) debugPrint('Create torrent failed: $e');
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.createTorrentFailed(e.toString()))),
      );
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final canCreate =
        _inputPath != null && _outputDirectory != null && !_creating;

    return AlertDialog(
      title: Text(l.createTorrent),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(
                  _inputPath == null
                      ? l.sourceFileOrFolder
                      : p.basename(_inputPath!),
                ),
                subtitle: _inputPath != null ? Text(_inputPath!) : null,
                trailing: PopupMenuButton<VoidCallback>(
                  onSelected: (fn) => fn(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _pickInputFile,
                      child: Text(l.selectFile),
                    ),
                    PopupMenuItem(
                      value: _pickInputDirectory,
                      child: Text(l.selectDirectory),
                    ),
                  ],
                  child: const Icon(Icons.more_vert),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.save),
                title: Text(
                  _outputDirectory == null
                      ? l.outputFolder
                      : p.basename(_outputDirectory!),
                ),
                subtitle:
                    _outputDirectory != null ? Text(_outputDirectory!) : null,
                trailing: IconButton(
                  tooltip: l.selectOutputDirectory,
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickOutputDirectory,
                ),
              ),
              TextField(
                controller: _trackersController,
                decoration: InputDecoration(
                  labelText: l.trackersLabel,
                  helperText: l.trackersHelper,
                ),
                maxLines: 4,
              ),
              SwitchListTile(
                title: Text(l.addForSeeding),
                subtitle: Text(l.addForSeedingSubtitle),
                value: _addForSeeding,
                onChanged: (v) => setState(() => _addForSeeding = v),
              ),
              SwitchListTile(
                title: Text(l.privateTorrent),
                value: _isPrivate,
                onChanged: (v) => setState(() => _isPrivate = v),
              ),
              if (_creating) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(l.creatingTorrent),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: canCreate ? _create : null,
          child: Text(l.create),
        ),
      ],
    );
  }
}
