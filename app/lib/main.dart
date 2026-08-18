import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gravity_torrent/engine/engine.dart';
import 'package:gravity_torrent/engine/transmission/transmission.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/models/app.dart';
import 'package:gravity_torrent/models/session.dart';
import 'package:gravity_torrent/models/torrents.dart';
import 'package:gravity_torrent/navigation/router.dart';
import 'package:gravity_torrent/platforms/android/foreground_service.dart';
import 'package:gravity_torrent/platforms/windows/register_app.dart';
import 'package:gravity_torrent/services/ads/ad_service_provider.dart';
import 'package:gravity_torrent/services/audio_handler.dart';
import 'package:gravity_torrent/services/purchase/purchase_service_provider.dart';
import 'package:gravity_torrent/utils/device.dart';
import 'package:gravity_torrent/services/service_locator.dart';
import 'package:gravity_torrent/utils/migrations.dart';
import 'package:gravity_torrent/utils/notifications.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yaru/yaru.dart';
import 'package:media_kit/media_kit.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:gravity_torrent/models/feature_flags.dart';
import 'package:gravity_torrent/screens/lock/lock_screen.dart';
import 'package:gravity_torrent/services/app_lock_service.dart';
import 'package:gravity_torrent/services/haptic_service.dart';
import 'package:gravity_torrent/services/quota_service.dart';
import 'package:gravity_torrent/services/remote_control_service.dart';
import 'package:gravity_torrent/services/rss_service.dart';
import 'package:gravity_torrent/services/scheduler_service.dart';
import 'package:gravity_torrent/services/theme_scheduler_service.dart';
import 'package:gravity_torrent/services/accessibility_service.dart';
import 'package:gravity_torrent/services/wifi_guard_service.dart';
import 'package:gravity_torrent/services/battery_service.dart';
import 'package:gravity_torrent/services/casting_service.dart';
import 'package:gravity_torrent/services/seed_ratio_service.dart';
import 'package:gravity_torrent/services/torrent_notes_service.dart';
import 'package:gravity_torrent/services/torrent_favorites_service.dart';
import 'package:gravity_torrent/services/recent_download_directories_service.dart';
import 'package:gravity_torrent/services/recent_search_queries_service.dart';
import 'package:gravity_torrent/services/analytics_service.dart';
import 'package:gravity_torrent/services/blocklist_service.dart';
import 'package:gravity_torrent/storage/shared_preferences.dart';
import 'package:gravity_torrent/services/feature_registration.dart';

ColorScheme _buildColorScheme(Brightness brightness, ColorScheme? dynamic) {
  return dynamic ??
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF4285F4),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.rainbow,
      );
}

ThemeData _buildTheme(ColorScheme colorScheme) {
  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    useMaterial3: true,
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surface,
    ),
  );
}

// Initialize torrents engine, we use transmission
Engine engine = TransmissionEngine();

/// Starts the background SOTA services that depend on the loaded feature flags.
/// Should be called after the engine is initialized and migrations have run.
Future<void> startServices(FeatureFlagsModel flags) async {
  HapticService.setEnabled(flags.enableHaptic);

  try {
    await WifiGuardService.instance.load();
    await WifiGuardService.instance.setEnabled(flags.enableWifiOnly);
  } catch (e) {
    if (kDebugMode) debugPrint('WifiGuardService init failed: $e');
  }

  try {
    await SeedRatioService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('SeedRatioService init failed: $e');
  }

  try {
    await TorrentNotesService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('TorrentNotesService init failed: $e');
  }

  try {
    await TorrentFavoritesService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('TorrentFavoritesService init failed: $e');
  }

  try {
    await RecentDownloadDirectoriesService.instance.load();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('RecentDownloadDirectoriesService init failed: $e');
    }
  }

  try {
    await RecentSearchQueriesService.instance.load();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('RecentSearchQueriesService init failed: $e');
    }
  }

  try {
    await BatteryService.instance.load();
    await BatteryService.instance.setEnabled(flags.enableBatterySaver);
  } catch (e) {
    if (kDebugMode) debugPrint('BatteryService init failed: $e');
  }

  try {
    await SchedulerService.instance.load();
    await SchedulerService.instance.setEnabled(flags.enableScheduler);
  } catch (e) {
    if (kDebugMode) debugPrint('SchedulerService init failed: $e');
  }

  try {
    await RssService.instance.load();
    if (flags.enableRssAutoDownload) {
      RssService.instance.startPolling();
    }
  } catch (e) {
    if (kDebugMode) debugPrint('RssService init failed: $e');
  }

  try {
    await QuotaService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('QuotaService init failed: $e');
  }

  try {
    await AppLockService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('AppLockService init failed: $e');
  }

  try {
    await AnalyticsService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('AnalyticsService init failed: $e');
  }

  try {
    await BlocklistService.instance.load();
  } catch (e) {
    if (kDebugMode) debugPrint('BlocklistService init failed: $e');
  }

  try {
    if (flags.enableRemoteControl) {
      await RemoteControlService.instance.start();
    }
  } catch (e) {
    if (kDebugMode) debugPrint('RemoteControlService init failed: $e');
  }
}

