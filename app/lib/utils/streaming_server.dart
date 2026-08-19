import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';

import 'package:mime/mime.dart';
import 'package:flutter/foundation.dart';
import 'package:gravity_torrent/engine/torrent.dart';
import 'package:gravity_torrent/engine/file.dart' as torrent_file;
import 'package:gravity_torrent/utils/secure_token.dart';
import 'package:gravity_torrent/utils/torrent_utils.dart';

/// Server to stream a file
class StreamingServer {
  HttpServer? _server;
  final Completer<void> _serverReadyCompleter = Completer<void>();
  bool _stopped = false;

  String filePath;
  final int bufferSize;
  final Torrent torrent;
  final torrent_file.File torrentFile;
  late File _file;
  int? _fileOffset;

  /// When true the server listens on all IPv4 interfaces so other devices on
  /// the LAN (for example a DLNA renderer) can fetch the stream. Otherwise it
  /// is reachable only from this device.
  final bool allowNetworkAccess;

  /// When true, enables preview mode by prioritizing download of first and last
  /// pieces for quick video preview.
  final bool enablePreview;

  /// Unguessable path prefix acting as a capability token.
  ///
  /// Binding to `0.0.0.0` would otherwise let *any* host on the network read
  /// the torrent's contents, so every request must present this token. It is
  /// generated per server instance and never persisted.
  final String pathToken;

  final Set<CancelableOperation<void>> _activeRequests = {};

  StreamingServer({
    required this.filePath,
    required this.bufferSize,
    required this.torrent,
    required this.torrentFile,
    this.allowNetworkAccess = false,
    this.enablePreview = false,
    String? pathToken,
  }) : pathToken = pathToken ?? generateSecureRandomToken(length: 16);

  /// Returns true when [requestPath] presents the capability token.
  @visibleForTesting
  bool isAuthorizedPath(String requestPath) =>
      pathCarriesToken(requestPath, pathToken);

  Future<void> start() async {
    try {
      int offset = 0;
      for (final f in torrent.files) {
        if (identical(f, torrentFile) || f.name == torrentFile.name) break;
        offset += f.length;
      }
      _fileOffset ??= offset;

      _file = File(filePath);
      final address = allowNetworkAccess
          ? InternetAddress.anyIPv4
          : InternetAddress.loopbackIPv4;
      final server = await HttpServer.bind(address, 0);
      _server = server;
      if (_stopped) {
        // stop() was called before bind completed.
        if (!_serverReadyCompleter.isCompleted) {
          _serverReadyCompleter.completeError(
            StateError('StreamingServer was stopped before it could start'),
          );
        }
        await server.close(force: true);
        return;
      }
      if (!_serverReadyCompleter.isCompleted) {
        _serverReadyCompleter.complete();
      }
      if (kDebugMode) {
        debugPrint(
          'streaming_server: starting streaming server on ${await getAddress()}',
        );
      }

      // Enable preview mode if requested
      if (enablePreview) {
        await _enablePreviewMode();
      }

      await for (final HttpRequest request in server) {
        final completer = CancelableCompleter<void>();
        late CancelableOperation<void> operation;

        // Create new cancelable request
        operation = CancelableOperation.fromFuture(
          _handleRequest(request, completer).whenComplete(() {
            _activeRequests.remove(operation);
          }),
          onCancel: () {
            if (kDebugMode) debugPrint('Request cancelled.');
            completer.operation.cancel();
          },
        );
        _activeRequests.add(operation);
      }
    } catch (e) {
      if (!_serverReadyCompleter.isCompleted) {
        _serverReadyCompleter.completeError(e);
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    if (kDebugMode) debugPrint('streaming_server: stop');
    _stopped = true;
    for (final op in _activeRequests.toList()) {
      await op.cancel();
    }
    await Future.wait(
      _activeRequests.map((op) async {
        try {
          await op.value;
        } catch (_) {}
      }).toList(),
    );
    _activeRequests.clear();
    await _server?.close(force: true);
    _server = null;

    // Disable sequential download when stopping
    try {
      await torrent.setSequentialDownloadFromPiece(-1);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'streaming_server: failed to disable sequential download: $e',
        );
      }
    }
  }

  void cancelRequest() {
    for (final op in _activeRequests.toList()) {
      op.cancel();
    }
    _activeRequests.clear();
  }

