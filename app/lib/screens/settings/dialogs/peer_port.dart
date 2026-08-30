import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';

class PeerPortDialog extends StatefulWidget {
  final void Function(int) onSave;
  final int currentValue;

  const PeerPortDialog({
    super.key,
    required this.onSave,
    required this.currentValue,
  });

  @override
  State<PeerPortDialog> createState() => _PeerPortDialogState();
}

class _PeerPortDialogState extends State<PeerPortDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController peerPort;

  @override
  void initState() {
    super.initState();
    peerPort = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.currentValue > 0 ? widget.currentValue.toString() : '51413',
      ),
    );
  }

  @override
  void dispose() {
    peerPort.dispose();
    super.dispose();
  }

  void handleSave() {
    if (_formKey.currentState?.validate() != true) return;
    final val = int.tryParse(peerPort.text);
    if (val == null || val < 1 || val > 65535) return;
    Navigator.of(context).pop();
    widget.onSave(val);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(localizations.incomingPort),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: peerPort,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: localizations.enterNumber),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return localizations.emptyNumber;
                }
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) {
                  return localizations.invalidNumber;
                }
                return null; // Return null if the input is valid
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(localizations.cancel),
        ),
        TextButton(onPressed: handleSave, child: Text(localizations.save)),
      ],
    );
  }
}
