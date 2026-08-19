import 'package:flutter/material.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

class SubtitlesSelectorDialog extends StatefulWidget {
  final List<SubtitleTrack> subtitles;
  final Function(SubtitleTrack) onSubtitleSelected;
  final String currentValue;
  const SubtitlesSelectorDialog({
    super.key,
    required this.onSubtitleSelected,
    required this.currentValue,
    required this.subtitles,
  });

  @override
  State<SubtitlesSelectorDialog> createState() =>
      _SubtitlesSelectorDialogState();
}

class _SubtitlesSelectorDialogState extends State<SubtitlesSelectorDialog> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The option list below deliberately omits the 'auto' track (there is no
    // "Auto" tile), so if the player is currently in that state - the
    // engine's own default before anything is explicitly selected - map it
    // to 'no' instead of leaving no tile checked at all.
    final effectiveValue =
        widget.currentValue == 'auto' ? 'no' : widget.currentValue;
    return AlertDialog(
      title: Text(l.subtitles),
      content: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: effectiveValue,
          onChanged: (id) {
            if (id == null) return;
            final s = widget.subtitles.firstWhere((s) => s.id == id);
            widget.onSubtitleSelected(s);
            Navigator.of(context).pop();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ...widget.subtitles.where((s) => s.id != 'auto').toList().map((
                sub,
              ) {
                return RadioListTile<String>(
                  title: Text(
                    sub.id == 'no' ? l.noSubtitle : sub.title ?? l.unknown,
                  ),
                  value: sub.id,
                );
              }),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: Text(l.cancel),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
