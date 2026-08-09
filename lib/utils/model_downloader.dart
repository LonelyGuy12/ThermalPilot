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
  static String normaliseUrl(String url) {
    url = url.trim();
    if (url.contains('huggingface.co') && url.contains('/blob/')) {
      url = url.replaceFirst('/blob/', '/resolve/');
    }
    return url;
  }

  static String fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'model.gguf';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isNotEmpty ? segments.last : 'model.gguf';
  }

  /// Downloads [url] to app documents directory, yielding progress updates.
  /// Supports auto-resume on connection drops.
  Stream<DownloadProgress> download(String url) async* {
    _cancelled = false;
    final normUrl = normaliseUrl(url);
    final fileName = fileNameFromUrl(normUrl);

    yield DownloadProgress(
      state: DownloadState.downloading,
      fileName: fileName,
    );

    final dir = await getApplicationDocumentsDirectory();
    final outFile = File('${dir.path}/$fileName');
    
    int maxRetries = 5;
    int retryCount = 0;
    int received = 0;
    int totalBytes = 0;
    
    // If the file exists from a previous failed attempt, we can try to resume.
    if (await outFile.exists()) {
      received = await outFile.length();
    }

    while (retryCount < maxRetries && !_cancelled) {
      IOSink? sink;
      try {
        _client = HttpClient();
        _client!.connectionTimeout = const Duration(seconds: 15);
        final request = await _client!.getUrl(Uri.parse(normUrl));
        request.headers.set('User-Agent', 'ThermalPilot/1.0');
        
        if (received > 0) {
          request.headers.set('Range', 'bytes=$received-');
        }
        
        request.followRedirects = true;
        request.maxRedirects = 5;

        final response = await request.close();

        if (response.statusCode != 200 && response.statusCode != 206) {
          if (response.statusCode == 416) {
            // Range not satisfiable -> file already downloaded completely.
            break; 
          }
          yield DownloadProgress(
            state: DownloadState.error,
            fileName: fileName,
            error: 'HTTP ${response.statusCode}: ${response.reasonPhrase}',
          );
          return;
        }

        // On first successful request, determine total size
        if (totalBytes == 0) {
          if (response.statusCode == 206) {
            // Partial content: Content-Range: bytes 100-200/500
            final contentRange = response.headers.value('content-range');
            if (contentRange != null && contentRange.contains('/')) {
              totalBytes = int.tryParse(contentRange.split('/').last) ?? 0;
            }
          } else {
            totalBytes = response.contentLength;
            if (received > 0) {
              // Server ignored Range header, restart download.
              received = 0;
            }
          }
        }

        // Open file: append if resuming (and server accepted range), else overwrite.
        sink = outFile.openWrite(mode: received > 0 ? FileMode.append : FileMode.writeOnly);
        
        final stopwatch = Stopwatch()..start();

        await for (final chunk in response) {
          if (_cancelled) {
            await sink.close();
            // keep partial file so they can resume later
            yield DownloadProgress(
              state: DownloadState.error,
              fileName: fileName,
              error: 'Download cancelled',
            );
            return;
          }

          sink.add(chunk);
          received += chunk.length;

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
        
        // If we reach here without exception, download is complete!
        break; 

      } catch (e) {
        await sink?.close();
        if (_cancelled) return;
        
        retryCount++;
        debugPrint('Download error (retry $retryCount/$maxRetries): $e');
        
        if (retryCount >= maxRetries) {
          yield DownloadProgress(
            state: DownloadState.error,
            fileName: fileName,
            error: e.toString(),
          );
          return;
        }
        
        // Small backoff before retry
        await Future.delayed(Duration(seconds: 2 * retryCount));
      } finally {
        _client?.close();
        _client = null;
      }
    }

    if (_cancelled) return;

    final savedPath = outFile.path;
    debugPrint('ModelDownloader: saved $fileName to $savedPath (${(received / 1024 / 1024).toStringAsFixed(1)} MB)');

    yield DownloadProgress(
      state: DownloadState.completed,
      fraction: 1.0,
      receivedBytes: received,
      totalBytes: totalBytes > 0 ? totalBytes : received,
      filePath: savedPath,
      fileName: fileName,
    );
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  static Future<String?> existingModelPath(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) return file.path;
    return null;
  }
}
