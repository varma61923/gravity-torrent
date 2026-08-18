import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:async/async.dart';
import 'package:audio_service/audio_service.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/services/ads/ad_service_provider.dart';
import 'package:gravity_torrent/services/audio_handler.dart';
import 'package:gravity_torrent/services/casting_service.dart';
import 'package:gravity_torrent/services/haptic_service.dart';
import 'package:gravity_torrent/services/pip_service.dart';
import 'package:gravity_torrent/services/player_enhancements_service.dart';
import 'package:gravity_torrent/widgets/player/ab_repeat_controls.dart';
import 'package:gravity_torrent/widgets/player/cast_control_sheet.dart';
import 'package:gravity_torrent/widgets/player/sleep_timer_button.dart';
import 'package:gravity_torrent/widgets/player/speed_selector.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/utils/device.dart' as device;
import 'package:gravity_torrent/models/feature_flags.dart';
import 'package:gravity_torrent/utils/media_queue.dart';
import 'package:gravity_torrent/utils/moov_priority_booster.dart';
import 'package:gravity_torrent/utils/streaming_server.dart';
import 'package:gravity_torrent/utils/subtitles.dart';
import 'package:gravity_torrent/utils/subtitles_server.dart';
import 'package:gravity_torrent/utils/torrent_utils.dart';
import 'package:gravity_torrent/widgets/player/playlist_queue_sheet.dart';
import 'package:gravity_torrent/widgets/torrent_player/dialogs/audio_track_selector.dart';
import 'package:gravity_torrent/widgets/torrent_player/dialogs/subtitles_selector.dart';
import 'package:gravity_torrent/widgets/window_title_bar.dart';
import 'package:path/path.dart' as p;

const bufferSize = 2 * 1024 * 1024;

class TorrentPlayer extends StatefulWidget {
  final torrent_file.File file;
  final String filePath;
  final Torrent torrent;

  const TorrentPlayer({
    super.key,
    required this.filePath,
    required this.torrent,
    required this.file,
  });

  @override
  State<TorrentPlayer> createState() => TorrentPlayerState();
}

class StreamingPlayer extends Player {
  StreamingServer server;

  StreamingPlayer({required super.configuration, required this.server});

  /// Pauses local playback directly, bypassing the cast redirect below. Used
  /// internally (e.g. right after a cast session starts, or when following a
  /// queue advance to a new file) so the same title never plays twice at
  /// once, on the TV and locally.
  Future<void> pauseLocalOnly() => super.pause();

  // The stock media_kit controls (and this screen's own transport buttons)
  // call play()/pause()/playOrPause()/seek() directly on this Player. While
  // a cast session is active those must control the renderer instead of the
  // local (already paused) player, or the user ends up with double playback
  // and the local seek bar drifting out of sync with the TV.
  @override
  Future<void> play() {
    if (CastingService.instance.isCasting) {
      return CastingService.instance.resume().then((_) {});
    }
    return super.play();
  }

  @override
  Future<void> pause() {
    if (CastingService.instance.isCasting) {
      return CastingService.instance.pause().then((_) {});
    }
    return super.pause();
  }

  @override
  Future<void> playOrPause() {
    final casting = CastingService.instance;
    if (casting.isCasting) {
      return (casting.isPaused ? casting.resume() : casting.pause())
          .then((_) {});
    }
    return super.playOrPause();
  }

  @override
  Future<void> seek(Duration duration) {
    if (CastingService.instance.isCasting) {
      return CastingService.instance.seek(duration).then((_) {});
    }
    // Cancel previous request, which might block next seek command
    server.cancelRequest();
    return super.seek(duration);
  }
}

class TorrentPlayerState extends State<TorrentPlayer> {
  StreamingPlayer? player;
  StreamingServer? server;
  SubtitlesServer? subsServer;
  VideoController? controller;
  BuildContext? _videoLoadingDialogContext;
  BuildContext? _subsLoadingDialogContext;
  bool _disposed = false;
  final GlobalKey _videoComponentKey = GlobalKey();
  PlayerEnhancementsService? _enhancements;
  CancelableCompleter<void>? _loadingCompleter;
  StreamSubscription<dynamic>? _logSub;

