import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:gravity_torrent/constants/locales.dart';
import 'package:gravity_torrent/services/ads/ad_service_provider.dart';
import 'package:gravity_torrent/services/app_lock_service.dart';
import 'package:gravity_torrent/services/battery_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/services/recent_download_directories_service.dart';
import 'package:gravity_torrent/services/recent_search_queries_service.dart';
import 'package:gravity_torrent/services/torrent_favorites_service.dart';
import 'package:gravity_torrent/services/torrent_notes_service.dart';
import 'package:gravity_torrent/services/wifi_guard_service.dart';
import 'package:gravity_torrent/dialogs/reusable/number_input.dart';
import 'package:gravity_torrent/engine/session.dart';
import 'package:gravity_torrent/main.dart';
import 'package:gravity_torrent/models/app.dart';
import 'package:gravity_torrent/models/feature_flags.dart';
import 'package:gravity_torrent/models/session.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/screens/settings/dialogs/blocklist_url.dart';
import 'package:gravity_torrent/screens/settings/dialogs/encryption_selector.dart';
import 'package:gravity_torrent/screens/settings/dialogs/locale_selector.dart';
import 'package:gravity_torrent/screens/settings/dialogs/maximum_active_downloads_editor.dart';
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';
import 'package:gravity_torrent/screens/settings/dialogs/ratio_input.dart';
import 'package:gravity_torrent/screens/settings/dialogs/reset_torrent_settings.dart';
import 'package:gravity_torrent/screens/settings/dialogs/theme_selector.dart';
import 'package:gravity_torrent/screens/settings/dialogs/turtle_schedule_dialog.dart';
import 'package:gravity_torrent/screens/settings/sections/accessibility_section.dart';
import 'package:gravity_torrent/screens/settings/sections/notification_settings_section.dart';
import 'package:gravity_torrent/screens/settings/sections/auto_start_section.dart';
import 'package:gravity_torrent/dialogs/backup_restore_dialog.dart';
import 'package:gravity_torrent/widgets/ad_banner_slot.dart';
import 'package:gravity_torrent/widgets/rate_app_tile.dart';
import 'package:gravity_torrent/utils/string_extensions.dart';
import 'package:gravity_torrent/utils/update.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/services/auto_extract_service.dart';
import 'package:gravity_torrent/widgets/bandwidth_heatmap_widget.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool canCheckForUpdate = false;
  bool showAdvancedSettings = false;
  bool _appLockToggleBusy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bool isFromAppStore = await isDistributedFromAppStore();
    await RecentDownloadDirectoriesService.instance.load();
    if (!mounted) return;
    setState(() {
      canCheckForUpdate = !isFromAppStore;
    });
  }

  // Handlers
  Future<void> handlePickFolder(BuildContext context) async {
    final localizations = AppLocalizations.of(context);

    String? selectedDirectory;
    bool pickerFailed = false;
    try {
      selectedDirectory = await FilePicker.getDirectoryPath(
        dialogTitle: localizations.downloadDirectoryPickerTitle,
      );
    } catch (e) {
      pickerFailed = true;
      if (kDebugMode) {
        debugPrint('FilePicker.getDirectoryPath failed: $e');
      }
    }

    // Fallback to a manual input dialog if the native picker failed
    if (pickerFailed) {
      if (!context.mounted) return;
      selectedDirectory = await _showManualDownloadDirDialog(context);
    }

    if (selectedDirectory == null || selectedDirectory.trim().isEmpty) return;
    selectedDirectory = selectedDirectory.trim();

    // Make sure the directory exists before telling the engine to use it.
    try {
      final dir = Directory(selectedDirectory);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${localizations.error}: $e'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (!context.mounted) return;
    final sessionModel = Provider.of<SessionModel>(context, listen: false);
    if (sessionModel.session == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session not loaded yet. Please try again.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    try {
      await sessionModel.session!.update(
        SessionBase(downloadDir: selectedDirectory),
      );
      if (!context.mounted) return;
      await sessionModel.fetchSession();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${localizations.error}: $e'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<String?> _showManualDownloadDirDialog(BuildContext context) async {
    final localizations = AppLocalizations.of(context);
    String? path;
    return showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(localizations.downloadDirectory),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText:
                  'e.g. /home/user/Downloads or C:\\Users\\You\\Downloads',
            ),
            onChanged: (value) => path = value,
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(localizations.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, path?.trim()),
              child: Text(localizations.save),
            ),
          ],
        );
      },
    );
  }

  Future<void> handleMaximumActiveDownloadsSave(
    BuildContext context,
    int value,
  ) async {
    final sessionUpdate = SessionBase(downloadQueueSize: value);
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.session?.update(sessionUpdate);
      await sessionModel.fetchSession();
    }
  }

  Future<void> handlePeerPortSave(BuildContext context, int value) async {
    final sessionUpdate = SessionBase(peerPort: value);
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.session?.update(sessionUpdate);
      await sessionModel.fetchSession();
    }
  }

  Future<void> handleSpeedLimitDownSave(BuildContext context, int value) async {
    final sessionUpdate = SessionBase(speedLimitDown: value);
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.session?.update(sessionUpdate);
      await sessionModel.fetchSession();
    }
  }

  Future<void> handleSpeedLimitUpSave(BuildContext context, int value) async {
    final sessionUpdate = SessionBase(speedLimitUp: value);
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.session?.update(sessionUpdate);
      await sessionModel.fetchSession();
    }
  }

  Future<void> handleResetTorrentsSettings(BuildContext context) async {
    await engine.resetSettings();
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.fetchSession();
    }
  }

  Future<void> _handleEnableSpeedLimits(bool value) async {
    final sessionUpdate = SessionBase(
      speedLimitDownEnabled: value,
      speedLimitUpEnabled: value,
    );
    if (context.mounted) {
      final sessionModel = Provider.of<SessionModel>(context, listen: false);
      await sessionModel.session?.update(sessionUpdate);
      await sessionModel.fetchSession();
    }
  }

  // SOTA feature toggle subtitle
  Widget? _featureSubtitle(String key, FeatureFlagsModel flags) {
    if (flags.isRemotelyDisabled(key)) {
      return Text(
        AppLocalizations.of(context).disabledByRemoteConfig,
        style: const TextStyle(color: Colors.orange),
      );
    }
    return null;
  }

  // Privacy & security
  Future<void> _updateSession(SessionBase update) async {
    if (!mounted) return;
    final sessionModel = Provider.of<SessionModel>(context, listen: false);
    await sessionModel.session?.update(update);
    if (!mounted) return;
    await sessionModel.fetchSession();
  }

  void _handleEncryptionChange(EncryptionMode mode) =>
      _updateSession(SessionBase(encryption: mode));

  void _handleBlocklistToggle(bool value) =>
      _updateSession(SessionBase(blocklistEnabled: value));

  Future<void> _handleBlocklistUrlSave(String url) async {
    final trimmed = url.trim();
    if (trimmed.isNotEmpty) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).validUrlRequired),
            ),
          );
        }
        return;
      }
      // Validate against SSRF (private host) using the same gate as
      // BlocklistService. Async, so this handler is now async.
      final isRoutable = await BlocklistService.isValidBlocklistUrl(trimmed);
      if (!isRoutable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).validUrlRequired),
            ),
          );
        }
        return;
      }
    }
    await _updateSession(
      SessionBase(blocklistUrl: trimmed, blocklistEnabled: trimmed.isNotEmpty),
    );
  }

  void _handleDhtToggle(bool value) =>
      _updateSession(SessionBase(dhtEnabled: value));

  void _handlePexToggle(bool value) =>
      _updateSession(SessionBase(pexEnabled: value));

  void _handleLpdToggle(bool value) =>
      _updateSession(SessionBase(lpdEnabled: value));

  void _handleUtpToggle(bool value) =>
      _updateSession(SessionBase(utpEnabled: value));

  void showEncryptionDialog() {
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(localizations.encryption),
          content: EncryptionSelector(
            currentValue: session?.encryption ?? EncryptionMode.preferred,
            onChanged: (mode) {
              Navigator.of(context).pop();
              _handleEncryptionChange(mode);
            },
          ),
          actions: <Widget>[
            TextButton(
              child: Text(localizations.cancel),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  void showBlocklistUrlDialog() {
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return BlocklistUrlDialog(
          currentValue: session?.blocklistUrl ?? '',
          onSave: _handleBlocklistUrlSave,
        );
      },
    );
  }

  String _encryptionLabel(AppLocalizations localizations, EncryptionMode mode) {
    return switch (mode) {
      EncryptionMode.preferred => localizations.encryptionPreferred,
      EncryptionMode.required => localizations.encryptionRequired,
      EncryptionMode.tolerated => localizations.encryptionTolerated,
    };
  }

  // Scheduling & seeding limits
  void _handleTurtleToggle(bool value) =>
      _updateSession(SessionBase(altSpeedEnabled: value));

  void _handleTurtleScheduleToggle(bool value) =>
      _updateSession(SessionBase(altSpeedTimeEnabled: value));

  void _handleSeedRatioToggle(bool value) =>
      _updateSession(SessionBase(seedRatioLimited: value));

  void _handleIdleSeedingToggle(bool value) =>
      _updateSession(SessionBase(idleSeedingLimitEnabled: value));

  void showAltSpeedDownDialog() {
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return NumberInputDialog(
          title:
              '${localizations.turtleDownloadLimit} ${localizations.kilobytesPerSecond}',
          currentValue: session?.altSpeedDown ?? 0,
          onSave: (value) => _updateSession(SessionBase(altSpeedDown: value)),
        );
      },
    );
  }

  void showAltSpeedUpDialog() {
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return NumberInputDialog(
          title:
              '${localizations.turtleUploadLimit} ${localizations.kilobytesPerSecond}',
          currentValue: session?.altSpeedUp ?? 0,
          onSave: (value) => _updateSession(SessionBase(altSpeedUp: value)),
        );
      },
    );
  }

  void showTurtleScheduleDialog() {
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return TurtleScheduleDialog(
          beginMinutes: session?.altSpeedTimeBegin ?? 540,
          endMinutes: session?.altSpeedTimeEnd ?? 1020,
          dayBitfield: session?.altSpeedTimeDay ?? 127,
          onSave: (begin, end, day) => _updateSession(
            SessionBase(
              altSpeedTimeBegin: begin,
              altSpeedTimeEnd: end,
              altSpeedTimeDay: day,
            ),
          ),
        );
      },
    );
  }

  void showSeedRatioDialog() {
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return RatioInputDialog(
          currentValue: session?.seedRatioLimit ?? 0,
          onSave: (value) => _updateSession(
            SessionBase(seedRatioLimit: value, seedRatioLimited: true),
          ),
        );
      },
    );
  }

  void showIdleSeedingDialog() {
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return NumberInputDialog(
          title: localizations.idleSeedingLimit,
          currentValue: session?.idleSeedingLimit ?? 30,
          onSave: (value) => _updateSession(
            SessionBase(idleSeedingLimit: value, idleSeedingLimitEnabled: true),
          ),
        );
      },
    );
  }

  String _formatSchedule(int begin, int end) {
    String fmt(int minutes) {
      final t = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
      return MaterialLocalizations.of(context).formatTimeOfDay(t);
    }

    return '${fmt(begin)} – ${fmt(end)}';
  }

  // Dialogs
  void showThemeDialog(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(localizations.theme),
          content: const ThemeSelector(),
          actions: <Widget>[
            TextButton(
              child: Text(localizations.cancel),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void showLocaleDialog(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context).language),
          content: const LocaleSelector(),
          actions: <Widget>[
            TextButton(
              child: Text(localizations.cancel),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void showMaximumActiveDownloadDialog() {
    final stateContext = context;
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return MaximumActiveDownloadEditorDialog(
          currentValue: session?.downloadQueueSize ?? 0,
          onSave: (value) =>
              handleMaximumActiveDownloadsSave(stateContext, value),
        );
      },
    );
  }

  void showPeerPortDialog() {
    final stateContext = context;
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return PeerPortDialog(
          currentValue: session?.peerPort ?? 0,
          onSave: (value) => handlePeerPortSave(stateContext, value),
        );
      },
    );
  }

  void showSpeedLimitDownDialog() {
    final stateContext = context;
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return NumberInputDialog(
          title:
              '${localizations.downloadSpeed} ${localizations.kilobytesPerSecond}',
          currentValue: session?.speedLimitDown ?? 0,
          onSave: (value) => handleSpeedLimitDownSave(stateContext, value),
        );
      },
    );
  }

  void showSpeedLimitUpDialog() {
    final stateContext = context;
    final localizations = AppLocalizations.of(context);
    final session = Provider.of<SessionModel>(context, listen: false).session;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return NumberInputDialog(
          title:
              '${localizations.uploadSpeed} ${localizations.kilobytesPerSecond}',
          currentValue: session?.speedLimitUp ?? 0,
          onSave: (value) => handleSpeedLimitUpSave(stateContext, value),
        );
      },
    );
  }

  void showResetTorrentsSettingsDialog() {
    final stateContext = context;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return ResetTorrentsSettingsDialog(
          onOK: () => handleResetTorrentsSettings(stateContext),
        );
      },
    );
  }

  void _handleCheckForUpdateToggle(bool value) {
    final appModel = Provider.of<AppModel>(context, listen: false);
    appModel.setCheckForUpdate(value);
  }

  Future<void> _handleAppLockToggle(bool value, FeatureFlagsModel flags) async {
    // The switch's `value` only reflects `flags.enableAppLock`, which does
    // not change until this async handler finishes, so a rapid double-tap
    // would otherwise re-enter this method and push '/privacy-vault' twice.
    if (_appLockToggleBusy) return;
    _appLockToggleBusy = true;
    try {
      if (value) {
        if (!AppLockService.instance.hasPin) {
          await context.push('/privacy-vault');
          if (!mounted || !AppLockService.instance.hasPin) return;
        }
        await flags.setEnableAppLock(true);
      } else {
        if (AppLockService.instance.hasPin) {
          final authenticated =
              await context.push<bool>('/privacy-vault') ?? false;
          if (!mounted || !authenticated) return;
        }
        await flags.setEnableAppLock(false);
      }
    } finally {
      _appLockToggleBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    return Consumer3<AppModel, SessionModel, FeatureFlagsModel>(
      builder: (context, app, sessionModel, flags, _) {
        final downloadDir = sessionModel.session?.downloadDir ?? '';
        final downloadQueueSize = sessionModel.session?.downloadQueueSize ?? '';
        final peerPort = sessionModel.session?.peerPort ?? '';
        final isSpeedLimitEnabled =
            sessionModel.session?.speedLimitDownEnabled == true ||
                sessionModel.session?.speedLimitUpEnabled == true;
        final encryptionMode =
            sessionModel.session?.encryption ?? EncryptionMode.preferred;
        final blocklistEnabled =
            sessionModel.session?.blocklistEnabled ?? false;
        final blocklistUrl = sessionModel.session?.blocklistUrl ?? '';
        final blocklistSize = sessionModel.session?.blocklistSize ?? 0;
        final dhtEnabled = sessionModel.session?.dhtEnabled ?? true;
        final pexEnabled = sessionModel.session?.pexEnabled ?? true;
        final lpdEnabled = sessionModel.session?.lpdEnabled ?? false;
        final utpEnabled = sessionModel.session?.utpEnabled ?? true;
        final turtleEnabled = sessionModel.session?.altSpeedEnabled ?? false;
        final turtleDown = sessionModel.session?.altSpeedDown ?? 0;
        final turtleUp = sessionModel.session?.altSpeedUp ?? 0;
        final turtleScheduleEnabled =
            sessionModel.session?.altSpeedTimeEnabled ?? false;
        final turtleBegin = sessionModel.session?.altSpeedTimeBegin ?? 540;
        final turtleEnd = sessionModel.session?.altSpeedTimeEnd ?? 1020;
        final seedRatioLimited =
            sessionModel.session?.seedRatioLimited ?? false;
        final seedRatioLimit = sessionModel.session?.seedRatioLimit ?? 0;
        final idleSeedingEnabled =
            sessionModel.session?.idleSeedingLimitEnabled ?? false;
        final idleSeedingLimit = sessionModel.session?.idleSeedingLimit ?? 0;

        final advancedTiles = showAdvancedSettings
            ? <Widget>[
                ListTile(
                  onTap: showPeerPortDialog,
                  leading: const Icon(Icons.arrow_right_alt),
                  title: Text(localizations.listeningPort),
                  subtitle: Text(peerPort.toString()),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.data_usage),
                  title: Text(localizations.dataUsageAnalytics),
                  subtitle: _featureSubtitle('enableAnalytics', flags),
                  value: flags.enableAnalytics,
                  onChanged: (v) => flags.setEnableAnalytics(v),
                ),
                if (flags.enableAnalytics)
                  ListTile(
                    leading: const Icon(Icons.bar_chart),
                    title: Text(localizations.dataUsageDashboard),
                    onTap: () => context.push('/analytics'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.wifi_tethering),
                  title: Text(localizations.localRemoteControl),
                  subtitle: _featureSubtitle('enableRemoteControl', flags),
                  value: flags.enableRemoteControl,
                  onChanged: (v) => flags.setEnableRemoteControl(v),
                ),
                if (flags.enableRemoteControl)
                  ListTile(
                    leading: const Icon(Icons.qr_code),
                    title: Text(localizations.remoteControl),
                    onTap: () => context.push('/remote-control'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.schedule),
                  title: Text(localizations.smartDownloadScheduler),
                  subtitle: _featureSubtitle('enableScheduler', flags),
                  value: flags.enableScheduler,
                  onChanged: (v) => flags.setEnableScheduler(v),
                ),
                if (flags.enableScheduler)
                  ListTile(
                    leading: const Icon(Icons.access_alarms),
                    title: Text(localizations.downloadSchedule),
                    onTap: () => context.push('/scheduler'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.data_saver_on),
                  title: Text(localizations.monthlyBandwidthQuota),
                  subtitle: _featureSubtitle('enableQuota', flags),
                  value: flags.enableQuota,
                  onChanged: (v) => flags.setEnableQuota(v),
                ),
                if (flags.enableQuota)
                  ListTile(
                    leading: const Icon(Icons.storage),
                    title: Text(localizations.bandwidthQuotaSettings),
                    onTap: () => context.push('/quota'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.rss_feed),
                  title: Text(localizations.rssAutoDownload),
                  subtitle: _featureSubtitle('enableRssAutoDownload', flags),
                  value: flags.enableRssAutoDownload,
                  onChanged: (v) => flags.setEnableRssAutoDownload(v),
                ),
                if (flags.enableRssAutoDownload)
                  ListTile(
                    leading: const Icon(Icons.feed),
                    title: Text(localizations.rssFeeds),
                    onTap: () => context.push('/rss'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.wifi),
                  title: Text(localizations.wifiOnlyMode),
                  subtitle: _featureSubtitle('enableWifiOnly', flags),
                  value: flags.enableWifiOnly &&
                      WifiGuardService.instance.mode == WifiGuardMode.wifiOnly,
                  onChanged: (v) {
                    if (v) {
                      flags.setEnableWifiOnly(true);
                      WifiGuardService.instance.setMode(WifiGuardMode.wifiOnly);
                    } else {
                      flags.setEnableWifiOnly(false);
                    }
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.security),
                  title: Text(localizations.vpnKillSwitch),
                  subtitle: Text(localizations.vpnKillSwitchDescription),
                  value: flags.enableWifiOnly &&
                      WifiGuardService.instance.mode ==
                          WifiGuardMode.vpnKillSwitch,
                  onChanged: (v) {
                    if (v) {
                      flags.setEnableWifiOnly(true);
                      WifiGuardService.instance.setMode(
                        WifiGuardMode.vpnKillSwitch,
                      );
                    } else {
                      flags.setEnableWifiOnly(false);
                    }
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.cast),
                  title: Text(localizations.lanStreaming),
                  subtitle: Text(localizations.lanStreamingDescription),
                  value: flags.enableLanStreaming,
                  onChanged: (v) => flags.setEnableLanStreaming(v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.shield_outlined),
                  title: Text(localizations.peerBlocklistManager),
                  subtitle: Text(
                    BlocklistService.instance.isEnabled
                        ? localizations.peerBlocklistManagerActive(
                            BlocklistService.instance.rulesCount,
                          )
                        : localizations.peerBlocklistManagerDisabled,
                  ),
                  value: BlocklistService.instance.isEnabled,
                  onChanged: (v) async {
                    await BlocklistService.instance.setEnabled(v);
                    if (v) {
                      try {
                        await BlocklistService.instance.updateNow();
                      } catch (e) {
                        if (kDebugMode) {
                          debugPrint('Blocklist update failed: $e');
                        }
                      }
                    }
                    if (mounted) {
                      setState(() {});
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.battery_saver),
                  title: Text(localizations.batterySaverMode),
                  subtitle: _featureSubtitle('enableBatterySaver', flags),
                  value: flags.enableBatterySaver,
                  onChanged: (v) => flags.setEnableBatterySaver(v),
                ),
                if (flags.enableBatterySaver)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 72, right: 16),
                    title: Text(localizations.batteryThreshold),
                    subtitle: Text('${BatteryService.instance.threshold}%'),
                    onTap: () {
                      showDialog<void>(
                        context: context,
                        builder: (context) => NumberInputDialog(
                          title: localizations.batteryThresholdDialogTitle,
                          currentValue: BatteryService.instance.threshold,
                          onSave: (val) {
                            BatteryService.instance.setThreshold(val);
                            if (mounted) setState(() {});
                          },
                        ),
                      );
                    },
                  ),
                Consumer<AutoExtractService>(
                  builder: (context, autoExtractService, _) {
                    return SwitchListTile(
                      secondary: const Icon(Icons.folder_zip),
                      title: Text(localizations.autoExtractArchives),
                      subtitle: Text(
                        localizations.autoExtractArchivesDescription,
                      ),
                      value: autoExtractService.autoExtractEnabled,
                      onChanged: autoExtractService.setAutoExtractEnabled,
                    );
                  },
                ),
                const AutoStartSection(),
                SwitchListTile(
                  secondary: const Icon(Icons.lock),
                  title: Text(localizations.appLock),
                  subtitle: _featureSubtitle('enableAppLock', flags),
                  value: flags.enableAppLock,
                  onChanged: (v) => _handleAppLockToggle(v, flags),
                ),
                if (flags.enableAppLock)
                  ListTile(
                    leading: const Icon(Icons.shield),
                    title: Text(localizations.privacyVault),
                    subtitle: Text(localizations.privacyVaultSubtitle),
                    onTap: () => context.push('/privacy-vault'),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active),
                  title: Text(localizations.enhancedNotifications),
                  subtitle: _featureSubtitle('useEnhancedNotifications', flags),
                  value: flags.useEnhancedNotifications,
                  onChanged: (v) => flags.setUseEnhancedNotifications(v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.picture_in_picture_alt),
                  title: Text(localizations.backgroundAudioPip),
                  subtitle: _featureSubtitle('usePipBackgroundAudio', flags),
                  value: flags.usePipBackgroundAudio,
                  onChanged: (v) => flags.setUsePipBackgroundAudio(v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration),
                  title: Text(localizations.hapticFeedback),
                  subtitle: _featureSubtitle('enableHaptic', flags),
                  value: flags.enableHaptic,
                  onChanged: (v) => flags.setEnableHaptic(v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.shortcut),
                  title: Text(localizations.appShortcuts),
                  subtitle: _featureSubtitle('enableShortcuts', flags),
                  value: flags.enableShortcuts,
                  onChanged: (v) => flags.setEnableShortcuts(v),
                ),
                const AccessibilitySection(),
                const NotificationSettingsSection(),
                ListTile(
                  onTap: showResetTorrentsSettingsDialog,
                  leading: const Icon(Icons.settings_backup_restore),
                  title: Text(localizations.resetTorrentsSettings),
                ),
                ListTile(
                  leading: const Icon(Icons.backup),
                  title: Text(localizations.backupRestore),
                  subtitle: Text(localizations.backupDescription),
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => const BackupRestoreDialog(),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore_rounded),
                  title: Text(localizations.backupAndRestoreSettings),
                  onTap: () => context.push('/backup'),
                ),
              ]
            : <Widget>[];

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _SettingsSection(
                    icon: Icons.palette,
                    title: 'Appearance',
                    children: [
                      ListTile(
                        onTap: () => showThemeDialog(context),
                        leading: const Icon(Icons.dark_mode),
                        title: Text(localizations.theme),
                        subtitle: Text(app.theme.name.capitalize()),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.color_lens),
                        title: Text(localizations.dynamicColor),
                        subtitle: _featureSubtitle('useDynamicColor', flags),
                        value: flags.useDynamicColor,
                        onChanged: (v) => flags.setUseDynamicColor(v),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.nightlight_round),
                        title: Text(localizations.amoledTrueBlack),
                        subtitle: Text(
                          localizations.amoledTrueBlackDescription,
                        ),
                        value: app.amoledBlack,
                        onChanged: (v) => app.setAmoledBlack(v),
                      ),
                      ExpansionTile(
                        leading: const Icon(Icons.display_settings),
                        title: const Text('Display options'),
                        children: [
                          SwitchListTile(
                            secondary: const Icon(Icons.view_agenda),
                            title: Text(localizations.compactList),
                            subtitle: Text(
                              localizations.compactListDescription,
                            ),
                            value: app.compactList,
                            onChanged: (v) => app.setCompactList(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.label),
                            title: Text(localizations.showTorrentLabels),
                            subtitle: Text(
                              localizations.showTorrentLabelsDescription,
                            ),
                            value: app.showTorrentLabels,
                            onChanged: (v) => app.setShowTorrentLabels(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.filter_list),
                            title: Text(localizations.showStatusFilterChips),
                            subtitle: Text(
                              localizations.showStatusFilterChipsDescription,
                            ),
                            value: app.showStatusFilterChips,
                            onChanged: (v) => app.setShowStatusFilterChips(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.history),
                            title: Text(localizations.showRecentSearchQueries),
                            subtitle: Text(
                              localizations.showRecentSearchQueriesDescription,
                            ),
                            value: app.showRecentSearchQueries,
                            onChanged: (v) => app.setShowRecentSearchQueries(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.speed),
                            title: Text(localizations.showLiveSpeedHeader),
                            subtitle: Text(
                              localizations.showLiveSpeedHeaderDescription,
                            ),
                            value: app.showLiveSpeedHeader,
                            onChanged: (v) => app.setShowLiveSpeedHeader(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.format_list_numbered),
                            title: Text(localizations.showVisibleTorrentCount),
                            subtitle: Text(
                              localizations.showVisibleTorrentCountDescription,
                            ),
                            value: app.showVisibleTorrentCount,
                            onChanged: (v) => app.setShowVisibleTorrentCount(v),
                          ),
                          SwitchListTile(
                            secondary: const Icon(Icons.health_and_safety),
                            title: Text(localizations.showTorrentHealthBadge),
                            subtitle: Text(
                              localizations.showTorrentHealthBadgeDescription,
                            ),
                            value: app.showTorrentHealthBadge,
                            onChanged: (v) => app.setShowTorrentHealthBadge(v),
                          ),
                        ],
                      ),
                      ListTile(
                        onTap: () => showLocaleDialog(context),
                        leading: const Icon(Icons.language),
                        title: Text(localizations.language),
                        subtitle: Text(localeNames[app.locale] ?? app.locale),
                      ),
                    ],
                  ),
                  _SettingsSection(
                    icon: Icons.download_for_offline,
                    title: 'Downloads',
                    children: [
                      ListTile(
                        onTap: () => handlePickFolder(context),
                        leading: const Icon(Icons.folder_open),
                        title: Text(localizations.downloadDirectory),
                        subtitle: Text(downloadDir),
                      ),
                      ListTile(
                        leading: const Icon(Icons.clear_all),
                        title: Text(
                          localizations.clearRecentDownloadDirectories,
                        ),
                        onTap: () async {
                          await RecentDownloadDirectoriesService.instance
                              .clear();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  localizations.recentDirectoriesCleared,
                                ),
                                backgroundColor: Colors.lightGreen,
                              ),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.search_off),
                        title: Text(localizations.clearRecentSearches),
                        onTap: () async {
                          await RecentSearchQueriesService.instance.clear();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  localizations.recentSearchesCleared,
                                ),
                                backgroundColor: Colors.lightGreen,
                              ),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.star_border),
                        title: Text(localizations.clearFavorites),
                        onTap: () async {
                          await TorrentFavoritesService.instance.clear();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(localizations.favoritesCleared),
                                backgroundColor: Colors.lightGreen,
                              ),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.note_alt_outlined),
                        title: Text(localizations.clearNotes),
                        onTap: () async {
                          await TorrentNotesService.instance.clear();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(localizations.notesCleared),
                                backgroundColor: Colors.lightGreen,
                              ),
                            );
                          }
                        },
                      ),
                      ListTile(
                        onTap: showMaximumActiveDownloadDialog,
                        leading: const Icon(Icons.downloading),
                        title: Text(localizations.maxActiveDownloads),
                        subtitle: Text(downloadQueueSize.toString()),
                      ),
                      ListTile(
                        leading: const Icon(Icons.speed),
                        title: Text(localizations.enableSpeedLimits),
                        subtitle: Text(
                          localizations.speedLimitsDescription,
                          style: isSpeedLimitEnabled
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                        ),
                        trailing: Switch(
                          value: isSpeedLimitEnabled,
                          onChanged: (bool _) {
                            _handleEnableSpeedLimits(!isSpeedLimitEnabled);
                          },
                        ),
                      ),
                      ListTile(
                        enabled: isSpeedLimitEnabled,
                        onTap: showSpeedLimitDownDialog,
                        leading: const Icon(Icons.arrow_circle_down),
                        title: Text(localizations.downloadSpeedLimit),
                        subtitle: Text(
                          '${sessionModel.session?.speedLimitDown} ${localizations.kilobytesPerSecond}',
                        ),
                      ),
                      ListTile(
                        enabled: isSpeedLimitEnabled,
                        onTap: showSpeedLimitUpDialog,
                        leading: const Icon(Icons.arrow_circle_up),
                        title: Text(localizations.uploadSpeedLimit),
                        subtitle: Text(
                          '${sessionModel.session?.speedLimitUp} ${localizations.kilobytesPerSecond}',
                        ),
                      ),
                      Consumer<TorrentsModel>(
                        builder: (context, torrentsModel, _) => SwitchListTile(
                          secondary: const Icon(Icons.stop_circle_outlined),
                          title: Text(localizations.stopSeedingWhenComplete),
                          subtitle: Text(
                            localizations.stopSeedingWhenCompleteDescription,
                          ),
                          value: torrentsModel.stopSeedingWhenComplete,
                          onChanged: (v) =>
                              torrentsModel.setStopSeedingWhenComplete(v),
                        ),
                      ),
                    ],
                  ),
                  _SettingsSection(
                    icon: Icons.shield_outlined,
                    title: 'Network & Privacy',
                    children: [
                      ListTile(
                        onTap: showEncryptionDialog,
                        leading: const Icon(Icons.lock_outline),
                        title: Text(localizations.encryption),
                        subtitle: Text(
                          _encryptionLabel(localizations, encryptionMode),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.block),
                        title: Text(localizations.blocklist),
                        subtitle: Text(
                          blocklistEnabled && blocklistSize > 0
                              ? localizations.blocklistRulesCount(blocklistSize)
                              : localizations.blocklistDescription,
                        ),
                        value: blocklistEnabled,
                        onChanged: _handleBlocklistToggle,
                      ),
                      ListTile(
                        enabled: blocklistEnabled,
                        onTap: showBlocklistUrlDialog,
                        leading: const Icon(Icons.link),
                        title: Text(localizations.blocklistUrl),
                        subtitle: Text(
                          blocklistUrl.isEmpty
                              ? localizations.blocklistUrlNotSet
                              : blocklistUrl,
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.hub_outlined),
                        title: Text(localizations.dht),
                        subtitle: Text(localizations.dhtDescription),
                        value: dhtEnabled,
                        onChanged: _handleDhtToggle,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.people_outline),
                        title: Text(localizations.pex),
                        subtitle: Text(localizations.pexDescription),
                        value: pexEnabled,
                        onChanged: _handlePexToggle,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.lan_outlined),
                        title: Text(localizations.lpd),
                        subtitle: Text(localizations.lpdDescription),
                        value: lpdEnabled,
                        onChanged: _handleLpdToggle,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.bolt_outlined),
                        title: Text(localizations.utp),
                        subtitle: Text(localizations.utpDescription),
                        value: utpEnabled,
                        onChanged: _handleUtpToggle,
                      ),
                    ],
                  ),
                  _SettingsSection(
                    icon: Icons.speed,
                    title: 'Turtle & Seeding',
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 8.0,
                        ),
                        child: BandwidthHeatmapWidget(),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.hourglass_bottom),
                        title: Text(localizations.turtleMode),
                        subtitle: Text(localizations.turtleModeDescription),
                        value: turtleEnabled,
                        onChanged: _handleTurtleToggle,
                      ),
                      ListTile(
                        onTap: showAltSpeedDownDialog,
                        leading: const Icon(Icons.arrow_circle_down_outlined),
                        title: Text(localizations.turtleDownloadLimit),
                        subtitle: Text(
                          '$turtleDown ${localizations.kilobytesPerSecond}',
                        ),
                      ),
                      ListTile(
                        onTap: showAltSpeedUpDialog,
                        leading: const Icon(Icons.arrow_circle_up_outlined),
                        title: Text(localizations.turtleUploadLimit),
                        subtitle: Text(
                          '$turtleUp ${localizations.kilobytesPerSecond}',
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.schedule),
                        title: Text(localizations.turtleSchedule),
                        subtitle: Text(localizations.turtleScheduleDescription),
                        value: turtleScheduleEnabled,
                        onChanged: _handleTurtleScheduleToggle,
                      ),
                      ListTile(
                        enabled: turtleScheduleEnabled,
                        onTap: showTurtleScheduleDialog,
                        leading: const Icon(Icons.access_time),
                        title: Text(localizations.scheduledHours),
                        subtitle: Text(_formatSchedule(turtleBegin, turtleEnd)),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.data_usage),
                        title: Text(localizations.seedRatioLimitEnable),
                        subtitle: Text(localizations.seedRatioLimitDescription),
                        value: seedRatioLimited,
                        onChanged: _handleSeedRatioToggle,
                      ),
                      ListTile(
                        enabled: seedRatioLimited,
                        onTap: showSeedRatioDialog,
                        leading: const Icon(Icons.percent),
                        title: Text(localizations.seedRatioLimit),
                        subtitle: Text(
                          seedRatioLimit > 0
                              ? seedRatioLimit.toStringAsFixed(2)
                              : localizations.notSet,
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.timer_off_outlined),
                        title: Text(localizations.idleSeedingLimitEnable),
                        subtitle: Text(
                          localizations.idleSeedingLimitDescription,
                        ),
                        value: idleSeedingEnabled,
                        onChanged: _handleIdleSeedingToggle,
                      ),
                      ListTile(
                        enabled: idleSeedingEnabled,
                        onTap: showIdleSeedingDialog,
                        leading: const Icon(Icons.hourglass_disabled),
                        title: Text(localizations.idleSeedingLimit),
                        subtitle: Text(
                          idleSeedingLimit > 0
                              ? localizations.minutesValue(idleSeedingLimit)
                              : localizations.notSet,
                        ),
                      ),
                    ],
                  ),
                  _SettingsSection(
                    icon: Icons.settings,
                    title: 'Advanced / Labs',
                    description: localizations.showAdvancedSettings,
                    trailing: Switch(
                      value: showAdvancedSettings,
                      onChanged: (v) {
                        setState(() {
                          showAdvancedSettings = v;
                        });
                      },
                    ),
                    children: advancedTiles,
                  ),
                  _SettingsSection(
                    icon: Icons.info_outline,
                    title: 'About',
                    children: [
                      if (canCheckForUpdate)
                        ListTile(
                          leading: const Icon(Icons.update),
                          title: Text(localizations.checkForUpdates),
                          trailing: Switch(
                            value: app.checkForUpdate,
                            onChanged: _handleCheckForUpdateToggle,
                          ),
                          subtitle: Text(
                            localizations.checkForUpdatesDescription,
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.bolt),
                        title: Text(localizations.version),
                        subtitle: Text(
                          app.buildNumber.isNotEmpty
                              ? '${app.version} (${app.buildNumber})'
                              : app.version,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: localizations.copy,
                          onPressed: () async {
                            final versionText = app.buildNumber.isNotEmpty
                                ? '${app.version} (${app.buildNumber})'
                                : app.version;
                            await Clipboard.setData(
                              ClipboardData(text: versionText),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(localizations.versionCopied),
                                  backgroundColor: Colors.lightGreen,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.library_books),
                        title: Text(localizations.licenses),
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'Gravity Torrent',
                          applicationVersion: app.version,
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable:
                            AdServiceProvider.instance.adFreeNotifier,
                        builder: (context, isAdFree, _) {
                          if (isAdFree) return const SizedBox.shrink();
                          return ListTile(
                            leading: const Icon(
                              Icons.workspace_premium_outlined,
                            ),
                            title: Text(localizations.removeAds),
                            subtitle: Text(localizations.premiumSubtitle),
                            onTap: () => context.push('/upgrade'),
                          );
                        },
                      ),
                      const RateAppTile(),
                      ListTile(
                        leading: const Icon(Icons.bug_report),
                        title: Text(localizations.reportBug),
                        onTap: () async {
                          final result = await launchUrl(
                            Uri.parse(
                              'https://github.com/teamantigravity/gravity-torrent/issues/new/choose',
                            ),
                            mode: LaunchMode.externalApplication,
                          );
                          if (!context.mounted) return;
                          if (!result) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(localizations.bugReportOpenError),
                                backgroundColor: Colors.orange,
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const AdBannerSlot(),
          ],
        );
      },
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    this.description,
    this.trailing,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final desc = description;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(icon, color: colorScheme.primary),
              title: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: desc == null ? null : Text(desc),
              trailing: trailing,
            ),
            const Divider(height: 1),
            ...children,
          ],
        ),
      ),
    );
  }
}