/// Stops background services before the engine shuts down.
Future<void> stopServices() async {
  SchedulerService.instance.dispose();
  RssService.instance.stopPolling();
  WifiGuardService.instance.dispose();
  BatteryService.instance.dispose();
  CastingService.instance.dispose();
  await RemoteControlService.instance.stop();
  await PurchaseServiceProvider.dispose();
}

Future<void> _initDesktopWindow() async {
  try {
    await YaruWindowTitleBar.ensureInitialized();
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(minimumSize: Size(360, 360));

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (e, st) {
    debugPrint('Window initialisation failed: $e\n$st');
  }
}

Future<void> _bootstrap() async {
  // Create + init engine BEFORE registering so consumers never
  // see an uninitialised singleton.
  await engine.init();

  // Only register after successful init.
  getIt.registerSingleton<Engine>(engine);

  // Desktop window (non-blocking for mobile).
  if (isDesktop()) {
    await _initDesktopWindow();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    MediaKit.ensureInitialized();
  } catch (e, st) {
    // Missing libmpv or media dependencies should not prevent the app from
    // launching. Media playback will be unavailable, but the torrent UI works.
    if (kDebugMode) {
      debugPrint('MediaKit initialization failed: $e\n$st');
    }
  }

  await SharedPrefs.init();

  try {
    await initializeNotifications();
  } catch (e, st) {
    // Local notifications are optional; a bad notification setup should not
    // white-screen the app on startup.
    if (kDebugMode) {
      debugPrint('Notification initialization failed: $e\n$st');
    }
  }

  unawaited(
    AdServiceProvider.instance.init().catchError((e) {
      if (kDebugMode) debugPrint('AdService init failed: $e');
      return null;
    }),
  );
  try {
    PurchaseServiceProvider.wirePurchaseStream();
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('Purchase stream wiring failed: $e\n$st');
    }
  }

  await _bootstrap();

  // Register port for cross-isolate notification actions
  final receivePort = ReceivePort();
  IsolateNameServer.removePortNameMapping('notification_actions');
  IsolateNameServer.registerPortWithName(
    receivePort.sendPort,
    'notification_actions',
  );
  receivePort.listen((message) async {
    final actionId = message as String;
    if (actionId == 'exit') {
      await stopServices();
      if (getIt.isRegistered<Engine>()) {
        await getIt<Engine>().shutdown();
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        await stopForegroundService();
      }
      exit(0);
    } else {
      if (getIt.isRegistered<Engine>()) {
        await executeNotificationAction(actionId, getIt<Engine>());
      }
    }
  });

  // Initialize the media session for background audio on supported platforms.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    try {
      await AudioService.init<MediaKitAudioHandler>(
        builder: () => MediaKitAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.teamantigravity.gravitytorrent.media',
          androidNotificationChannelName: 'Media playback',
          androidNotificationChannelDescription:
              'Media playback controls and background audio',
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidStopForegroundOnPause: true,
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('AudioService init failed: $e');
    }
  }

  // Run migrations for app updates
  await runMigrations();

  // Load feature flags and remote config before starting any SOTA services so
  // remote kill switches are respected and the correct service state is restored.
  final featureFlags = FeatureFlagsModel();
  await featureFlags.initialization;

  // Load accessibility settings before the first frame so text scaling and
  // high-contrast mode are applied immediately.
  final accessibilityService = AccessibilityService();
  await accessibilityService.load();

  // Initialize notification channels and other feature hooks before starting
  // background services that may post notifications.
  try {
    await initializeFeatures();
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('Feature initialization failed: $e\n$st');
    }
  }

  // Start background SOTA services based on the loaded flags.
  await startServices(featureFlags);

  if (!kIsWeb && Platform.isAndroid) {
    try {
      await createForegroundService();
    } catch (e) {
      // Android does not allow to start a foreground service
      // while app is in background. This can happen in development
      // when live reloading.
      if (kDebugMode) debugPrint(e.toString());
    }
  } else if (!kIsWeb && Platform.isWindows) {
    await registerAppInRegistry();
  }

  runApp(
    GravityTorrent(
      featureFlags: featureFlags,
      accessibilityService: accessibilityService,
    ),
  );
}