  Future<String> getAddress() async {
    await _serverReadyCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
        'StreamingServer: timed out waiting for server to start',
      ),
    );
    final server = _server;
    if (server == null) {
      throw StateError('Streaming server is not running');
    }
    var host = server.address.host;
    if (host == '0.0.0.0' || host == '::') {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: false,
        );
        for (final interface in interfaces) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback) {
              host = addr.address;
              break;
            }
          }
          if (host != '0.0.0.0' && host != '::') break;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('StreamingServer: NetworkInterface.list failed: $e');
        }
      }
    }
    return 'http://$host:${server.port}/$pathToken';
  }

  Future<void> _handleRequest(
    HttpRequest request,
    CancelableCompleter<void> cancelableCompleter,
  ) async {
    try {
      if (!isAuthorizedPath(request.uri.path)) {
        // Deliberately a 404 rather than a 403 so a scanner cannot tell that a
        // stream exists behind an unknown token.
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'GET') {
        await _handleGetRequest(request, cancelableCompleter);
      } else if (request.method == 'HEAD') {
        await _handleHeadRequest(request);
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    } on CancellationException {
      if (kDebugMode) debugPrint('streaming_server: Request cancelled');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('streaming_server: Error processing request: $e');
      }
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('StreamingServer: failed to set error status: $e');
        }
      }
    } finally {
      try {
        await request.response.close();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('StreamingServer: failed to close response: $e');
        }
      }
      cancelableCompleter.complete();
    }
  }

  Future<void> _handleHeadRequest(HttpRequest request) async {
    if (kDebugMode) debugPrint('streaming_server: _handleHeadRequest');
    final fileSize = torrentFile.length;
    request.response.statusCode = HttpStatus.ok;
    final mimeType = lookupMimeType(filePath) ?? ContentType.binary.mimeType;
    try {
      request.response.headers.contentType = ContentType.parse(mimeType);
    } on FormatException {
      request.response.headers.contentType = ContentType.binary;
    }
    request.response.headers.contentLength = fileSize;
    request.response.headers.set('Accept-Ranges', 'bytes');
  }

  Future<void> _handleGetRequest(
    HttpRequest request,
    CancelableCompleter<void> cancelableCompleter,
  ) async {
    // Wait for at least first piece
    if (kDebugMode) debugPrint('streaming_server: _handleGetRequest');
    if (torrent.pieceSize <= 0) {
      request.response.statusCode = HttpStatus.internalServerError;
      return;
    }
    final fileSize = torrentFile.length;
    final rangeHeader = request.headers.value('range');

    if (rangeHeader != null) {
      await _handleRangeRequest(
        request,
        fileSize,
        rangeHeader,
        cancelableCompleter,
      );
    } else {
      await _sendFullFile(request, fileSize, cancelableCompleter);
    }
  }

  Future<void> _sendFullFile(
    HttpRequest request,
    int fileSize,
    CancelableCompleter<void> cancelableCompleter,
  ) async {
    if (kDebugMode) debugPrint('streaming_server: _sendFullFile');
    request.response.statusCode = HttpStatus.ok;
    final mimeType = lookupMimeType(filePath) ?? ContentType.binary.mimeType;
    try {
      request.response.headers.contentType = ContentType.parse(mimeType);
    } on FormatException {
      request.response.headers.contentType = ContentType.binary;
    }
    request.response.headers.contentLength = fileSize;

    await _pipeFileRangeInBlocks(
      _file,
      request.response,
      0,
      fileSize - 1,
      torrent.pieceSize,
      cancelableCompleter,
    );
  }

  Future<void> _handleRangeRequest(
    HttpRequest request,
    int fileSize,
    String rangeHeader,
    CancelableCompleter<void> cancelableCompleter,
  ) async {
    if (kDebugMode) debugPrint('streaming_server: _handleRangeRequest');
    if (torrent.pieceSize <= 0) {
      request.response.statusCode = HttpStatus.internalServerError;
      return;
    }

    // Reject multi-range requests (contain commas) and malformed headers
    if (rangeHeader.contains(',')) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }

    final rangeRegex = RegExp(r'bytes=(\d*)-(\d*)');
    final match = rangeRegex.firstMatch(rangeHeader);

    if (match == null) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }

    final startStr = match.group(1);
    final endStr = match.group(2);

    // Reject bytes=- (both empty)
    if ((startStr == null || startStr.isEmpty) &&
        (endStr == null || endStr.isEmpty)) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }

    int start = 0;
    int end = fileSize - 1;

    try {
      if (startStr != null && startStr.isNotEmpty) {
        start = int.parse(startStr);
      }

      if (endStr != null && endStr.isNotEmpty) {
        if (startStr != null && startStr.isNotEmpty) {
          end = int.parse(endStr);
        } else {
          // Suffix range: bytes=-N
          final suffixLength = int.parse(endStr);
          start = fileSize - suffixLength;
          if (start < 0) start = 0;
          end = fileSize - 1;
        }
      }
    } on FormatException {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }

    if (start < 0 || start >= fileSize) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set('Content-Range', 'bytes */$fileSize');
      return;
    }

    if (end >= fileSize) {
      end = fileSize - 1;
    }

    if (start > end) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set('Content-Range', 'bytes */$fileSize');
      return;
    }

    final contentLength = end - start + 1;

    request.response.statusCode = HttpStatus.partialContent;
    final mimeType = lookupMimeType(filePath) ?? ContentType.binary.mimeType;
    try {
      request.response.headers.contentType = ContentType.parse(mimeType);
    } on FormatException {
      request.response.headers.contentType = ContentType.binary;
    }
    request.response.headers.contentLength = contentLength;
    request.response.headers.set(
      'Content-Range',
      'bytes $start-$end/$fileSize',
    );

    final piece = ((_fileOffset ?? 0) + start) ~/ torrent.pieceSize;

    if (kDebugMode) {
      debugPrint(
        'handleRangeRequest $start ${end + 1} $contentLength piece: $piece ${torrent.pieceSize}',
      );
    }

    await torrent.setSequentialDownloadFromPiece(piece);
    await _pipeFileRangeInBlocks(
      _file,
      request.response,
      start,
      end,
      torrent.pieceSize,
      cancelableCompleter,
    );
  }

  List<int> _computeNeededPieces(int? from, int? count) {
    final List<int> neededPieces = [];
    final pieceSize = torrent.pieceSize;
    final neededPiecesCount =
        count ?? (pieceSize > 0 ? (bufferSize / pieceSize).ceil() : 1);
    final firstPiece = from ?? torrentFile.beginPiece;
    final lastPiece = torrentFile.endPiece;
    for (int i = 0; i < neededPiecesCount && firstPiece + i <= lastPiece; i++) {
      neededPieces.add(firstPiece + i);
    }

    return neededPieces;
  }

  Future<void> _waitForPieces({
    int? from,
    int? count,
    CancelableCompleter<void>? cancelableCompleter,
  }) async {
    final neededPieces = _computeNeededPieces(from, count);
    if (kDebugMode) debugPrint('streaming_server: neededPieces $neededPieces');

    await waitForPiecesList(
      torrent: torrent,
      neededPieces: neededPieces,
      onCancelled: cancelableCompleter != null
          ? () {
              if (cancelableCompleter.isCanceled) {
                if (kDebugMode) debugPrint('streaming_server: cancel throw');
                return true;
              }
              return false;
            }
          : null,
    );
  }

  Future<void> _pipeFileRangeInBlocks(
    File file,
    HttpResponse response,
    int start,
    int end,
    int blockSize,
    CancelableCompleter<void> cancelableCompleter,
  ) async {
    if (kDebugMode) {
      debugPrint(
        'streaming_server: _pipeFileRangeInBlocks start: $start end: $end',
      );
    }

    int currentStart = start;
    while (currentStart <= end) {
      if (cancelableCompleter.isCanceled) {
        if (kDebugMode) {
          debugPrint('streaming_server: _pipeFileRangeInBlocks isCanceled !!!');
        }
        throw CancellationException();
      }

      int currentEnd = currentStart + blockSize - 1;
      if (currentEnd > end) {
        currentEnd = end;
      }

      final startPiece =
          ((_fileOffset ?? 0) + currentStart) ~/ torrent.pieceSize;
      final endPiece = ((_fileOffset ?? 0) + currentEnd) ~/ torrent.pieceSize;
      final pieceCount = endPiece - startPiece + 1;

      await _waitForPieces(
        from: startPiece,
        count: pieceCount,
        cancelableCompleter: cancelableCompleter,
      );
      if (kDebugMode) {
        debugPrint(
          'streaming_server: reading pieces: $startPiece-$endPiece '
          'start: $start end: $end',
        );
      }
      final readStream = file.openRead(currentStart, currentEnd + 1);

      await for (final chunk in readStream) {
        if (cancelableCompleter.isCanceled) {
          throw CancellationException();
        }
        response.add(chunk);
        await response.flush();
      }

      currentStart = currentEnd + 1;
    }
    // Note: the response is closed once by _handleRequest's finally block to
    // avoid a double-close StateError.
  }

  /// Enables preview mode by prioritizing download of first and last pieces.
  ///
  /// This allows quick video preview by downloading the beginning (for headers)
  /// and end (for metadata) of the file first.
  Future<void> _enablePreviewMode() async {
    if (torrent.pieceCount <= 0) return;

    final filePieceCount = (torrentFile.endPiece - torrentFile.beginPiece + 1)
        .clamp(0, torrent.pieceCount);
    if (filePieceCount <= 0) return;

    final headCount = min(3, filePieceCount);
    final tailCount = min(3, filePieceCount);

    // Prioritize first few pieces (for video headers)
    final firstPieces = List.generate(
      headCount,
      (i) => torrentFile.beginPiece + i,
    );

    // Prioritize last few pieces (for video metadata/index)
    final lastPieces = List.generate(
      tailCount,
      (i) => torrentFile.endPiece - i,
    ).reversed.toList();

    final priorityPieces = {...firstPieces, ...lastPieces}
        .where((p) => p >= 0 && p < torrent.pieceCount)
        .toList();
    priorityPieces.sort();

    if (kDebugMode) {
      debugPrint(
        'streaming_server: enabling preview mode with priority pieces: $priorityPieces',
      );
    }

    try {
      await torrent.setPriorityPieces(priorityPieces, 7); // High priority
    } catch (e) {
      if (kDebugMode) {
        debugPrint('streaming_server: failed to set priority pieces: $e');
      }
    }
  }
}
