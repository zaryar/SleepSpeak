import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'logger_service.dart';

class WavAnalyzerService {
  final LoggerService _logger = LoggerService();

  /// Background Isolate: Analyzes a WAV file off the main UI thread with zero UI lag
  Future<List<double>> extractAmplitudeHistory(File wavFile) async {
    try {
      if (!await wavFile.exists()) return [];
      final path = wavFile.path;

      // Run heavy file parsing in background OS Isolate thread
      final rawHistory = await compute(_parseWavInIsolate, path);

      // Downsample to max 1200 points for instant 60/120 FPS rendering
      final downsampled = _downsample(rawHistory, maxPoints: 1200);

      _logger.log('WavAnalyzerService: Computed ${downsampled.length} points in background isolate for $path.');
      return downsampled;
    } catch (e) {
      _logger.log('WavAnalyzerService Error: $e');
      return [];
    }
  }

  static List<double> _downsample(List<double> input, {int maxPoints = 1200}) {
    if (input.length <= maxPoints) return input;

    final List<double> result = [];
    final double step = input.length / maxPoints;

    for (int i = 0; i < maxPoints; i++) {
      final int start = (i * step).floor();
      final int end = ((i + 1) * step).floor().clamp(start + 1, input.length);

      double maxDb = -60.0;
      for (int j = start; j < end; j++) {
        if (input[j] > maxDb) {
          maxDb = input[j];
        }
      }
      result.add(maxDb);
    }
    return result;
  }
}

/// Static top-level function executed in background Isolate
List<double> _parseWavInIsolate(String filePath) {
  final List<double> history = [];
  final file = File(filePath);

  if (!file.existsSync()) return history;

  final fileSize = file.lengthSync();
  if (fileSize <= 44) return history;

  final RandomAccessFile raf = file.openSync(mode: FileMode.read);
  try {
    raf.setPositionSync(44);

    const int bytesPerChunk = 6400; // 200ms of 16kHz 16-bit mono
    final int dataSize = fileSize - 44;
    final int totalChunks = dataSize ~/ bytesPerChunk;

    final Uint8List buffer = Uint8List(bytesPerChunk);

    for (int i = 0; i < totalChunks; i++) {
      final bytesRead = raf.readIntoSync(buffer);
      if (bytesRead < 2) break;

      final Int16List samples = buffer.buffer.asInt16List(0, bytesRead ~/ 2);

      double sumSquare = 0.0;
      for (int j = 0; j < samples.length; j++) {
        final sample = samples[j];
        sumSquare += sample * sample;
      }

      final rms = sqrt(sumSquare / samples.length);

      double db = -60.0;
      if (rms > 1.0) {
        db = 20.0 * (log(rms / 32768.0) / ln10);
      }
      history.add(db.clamp(-60.0, 0.0));
    }
  } finally {
    raf.closeSync();
  }

  return history;
}
