import 'package:flutter/material.dart';
import 'package:gravity_torrent/services/scheduler_service.dart';
import 'package:gravity_torrent/utils/device.dart';
import 'package:gravity_torrent/widgets/window_title_bar.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';

class SchedulerScreen extends StatefulWidget {
  const SchedulerScreen({super.key});

  @override
  State<SchedulerScreen> createState() => _SchedulerScreenState();
}

class _SchedulerScreenState extends State<SchedulerScreen> {
  bool _loaded = false;
  bool _enabled = false;
  int _startHour = 23;
  int _startMinute = 0;
  int _endHour = 7;
  int _endMinute = 0;
  int _dayBitmask = 127;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await SchedulerService.instance.load();
      final svc = SchedulerService.instance;
      if (mounted) {
        setState(() {
          _enabled = svc.enabled;
          _startHour = svc.window.start.hour;
          _startMinute = svc.window.start.minute;
          _endHour = svc.window.end.hour;
          _endMinute = svc.window.end.minute;
          _dayBitmask = svc.window.dayBitmask;
        });
      }
    } catch (e, stack) {
      debugPrint('SchedulerScreen load error: $e\\n$stack');
    } finally {
      if (mounted) {
        setState(() {
          _loaded = true;
        });
      }
    }
  }

  Future<void> _save() async {
    final window = ScheduleWindow(
      start: ScheduleTime(hour: _startHour, minute: _startMinute),
      end: ScheduleTime(hour: _endHour, minute: _endMinute),
      dayBitmask: _dayBitmask,
    );
    await SchedulerService.instance.setWindow(window);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Download schedule saved')));
    }
  }

  Future<void> _pickTime(
    String label,
    int hour,
    int minute,
    ValueChanged<TimeOfDay> onPicked,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: hour, minute: minute),
      helpText: label,
    );
    if (picked != null) {
      if (!mounted) return;
      onPicked(picked);
    }
  }

  String _formatTime(int hour, int minute) {
    final t = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay(hour: hour, minute: minute));
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: isDesktop()
          ? const WindowTitleBar()
          : AppBar(title: Text(localizations.downloadScheduler)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Smart download scheduler',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Automatically pause downloads outside the configured '
                    'time window. Great for respecting peak-hour bandwidth '
                    'limits or night-rate tariffs.',
                  ),
                  const SizedBox(height: 24),
                  SwitchListTile(
                    secondary: const Icon(Icons.schedule),
                    title: Text(localizations.enableScheduler),
                    subtitle: Text(
                      _enabled
                          ? 'Active — pausing downloads outside window'
                          : 'Disabled',
                    ),
                    value: _enabled,
                    onChanged: (v) async {
                      setState(() => _enabled = v);
                      await SchedulerService.instance.setEnabled(v);
                    },
                  ),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    'Download window',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          enabled: _enabled,
                          leading: Icon(
                            Icons.play_arrow,
                            color: colorScheme.primary,
                          ),
                          title: Text(localizations.startTime),
                          subtitle: Text(
                            localizations.downloadsResumeAtThisTime,
                          ),
                          trailing: Text(
                            _loaded
                                ? _formatTime(_startHour, _startMinute)
                                : '--:--',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: colorScheme.primary),
                          ),
                          onTap: _enabled
                              ? () => _pickTime(
                                    localizations.selectStartTime,
                                    _startHour,
                                    _startMinute,
                                    (t) => setState(() {
                                      _startHour = t.hour;
                                      _startMinute = t.minute;
                                    }),
                                  )
                              : null,
                        ),
                        const Divider(indent: 16, endIndent: 16, height: 1),
                        ListTile(
                          enabled: _enabled,
                          leading: Icon(Icons.stop, color: colorScheme.error),
                          title: Text(localizations.endTime),
                          subtitle: Text(
                            localizations.downloadsPauseAtThisTime,
                          ),
                          trailing: Text(
                            _loaded
                                ? _formatTime(_endHour, _endMinute)
                                : '--:--',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: colorScheme.error),
                          ),
                          onTap: _enabled
                              ? () => _pickTime(
                                    localizations.selectEndTime,
                                    _endHour,
                                    _endMinute,
                                    (t) => setState(() {
                                      _endHour = t.hour;
                                      _endMinute = t.minute;
                                    }),
                                  )
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (_enabled) ...[
                    if (_startHour * 60 + _startMinute ==
                        _endHour * 60 + _endMinute) ...[
                      const SizedBox(height: 8),
                      Chip(
                        avatar: Icon(
                          Icons.info_outline,
                          color: colorScheme.primary,
                        ),
                        label: const Text(
                          'Start and end time are the same — downloads will run all day',
                        ),
                      ),
                    ] else if ((_startHour * 60 + _startMinute) >=
                        (_endHour * 60 + _endMinute)) ...[
                      const SizedBox(height: 8),
                      Chip(
                        avatar: Icon(
                          Icons.info_outline,
                          color: colorScheme.primary,
                        ),
                        label: Text(localizations.scheduleWrapsPastMidnight),
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Active days',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: List.generate(7, (i) {
                      final bit = 1 << i;
                      final selected = _dayBitmask & bit != 0;
                      return FilterChip(
                        label: Text(_dayLabels[i]),
                        selected: selected,
                        onSelected: _enabled
                            ? (v) {
                                setState(() {
                                  if (v) {
                                    _dayBitmask |= bit;
                                  } else {
                                    _dayBitmask &= ~bit;
                                  }
                                });
                              }
                            : null,
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _enabled ? _save : null,
                      icon: const Icon(Icons.save),
                      label: Text(localizations.saveSchedule),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
