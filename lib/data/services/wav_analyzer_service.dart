import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../../domain/models/detected_event.dart';
import 'logger_service.dart';
import 'platform_file/platform_file.dart';

class WavAnalysisResult {
  final List<double> waveformHistory; // Downsampled for instant 120 FPS UI
  final List<DetectedEvent> detectedEvents; // Exact millisecond precision

  const WavAnalysisResult({
    required this.waveformHistory,
    required this.detectedEvents,
  });
}

class WavAnalyzerService {
  final LoggerService _logger = LoggerService();

  /// Analyzes a WAV file in a background isolate:
  /// Detects noise events with exact millisecond precision, and downsamples waveform for UI.
  Future<WavAnalysisResult> analyzeWavFile(AppFile wavFile, {double thresholdDb = -38.0}) async {
    if (kIsWeb) {
      return const WavAnalysisResult(waveformHistory: [], detectedEvents: []);
    }
    try {
      if (!await wavFile.exists()) {
        return const WavAnalysisResult(waveformHistory: [], detectedEvents: []);
      }
      final path = wavFile.path;

      // Run full WAV analysis in background OS worker thread
      final map = await compute(_analyzeWavInIsolate, {
        'path': path,
        'thresholdDb': thresholdDb,
      });

      final history = (map['history'] as List<dynamic>).map((e) => (e as num).toDouble()).toList();
      final eventsJson = map['events'] as List<dynamic>;
      final events = eventsJson
          .map((e) => DetectedEvent.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();

      _logger.log('WavAnalyzerService: Extracted ${events.length} dynamic events with exact timing for $path.');
      return WavAnalysisResult(waveformHistory: history, detectedEvents: events);
    } catch (e) {
      _logger.log('WavAnalyzerService Error: $e');
      return const WavAnalysisResult(waveformHistory: [], detectedEvents: []);
    }
  }

  /// Backward-compatible lightweight waveform extractor
  Future<List<double>> extractAmplitudeHistory(AppFile wavFile) async {
    final result = await analyzeWavFile(wavFile);
    return result.waveformHistory;
  }
}

/// Static top-level function executed in background Isolate
Map<String, dynamic> _analyzeWavInIsolate(Map<String, dynamic> params) {
  final String filePath = params['path'] as String;
  final double thresholdDb = (params['thresholdDb'] as num).toDouble();

  final List<double> rawHistory = [];
  final file = File(filePath);

  if (!file.existsSync()) {
    return {'history': <double>[], 'events': <Map<String, dynamic>>[]};
  }

  final fileSize = file.lengthSync();
  if (fileSize <= 44) {
    return {'history': <double>[], 'events': <Map<String, dynamic>>[]};
  }

  final raf = file.openSync(mode: FileMode.read);
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
      rawHistory.add(db.clamp(-60.0, 0.0));
    }
  } finally {
    raf.closeSync();
  }

  // 1. Calculate events at FULL 200ms precision (Exact dynamic duration: 1.2s, 3.4s, 5.0s, etc.)
  final List<Map<String, dynamic>> rawEvents = [];
  const int msPerSample = 200;

  bool inPeak = false;
  int peakStartIdx = 0;
  double maxDb = -100.0;
  double sumDb = 0.0;
  int count = 0;

  for (int i = 0; i < rawHistory.length; i++) {
    final db = rawHistory[i];
    if (db >= thresholdDb) {
      if (!inPeak) {
        inPeak = true;
        peakStartIdx = i;
        maxDb = db;
        sumDb = db;
        count = 1;
      } else {
        if (db > maxDb) maxDb = db;
        sumDb += db;
        count++;
      }
    } else {
      if (inPeak) {
        inPeak = false;
        final startMs = peakStartIdx * msPerSample;
        final endMs = i * msPerSample;
        final durationMs = endMs - startMs;

        if (durationMs >= 300) {
          rawEvents.add({
            'id': 'evt_${startMs}_${maxDb.toStringAsFixed(1)}',
            'startOffsetMs': startMs,
            'durationMs': durationMs,
            'maxDb': maxDb,
            'avgDb': sumDb / count,
          });
        }
      }
    }
  }

  if (inPeak) {
    final startMs = peakStartIdx * msPerSample;
    final endMs = rawHistory.length * msPerSample;
    final durationMs = endMs - startMs;
    if (durationMs >= 300) {
      rawEvents.add({
        'id': 'evt_${startMs}_${maxDb.toStringAsFixed(1)}',
        'startOffsetMs': startMs,
        'durationMs': durationMs,
        'maxDb': maxDb,
        'avgDb': sumDb / count,
      });
    }
  }

  // Merge events that occur within 5 seconds (5000ms) of each other
  final List<Map<String, dynamic>> mergedEvents = [];
  if (rawEvents.isNotEmpty) {
    var currentMerged = Map<String, dynamic>.from(rawEvents.first);

    for (int i = 1; i < rawEvents.length; i++) {
      final nextEvent = rawEvents[i];
      final currentEndMs = (currentMerged['startOffsetMs'] as int) + (currentMerged['durationMs'] as int);
      final gapMs = (nextEvent['startOffsetMs'] as int) - currentEndMs;

      if (gapMs <= 5000) {
        final newDurationMs = ((nextEvent['startOffsetMs'] as int) + (nextEvent['durationMs'] as int)) -
            (currentMerged['startOffsetMs'] as int);
        final nextMax = (nextEvent['maxDb'] as num).toDouble();
        final currMax = (currentMerged['maxDb'] as num).toDouble();
        final newMaxDb = nextMax > currMax ? nextMax : currMax;

        currentMerged['durationMs'] = newDurationMs;
        currentMerged['maxDb'] = newMaxDb;
        currentMerged['avgDb'] = ((currentMerged['avgDb'] as num) + (nextEvent['avgDb'] as num)) / 2.0;
      } else {
        mergedEvents.add(currentMerged);
        currentMerged = Map<String, dynamic>.from(nextEvent);
      }
    }
    mergedEvents.add(currentMerged);
  }

  // 2. Downsample rawHistory to max 1200 points for 120 FPS UI waveform rendering
  final downsampled = _downsampleList(rawHistory, 1200);

  return {
    'history': downsampled,
    'events': mergedEvents,
  };
}

List<double> _downsampleList(List<double> input, int maxPoints) {
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