class GravityTorrent extends StatelessWidget {
  final FeatureFlagsModel featureFlags;
  final AccessibilityService accessibilityService;

  const GravityTorrent({
    super.key,
    required this.featureFlags,
    required this.accessibilityService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AppModel()),
        ChangeNotifierProvider.value(value: featureFlags),
        ChangeNotifierProvider(
          create: (context) => TorrentsModel(
            featureFlags: Provider.of<FeatureFlagsModel>(
              context,
              listen: false,
            ),
          ),
        ),
        ChangeNotifierProvider(create: (context) => SessionModel()),
        ChangeNotifierProxyProvider<AppModel, ThemeSchedulerService>(
          create: (_) => ThemeSchedulerService(),
          update: (_, app, service) => service!..attachAppModel(app),
        ),
        ChangeNotifierProvider.value(value: accessibilityService),
        ...featureProviders(),
      ],
      child: const GravityTorrentApp(),
    );
  }
}

class GravityTorrentApp extends StatefulWidget {
  const GravityTorrentApp({super.key});

  @override
  State<GravityTorrentApp> createState() => _GravityTorrentAppState();
}

class _GravityTorrentAppState extends State<GravityTorrentApp>
    with WidgetsBindingObserver, WindowListener {
  bool _unlocked = false;
  bool _wasLocked = false;
  bool _hasEvaluatedLockState = false;
  Timer? _lockDebounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktop()) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    _lockDebounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (isDesktop()) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _shutdownServices() async {
    await stopServices();
    await engine.shutdown();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateLockState();
  }

  void _updateLockState() {
    final flags = Provider.of<FeatureFlagsModel>(context, listen: false);
    final isLockEnabled = flags.enableAppLock &&
        AppLockService.instance.enabled &&
        AppLockService.instance.hasPin;

    if (!isLockEnabled) {
      _unlocked = false;
      _wasLocked = false;
    } else {
      if (!_wasLocked && _hasEvaluatedLockState) {
        // Lock just became active during this running session (e.g. user
        // just finished setting up their PIN). Grant the current session
        // access so the user isn't immediately locked out right after
        // enabling the feature. The `_hasEvaluatedLockState` guard excludes
        // the very first evaluation (app cold start), so a lock that was
        // already enabled from a previous session still requires
        // authentication on launch.
        _unlocked = true;
      }
      _wasLocked = true;
    }
    _hasEvaluatedLockState = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _lockDebounceTimer?.cancel();
        if (kDebugMode) debugPrint('Application resumed');
        unawaited(processPendingNotificationAction());
        break;

      case AppLifecycleState.inactive:
        break;

      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_unlocked) {
          _lockDebounceTimer?.cancel();
          _lockDebounceTimer = Timer(const Duration(seconds: 5), () {
            if (mounted) setState(() => _unlocked = false);
          });
        }
        break;

      case AppLifecycleState.detached:
        _lockDebounceTimer?.cancel();
        if (defaultTargetPlatform == TargetPlatform.android &&
            isForegroundServiceStarted) {
          // If the foreground service is active, deliberately keep the app and engine running
          // in the background even if the Flutter activity is detached from the recent apps list.
        } else {
          unawaited(_shutdownServices());
        }
        break;
    }
  }

  @override
  void onWindowClose() {
    if (mounted && _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  // App root
  @override
  Widget build(BuildContext context) {
    return _AppLocaleLayer(
      builder: (context, app, locale) {
        return _FeatureFlagsLayer(
          unlocked: _unlocked,
          builder: (context, flags, shouldLock) {
            return _ColorSchemeLayer(
              app: app,
              flags: flags,
              locale: locale,
              shouldLock: shouldLock,
              onUnlocked: () => setState(() => _unlocked = true),
            );
          },
        );
      },
    );
  }
}

class _AppLocaleLayer extends StatelessWidget {
  final Widget Function(BuildContext context, AppModel app, Locale locale)
      builder;

  const _AppLocaleLayer({required this.builder});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppModel>();
    final locale = AppLocalizations.supportedLocales.firstWhere(
      (l) => l.toString() == app.locale,
      orElse: () => AppLocalizations.supportedLocales.first,
    );

    return builder(context, app, locale);
  }
}