  /// File currently being streamed. Diverges from `widget.file` once the user
  /// (or auto-advance) moves through the playlist queue.
  late torrent_file.File _currentFile;
  late String _currentFilePath;

  /// Whether the stream server may bind to the LAN. Required for casting.
  bool _lanStreamingEnabled = false;

  /// Latest stream URL handed to the player, reused when casting.
  String? _streamUrl;

  /// Guard to prevent re-entrant calls to `_openQueueItem`.
  bool _isOpeningQueueItem = false;

  /// Tracks the previous `CastingService.isCasting` value so
  /// [_onCastingChanged] can detect when a session ends (stopped from the
  /// cast sheet, failed to follow a queue advance, or ended for any other
  /// reason) and resume local playback instead of leaving the user staring
  /// at a frozen, paused frame.
  bool _wasCasting = false;

  void _onCastingChanged() {
    final isCasting = CastingService.instance.isCasting;
    if (_wasCasting && !isCasting && !_disposed) {
      unawaited(player?.play());
    }
    _wasCasting = isCasting;
  }

  void _closeVideoLoadingDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_videoLoadingDialogContext != null &&
          _videoLoadingDialogContext!.mounted) {
        final ctx = _videoLoadingDialogContext!;
        _videoLoadingDialogContext = null;
        if (Navigator.canPop(ctx)) {
          Navigator.of(ctx).pop();
        }
      }
    });
  }

  void _closeSubtitlesLoadingDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_subsLoadingDialogContext != null &&
          _subsLoadingDialogContext!.mounted) {
        final ctx = _subsLoadingDialogContext!;
        _subsLoadingDialogContext = null;
        if (Navigator.canPop(ctx)) {
          Navigator.of(ctx).pop();
        }
      }
    });
  }

  @override
  void initState() {
    // Enter immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    super.initState();
    _currentFile = widget.file;
    _currentFilePath = widget.filePath;
    CastingService.instance.addListener(_onCastingChanged);
    initPlayer();
  }

  @override
  void dispose() {
    _disposed = true;
    CastingService.instance.removeListener(_onCastingChanged);
    _loadingCompleter?.operation.cancel();
    unawaited(_disposePlayer());
    super.dispose();
  }

  Future<void> _disposePlayer() async {
    try {
      if (CastingService.instance.isCasting) {
        await CastingService.instance.stopCasting();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error stopping cast: $e');
    }

    try {
      await widget.torrent.stopStreaming();
    } catch (_) {}
    try {
      await player?.stop();
    } catch (_) {}
    try {
      await MediaKitAudioHandler.instance?.setPlayer(null);
    } catch (_) {}
    try {
      await server?.stop();
    } catch (_) {}
    try {
      await subsServer?.stop();
    } catch (_) {}
    try {
      _enhancements?.detachPlayer();
    } catch (_) {}
    try {
      await _logSub?.cancel();
    } catch (_) {}

    try {
      await player?.dispose();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (e) {
      if (kDebugMode) debugPrint('Error disposing player: $e');
    }
  }

  Future<void> initPlayer() async {
    _enhancements = context.read<PlayerEnhancementsService>();
    _lanStreamingEnabled = context.read<FeatureFlagsModel>().enableLanStreaming;

    // Boost Moov atom and header pieces for rapid playback startup
    try {
      await MoovPriorityBooster.boostForStreaming(
        torrent: widget.torrent,
        file: widget.file,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('boostForStreaming error: $e');
    }

    // Streaming server
    server = StreamingServer(
      filePath: widget.filePath,
      bufferSize: bufferSize,
      torrent: widget.torrent,
      torrentFile: widget.file,
      allowNetworkAccess: _lanStreamingEnabled,
    );

    player = StreamingPlayer(
      configuration: const PlayerConfiguration(bufferSize: bufferSize),
      server: server!,
    );

    controller = VideoController(
      player!,
      configuration: const VideoControllerConfiguration(),
    );

    if (player!.platform is NativePlayer) {
      final nativePlayer = player!.platform as NativePlayer;
      await nativePlayer.setProperty('network-timeout', '0');
      await nativePlayer.setProperty('cache', 'no');
    }
    if (_disposed) return;

    _logSub = player!.stream.log.listen((log) {
      if (kDebugMode) debugPrint('mpv: $log');
    });

    await widget.torrent.startStreaming(widget.file);

    // Preload video file (wait for first piece)
    if (widget.torrent.progress != 1) {
      final completer = CancelableCompleter<void>();
      _loadingCompleter = completer;
      if (!mounted) return;
      onVideoLoading(completer);

      try {
        await waitForPieces(
          torrent: widget.torrent,
          file: widget.file,
          pieceCount: 1,
          cancelableCompleter: completer,
        );
      } catch (e) {
        _closeVideoLoadingDialog();
        if (!mounted) return;
        if (e is CancellationException) {
          return; // Exit silently
        }
        if (kDebugMode) debugPrint('waitForPieces failed: $e');
        // Do not return here; allow the player to attempt opening.
      }

      if (!mounted) return;
      if (!completer.isCanceled) completer.complete();
      _closeVideoLoadingDialog();

      if (!mounted) return;
    }

    if (_disposed) return;
    // Start streaming server after video file is ready. `start()` only returns
    // when the server socket closes, so it must not be awaited here.
    unawaited(
      server!.start().catchError((Object e) {
        if (kDebugMode) debugPrint('streaming server stopped: $e');
      }),
    );
    final serverAdress = await server!.getAddress();
    _streamUrl = serverAdress;
    if (_disposed) return;

    if (kDebugMode) debugPrint('download subs');
    // Download subtitles
    if (widget.torrent.progress != 1) {
      final completer = CancelableCompleter<void>();
      _loadingCompleter = completer;
      if (!mounted) return;
      onSubtitlesLoading(completer);

      try {
        await downloadSubtitles(
          widget.file,
          widget.torrent,
          cancelableCompleter: completer,
        );
      } catch (e) {
        _closeSubtitlesLoadingDialog();
        if (!mounted) return;
        if (e is CancellationException) {
          return; // Exit silently
        }
        if (kDebugMode) debugPrint('downloadSubtitles failed: $e');
        // Do not return here; gracefully degrade and continue.
      }

      if (!mounted) return;
      if (!completer.isCanceled) completer.complete();
      _closeSubtitlesLoadingDialog();

      if (!mounted) return;
    }

    // Initialize subtitles server
    final subsServer = SubtitlesServer(torrent: widget.torrent);
    this.subsServer = subsServer;
    // Like the streaming server, `start()` runs the accept loop and only
    // returns once the socket closes, so it must not be awaited.
    unawaited(
      subsServer.start().catchError((Object e) {
        if (kDebugMode) debugPrint('subtitles server stopped: $e');
      }),
    );
    final subtitlesServerAdress = await subsServer.getAddress();
    if (_disposed) return;

    if (kDebugMode) debugPrint('open player');
    try {
      await player!.open(Media(serverAdress));
    } catch (e) {
      if (kDebugMode) debugPrint('player.open error: $e');
    }
    if (_disposed) return;

    _enhancements?.attachPlayer(player!);
    _setupQueue();
    _enhancements?.openHandler = _openQueueItem;
    await _enhancements?.restoreResumePosition(_currentFilePath);
    if (_disposed) return;

    final externalSubtitlesFiles = getExternalSubtitles(
      widget.file,
      widget.torrent,
    );

    final externalSubtitles = externalSubtitlesFiles
        .map(
          (f) => ExternalSubtitle(
            name: truncateFromLastSlash(f.name),
            url: Uri.encodeFull('$subtitlesServerAdress/${f.name}'),
            language: detectSubtitleLanguage(f.name),
          ),
        )
        .toList();

    // Load external subtitles to be able to select them
    for (final sub in externalSubtitles) {
      if (_disposed) return;
      await player!.setSubtitleTrack(
        SubtitleTrack.uri(sub.url, title: sub.name, language: sub.language),
      );
    }
    if (_disposed) return;

    await player!.setSubtitleTrack(SubtitleTrack.no());
    if (_disposed) return;

    await player!.play();
    if (_disposed) return;

    // Register with the platform media session for background controls
    final audioHandler = MediaKitAudioHandler.instance;
    if (audioHandler != null) {
      await audioHandler.setPlayer(
        player!,
        item: MediaItem(
          id: widget.filePath,
          title: widget.file.name,
          album: widget.torrent.name,
          duration: player!.state.duration,
        ),
      );
    }
  }

  void onVideoLoading(CancelableCompleter<void> completer) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        _videoLoadingDialogContext = dialogContext;
        return AlertDialog(
          title: const Text('Loading Video...'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [Center(child: CircularProgressIndicator())],
          ),
          actions: [
            TextButton(
              onPressed: () {
                completer.operation.cancel();
                _closeVideoLoadingDialog();
                if (mounted && Navigator.canPop(context)) {
                  Navigator.pop(context); // Exit player screen
                }
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ).then((_) {
      if (!completer.isCanceled && !completer.isCompleted) {
        completer.operation.cancel();
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      }
    });
  }

  void onSubtitlesLoading(CancelableCompleter<void> completer) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        _subsLoadingDialogContext = dialogContext;
        return AlertDialog(
          title: const Text('Loading Subtitles...'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [Center(child: CircularProgressIndicator())],
          ),
          actions: [
            TextButton(
              onPressed: () {
                completer.operation.cancel();
                _closeSubtitlesLoadingDialog();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ).then((_) {
      if (!completer.isCanceled && !completer.isCompleted) {
        completer.operation.cancel();
      }
    });
  }

  onSubtitlesClick() {
    if (player == null) return;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return SubtitlesSelectorDialog(
          subtitles: player!.state.tracks.subtitle,
          currentValue: player!.state.track.subtitle.id,
          onSubtitleSelected: (SubtitleTrack sub) async {
            await player!.setSubtitleTrack(sub);
          },
        );
      },
    );
  }

  onAudioTrackClick() {
    if (player == null) return;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AudioTrackSelectorDialog(
          tracks: player!.state.tracks.audio,
          currentValue: player!.state.track.audio.id,
          onTrackSelected: (AudioTrack track) async {
            await player!.setAudioTrack(track);
          },
        );
      },
    );
  }

  /// Builds the playback queue from the torrent's playable files.
  ///
  /// Files are ordered naturally (so `E2` precedes `E10`) and samples are
  /// skipped, which makes "play next episode" behave the way a viewer expects.
  /// The queue starts positioned on the file the user actually opened.
  void _setupQueue() {
    final enhancements = _enhancements;
    if (enhancements == null) return;

    final ordered = orderedPlayableFiles(widget.torrent.files);
    if (ordered.isEmpty) return;

    final items = ordered
        .map(
          (f) => PlaylistItem(
            title: truncateFromLastSlash(f.name),
            filePath: p.join(widget.torrent.location, f.name),
            torrentId: widget.torrent.id,
            fileName: f.name,
          ),
        )
        .toList();

    var startIndex = ordered.indexWhere((f) => f.name == widget.file.name);
    // The opened file may itself be a sample, which `orderedPlayableFiles`
    // filters out. Prepend it so the queue always contains what is playing.
    if (startIndex < 0) {
      items.insert(
        0,
        PlaylistItem(
          title: truncateFromLastSlash(widget.file.name),
          filePath: widget.filePath,
          torrentId: widget.torrent.id,
          fileName: widget.file.name,
        ),
      );
      startIndex = 0;
    }

    enhancements.setQueue(items, startIndex: startIndex);
  }

  /// Rebuilds the streaming pipeline for [item] and opens it in the player.
  ///
  /// Returns `false` when the item cannot be resolved or the widget has been
  /// disposed, which tells [PlayerEnhancementsService] to leave its state alone.
  Future<bool> _openQueueItem(PlaylistItem item) async {
    if (_disposed) return false;
    if (_isOpeningQueueItem) return false;

    _isOpeningQueueItem = true;
    try {
      final fileName = item.fileName;
      final activePlayer = player;
      if (fileName == null || activePlayer == null) return false;

      final target = widget.torrent.files.firstWhere(
        (f) => f.name == fileName,
        orElse: () => _currentFile,
      );
      if (target.name == _currentFile.name && _streamUrl != null) return true;

      // Tear the previous stream down before starting the next one so the two
      // do not compete for sequential-download priority.
      await server?.stop();
      if (!mounted) return false;
      await widget.torrent.stopStreaming();
      if (!mounted) return false;

      _currentFile = target;
      _currentFilePath = p.join(widget.torrent.location, target.name);

      await MoovPriorityBooster.boostForStreaming(
        torrent: widget.torrent,
        file: target,
      );
      if (!mounted) return false;

      await widget.torrent.startStreaming(target);
      if (!mounted) {
        // Widget disposed after startStreaming; clean up so the streaming state
        // doesn't linger until _disposePlayer() has a chance to run.
        unawaited(widget.torrent.stopStreaming().catchError((_) {}));
        return false;
      }

      final nextServer = StreamingServer(
        filePath: _currentFilePath,
        bufferSize: bufferSize,
        torrent: widget.torrent,
        torrentFile: target,
        allowNetworkAccess: _lanStreamingEnabled,
      );
      server = nextServer;
      activePlayer.server = nextServer;

      unawaited(
        nextServer.start().catchError((Object e) {
          if (kDebugMode) debugPrint('streaming server stopped: $e');
        }),
      );
      final address = await nextServer.getAddress();
      if (!mounted) {
        unawaited(nextServer.stop().catchError((_) {}));
        unawaited(widget.torrent.stopStreaming().catchError((_) {}));
        return false;
      }
      _streamUrl = address;

      await activePlayer.open(Media(address));
      if (!mounted) {
        unawaited(nextServer.stop().catchError((_) {}));
        unawaited(widget.torrent.stopStreaming().catchError((_) {}));
        return false;
      }

      // A cast session was pointed at the old (now stopped) stream server,
      // so it must either follow the queue advance to the new URL or be torn
      // down cleanly - otherwise the renderer is left fetching a dead
      // connection while the UI still shows "connected".
      final casting = CastingService.instance;
      if (casting.isCasting) {
        final device = casting.selectedDevice;
        var followed = false;
        if (device != null) {
          try {
            followed = await casting.castStream(
              device: device,
              streamUrl: address,
              title: target.name,
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to follow queue advance while casting: $e');
            }
          }
        }
        if (!mounted) {
          unawaited(nextServer.stop().catchError((_) {}));
          unawaited(widget.torrent.stopStreaming().catchError((_) {}));
          return false;
        }
        if (followed) {
          // Avoid playing the same title twice at once, on the TV and
          // locally.
          await activePlayer.pauseLocalOnly();
        } else {
          unawaited(casting.stopCasting());
        }
      }

      setState(() {});
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to open queue item: $e');
      return false;
    } finally {
      _isOpeningQueueItem = false;
    }
  }

  Widget _buildBackButton() {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.arrow_back, color: Colors.white),
      onPressed: () {
        HapticService.light();
        Navigator.pop(context);
        AdServiceProvider.instance.showInterstitialIfReady();
      },
    );
  }

  Widget _buildLoopButton() {
    return Consumer<PlayerEnhancementsService>(
      builder: (context, svc, _) {
        final IconData icon;
        switch (svc.loopMode) {
          case LoopMode.off:
            icon = Icons.repeat_outlined;
          case LoopMode.one:
            icon = Icons.repeat_one;
          case LoopMode.all:
            icon = Icons.repeat;
        }
        return MaterialDesktopCustomButton(
          icon: Icon(icon),
          onPressed: svc.cycleLoopMode,
        );
      },
    );
  }

  Widget _buildPipButton() {
    if (!device.isDesktop()) return const SizedBox.shrink();
    final pipEnabled = context.select<FeatureFlagsModel, bool>(
      (flags) => flags.usePipBackgroundAudio,
    );
    if (!pipEnabled) return const SizedBox.shrink();

    return MaterialDesktopCustomButton(
      icon: Icon(
        PipService.instance.isFloating
            ? Icons.fullscreen
            : Icons.picture_in_picture_alt,
      ),
      onPressed: () async {
        HapticService.medium();
        if (PipService.instance.isFloating) {
          await PipService.instance.exitCompactFloating(context);
        } else {
          await PipService.instance.enterCompactFloating(context);
        }
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  Widget _buildSubtitlesButton() {
    return MaterialDesktopCustomButton(
      icon: const Icon(Icons.subtitles),
      onPressed: onSubtitlesClick,
    );
  }

  Widget _buildAudioTrackButton() {
    return MaterialDesktopCustomButton(
      icon: const Icon(Icons.multitrack_audio),
      onPressed: onAudioTrackClick,
    );
  }

  Widget _buildPlaybackSpeedButton() {
    return const SpeedSelector();
  }

  Widget _buildSleepTimerButton() {
    return const SleepTimerButton();
  }

  Widget _buildQueueButton() {
    return Consumer<PlayerEnhancementsService>(
      builder: (context, svc, _) {
        // A single-item queue offers nothing to navigate, so the button is
        // hidden rather than shown as a dead control.
        if (svc.queue.length < 2) return const SizedBox.shrink();
        return MaterialDesktopCustomButton(
          icon: const Icon(Icons.playlist_play),
          onPressed: () {
            HapticService.light();
            unawaited(
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const PlaylistQueueSheet(),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _onCastPressed() async {
    HapticService.medium();
    final localizations = AppLocalizations.of(context);
    final scaffold = ScaffoldMessenger.of(context);
    final casting = CastingService.instance;

    if (casting.isCasting) {
      // Surface the transport controls rather than silently disconnecting.
      await showModalBottomSheet<void>(
        context: context,
        builder: (_) => const CastControlSheet(),
      );
      return;
    }

    // Without LAN streaming the stream server is bound to loopback, so a TV
    // could never fetch it. Tell the user instead of failing silently.
    if (!_lanStreamingEnabled) {
      scaffold.showSnackBar(
        SnackBar(content: Text(localizations.castLanStreamingRequired)),
      );
      return;
    }

    scaffold.showSnackBar(
      SnackBar(content: Text(localizations.castScanningMessage)),
    );

    List<CastDevice> devices = [];
    try {
      devices = await casting.discoverDevices();
    } catch (e) {
      if (!mounted) return;
      scaffold.showSnackBar(
        SnackBar(content: Text('Error discovering devices: $e')),
      );
      return;
    }
    if (!mounted) return;
    if (devices.isEmpty) {
      scaffold.showSnackBar(
        SnackBar(content: Text(localizations.castNoDevicesFound)),
      );
      return;
    }

    final streamUrl = _streamUrl ?? '';
    if (!mounted) return;

    final selected = await showDialog<CastDevice>(
      context: context,
      builder: (dialogCtx) => SimpleDialog(
        title: Text(localizations.castToDevice),
        children: devices
            .map(
              (d) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogCtx, d),
                child: Text(d.name),
              ),
            )
            .toList(),
      ),
    );
    if (selected == null || !mounted) return;

    bool success = false;
    try {
      success = await casting.castStream(
        device: selected,
        streamUrl: streamUrl,
        title: _currentFile.name,
      );
    } catch (e) {
      if (!mounted) return;
      scaffold.showSnackBar(
        SnackBar(content: Text('Error casting stream: $e')),
      );
      return;
    }

    // Avoid playing the same title twice at once, on the TV and locally.
    if (success) {
      if (!mounted) return;
      await player?.pauseLocalOnly();
    }
    if (!mounted) return;

    scaffold.showSnackBar(
      SnackBar(
        content: Text(
          success
              ? localizations.castStartedOn(selected.name)
              : localizations.castFailed(
                  casting.lastError ?? localizations.castNoDevicesFound,
                ),
        ),
      ),
    );
  }

  Widget _buildCastButton() {
    // Listens to the service so the icon reflects the real session state
    // instead of whatever the last setState happened to capture.
    return ListenableBuilder(
      listenable: CastingService.instance,
      builder: (context, _) {
        final casting = CastingService.instance;
        return MaterialDesktopCustomButton(
          icon: Icon(
            casting.isCasting ? Icons.cast_connected : Icons.cast,
            color: casting.isCasting ? Colors.blue : null,
          ),
          onPressed: () {
            // The control does not accept a null callback, so re-entrant taps
            // during a scan are dropped here instead.
            if (casting.isDiscovering) return;
            unawaited(_onCastPressed());
          },
        );
      },
    );
  }

  List<Widget> _buildMobileBottomButtonBar() {
    return [
      const MaterialPositionIndicator(),
      const Spacer(),
      _buildQueueButton(),
      _buildCastButton(),
      _buildSleepTimerButton(),
      _buildPlaybackSpeedButton(),
      _buildSubtitlesButton(),
      _buildAudioTrackButton(),
      _buildPipButton(),
    ];
  }

  List<Widget> _buildDesktopBottomButtonBar() {
    return [
      const MaterialDesktopSkipPreviousButton(),
      const MaterialDesktopPlayOrPauseButton(),
      const MaterialDesktopSkipNextButton(),
      const MaterialDesktopVolumeButton(),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      _buildQueueButton(),
      // Desktop can cast too — the omission previously made the documented
      // feature unreachable outside mobile.
      _buildCastButton(),
      _buildSleepTimerButton(),
      _buildPlaybackSpeedButton(),
      _buildSubtitlesButton(),
      _buildAudioTrackButton(),
      _buildPipButton(),
      const MaterialDesktopFullscreenButton(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final videoController = controller;
    final body = videoController == null
        ? const Center(child: CircularProgressIndicator())
        : Stack(
            children: [
              device.isMobile()
                  ? MaterialVideoControlsTheme(
                      normal: MaterialVideoControlsThemeData(
                        seekBarThumbColor: const Color(0xFF4285F4),
                        seekBarPositionColor: const Color(0xFF4285F4),
                        padding: const EdgeInsets.only(bottom: 64),
                        topButtonBar: [
                          _buildBackButton(),
                          const Spacer(),
                          const ABRepeatControls(),
                          _buildLoopButton(),
                        ],
                        bottomButtonBar: _buildMobileBottomButtonBar(),
                      ),
                      fullscreen: MaterialVideoControlsThemeData(
                        seekBarThumbColor: const Color(0xFF4285F4),
                        seekBarPositionColor: const Color(0xFF4285F4),
                        padding: const EdgeInsets.only(bottom: 64),
                        topButtonBar: [
                          _buildBackButton(),
                          const Spacer(),
                          const ABRepeatControls(),
                          _buildLoopButton(),
                        ],
                        bottomButtonBar: _buildMobileBottomButtonBar(),
                      ),
                      child: Video(
                        key: _videoComponentKey,
                        controller: videoController,
                        controls: MaterialVideoControls,
                      ),
                    )
                  : MaterialDesktopVideoControlsTheme(
                      normal: MaterialDesktopVideoControlsThemeData(
                        seekBarThumbColor: const Color(0xFF4285F4),
                        seekBarPositionColor: const Color(0xFF4285F4),
                        topButtonBar: [
                          _buildBackButton(),
                          const Spacer(),
                          const ABRepeatControls(),
                          _buildLoopButton(),
                        ],
                        bottomButtonBar: _buildDesktopBottomButtonBar(),
                      ),
                      fullscreen: MaterialDesktopVideoControlsThemeData(
                        seekBarThumbColor: const Color(0xFF4285F4),
                        seekBarPositionColor: const Color(0xFF4285F4),
                        topButtonBar: [
                          _buildBackButton(),
                          const Spacer(),
                          const ABRepeatControls(),
                          _buildLoopButton(),
                        ],
                        bottomButtonBar: _buildDesktopBottomButtonBar(),
                      ),
                      child: Video(
                        key: _videoComponentKey,
                        controller: videoController,
                        controls: MaterialDesktopVideoControls,
                      ),
                    ),
            ],
          );

    return Theme(
      data: ThemeData.dark(),
      child: SafeArea(
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: device.isDesktop()
              ? const WindowTitleBar(backgroundColor: Colors.black)
              : AppBar(toolbarHeight: 0),
          body: body,
        ),
      ),
    );
  }
}
