/// Model downloader: downloads GGUF files from HuggingFace URLs with progress.
/// Uses dart:io HttpClient directly — no extra dependency needed.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Download state for the UI.
enum DownloadState { idle, downloading, completed, error }

/// Progress data emitted during download.
class DownloadProgress {
  final DownloadState state;
  final double fraction; // 0.0 – 1.0
  final int receivedBytes;
  final int totalBytes;
  final String? filePath; // set when completed
  final String? error; // set when errored
  final String fileName;

  const DownloadProgress({
    required this.state,
    this.fraction = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.filePath,
    this.error,
    this.fileName = '',
  });

  String get receivedMB => (receivedBytes / 1024 / 1024).toStringAsFixed(1);
  String get totalMB => (totalBytes / 1024 / 1024).toStringAsFixed(1);
  String get progressText => totalBytes > 0
      ? '$receivedMB / $totalMB MB (${(fraction * 100).toStringAsFixed(0)}%)'
      : '$receivedMB MB downloaded';
}

/// Downloads a GGUF model from a URL (typically HuggingFace) to app storage.
class ModelDownloader {
  HttpClient? _client;
  bool _cancelled = false;

  /// Normalises a HuggingFace URL so it resolves to the raw file.
  ///
  /// Accepts formats like:
  ///   - https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/file.gguf
  ///   - https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/main/file.gguf
  /// The second form is what you get when you copy the URL from the HuggingFace
  /// file browser — we rewrite /blob/ → /resolve/ so it serves the raw file.
  static String normaliseUrl(String url) {
    url = url.trim();
    // HuggingFace /blob/ → /resolve/
    if (url.contains('huggingface.co') && url.contains('/blob/')) {
      url = url.replaceFirst('/blob/', '/resolve/');
    }
    return url;
  }

  /// Extracts a filename from a URL (last path segment).
  static String fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'model.gguf';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isNotEmpty ? segments.last : 'model.gguf';
  }

  /// Downloads [url] to app documents directory, yielding progress updates.
  ///
  /// The returned stream emits [DownloadProgress] events and completes with
  /// a final event whose [DownloadProgress.filePath] is the saved path.
  Stream<DownloadProgress> download(String url) async* {
    _cancelled = false;
    final normUrl = normaliseUrl(url);
    final fileName = fileNameFromUrl(normUrl);

    yield DownloadProgress(
      state: DownloadState.downloading,
      fileName: fileName,
    );

    try {
      _client = HttpClient();
      // Some HuggingFace CDN nodes require a browser-like User-Agent
      final request = await _client!.getUrl(Uri.parse(normUrl));
      request.headers.set('User-Agent', 'ThermalPilot/1.0');
      request.followRedirects = true;
      request.maxRedirects = 5;

      final response = await request.close();

      if (response.statusCode != 200) {
        yield DownloadProgress(
          state: DownloadState.error,
          fileName: fileName,
          error: 'HTTP ${response.statusCode}: ${response.reasonPhrase}',
        );
        return;
      }

      final totalBytes = response.contentLength;
      final dir = await getApplicationDocumentsDirectory();
      final outFile = File('${dir.path}/$fileName');
      final sink = outFile.openWrite();

      int received = 0;
      final stopwatch = Stopwatch()..start();

      await for (final chunk in response) {
        if (_cancelled) {
          await sink.close();
          if (await outFile.exists()) await outFile.delete();
          yield DownloadProgress(
            state: DownloadState.error,
            fileName: fileName,
            error: 'Download cancelled',
          );
          return;
        }

        sink.add(chunk);
        received += chunk.length;

        // Throttle progress events to ~4/sec to avoid UI jank
        if (stopwatch.elapsedMilliseconds > 250) {
          stopwatch.reset();
          yield DownloadProgress(
            state: DownloadState.downloading,
            fraction: totalBytes > 0 ? received / totalBytes : 0,
            receivedBytes: received,
            totalBytes: totalBytes > 0 ? totalBytes : 0,
            fileName: fileName,
          );
        }
      }

      await sink.flush();
      await sink.close();

      final savedPath = outFile.path;
      debugPrint('ModelDownloader: saved $fileName to $savedPath '
          '(${(received / 1024 / 1024).toStringAsFixed(1)} MB)');

      yield DownloadProgress(
        state: DownloadState.completed,
        fraction: 1.0,
        receivedBytes: received,
        totalBytes: totalBytes > 0 ? totalBytes : received,
        filePath: savedPath,
        fileName: fileName,
      );
    } catch (e) {
      yield DownloadProgress(
        state: DownloadState.error,
        fileName: fileName,
        error: e.toString(),
      );
    } finally {
      _client?.close();
      _client = null;
    }
  }

  /// Cancels an in-progress download.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// Checks if a model file already exists in app documents.
  static Future<String?> existingModelPath(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) return file.path;
    return null;
  }
}