class _FeatureFlagsLayer extends StatelessWidget {
  final bool unlocked;
  final Widget Function(
    BuildContext context,
    FeatureFlagsModel flags,
    bool shouldLock,
  ) builder;

  const _FeatureFlagsLayer({required this.unlocked, required this.builder});

  @override
  Widget build(BuildContext context) {
    final flags = context.watch<FeatureFlagsModel>();
    final isLockEnabled = flags.enableAppLock &&
        AppLockService.instance.enabled &&
        AppLockService.instance.hasPin;
    final shouldLock = isLockEnabled && !unlocked;

    return builder(context, flags, shouldLock);
  }
}

class _ColorSchemeLayer extends StatelessWidget {
  final AppModel app;
  final FeatureFlagsModel flags;
  final Locale locale;
  final bool shouldLock;
  final VoidCallback onUnlocked;

  const _ColorSchemeLayer({
    required this.app,
    required this.flags,
    required this.locale,
    required this.shouldLock,
    required this.onUnlocked,
  });

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final lightColorScheme = _buildColorScheme(
          Brightness.light,
          flags.loaded && flags.useDynamicColor ? lightDynamic : null,
        );
        final darkColorScheme = _buildColorScheme(
          Brightness.dark,
          flags.loaded && flags.useDynamicColor ? darkDynamic : null,
        );

        final baseLightTheme = _buildTheme(lightColorScheme);
        final baseDarkTheme = _buildTheme(darkColorScheme);

        return Consumer2<ThemeSchedulerService, AccessibilityService>(
          builder: (context, themeSvc, a11ySvc, child) {
            final darkTheme = themeSvc.isAmoled
                ? themeSvc.applyAmoled(baseDarkTheme)
                : baseDarkTheme;

            return MaterialApp.router(
              title: 'Gravity Torrent',
              themeMode: themeSvc.materialThemeMode,
              theme: a11ySvc.applyToTheme(baseLightTheme),
              darkTheme: a11ySvc.applyToTheme(darkTheme),
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(a11ySvc.textScaleFactor),
                  disableAnimations: a11ySvc.reducedMotion,
                ),
                child: _LockGate(
                  shouldLock: shouldLock,
                  onUnlocked: onUnlocked,
                  child: child!,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _LockGate extends StatelessWidget {
  final bool shouldLock;
  final VoidCallback onUnlocked;
  final Widget child;

  const _LockGate({
    required this.shouldLock,
    required this.onUnlocked,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (shouldLock) {
      return LockScreen(onUnlocked: onUnlocked);
    }
    return child;
  }
}
