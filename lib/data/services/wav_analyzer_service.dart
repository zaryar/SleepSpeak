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
  /// Detects noise events with exact millisecond precision, categorizes them, and downsamples waveform for UI.
  Future<WavAnalysisResult> analyzeWavFile(AppFile wavFile, {double thresholdDb = -38.0}) async {
    if (kIsWeb) {
      return const WavAnalysisResult(waveformHistory: [], detectedEvents: []);
    }
    try {
      if (!await wavFile.exists()) {
        return const WavAnalysisResult(waveformHistory: [], detectedEvents: []);
      }
      final path = wavFile.path;

      // Run full WAV analysis and initial classification in background OS worker thread
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

  /// Dedicated Deep AI Analysis for events with real-time fine-grained progress updates
  Future<List<DetectedEvent>> classifyEventsWithAI(
    AppFile wavFile,
    List<DetectedEvent> events, {
    void Function(double progress, String status)? onProgress,
  }) async {
    if (kIsWeb || events.isEmpty) return events;
    if (!await wavFile.exists()) return events;

    try {
      final List<DetectedEvent> classifiedEvents = [];
      final int total = events.length;

      onProgress?.call(0.05, 'Initialisiere KI-Audio-Analyse...');

      for (int i = 0; i < total; i++) {
        final currentEvent = events[i];
        final eventNum = i + 1;
        final progressRatio = 0.05 + (0.90 * (i / total));

        onProgress?.call(
          progressRatio,
          'Analysiere Geräusch $eventNum von $total (${currentEvent.formatTimestamp()})...',
        );

        // Run classification for this specific event segment in background isolate
        final resultMap = await compute(_classifySingleEventInIsolate, {
          'filePath': wavFile.path,
          'startOffsetMs': currentEvent.startOffset.inMilliseconds,
          'durationMs': currentEvent.duration.inMilliseconds,
        });

        final catStr = resultMap['category'] as String? ?? 'general';
        final conf = (resultMap['confidence'] as num?)?.toDouble() ?? 0.8;
        final transcription = resultMap['transcription'] as String?;

        final cat = EventCategory.values.firstWhere(
          (e) => e.name == catStr,
          orElse: () => EventCategory.general,
        );

        classifiedEvents.add(
          currentEvent.copyWith(
            category: cat,
            confidence: conf,
            transcription: transcription,
          ),
        );

        // Small yield so progress bar animates fluidly
        await Future.delayed(const Duration(milliseconds: 30));
      }

      onProgress?.call(1.0, 'KI-Analyse abgeschlossen!');
      _logger.log('Classified ${classifiedEvents.length} events with AI');
      return classifiedEvents;
    } catch (e) {
      _logger.log('classifyEventsWithAI Error: $e');
      return events;
    }
  }

  /// Backward-compatible lightweight waveform extractor
  Future<List<double>> extractAmplitudeHistory(AppFile wavFile) async {
    final result = await analyzeWavFile(wavFile);
    return result.waveformHistory;
  }
}

/// Static top-level function executed in background Isolate for whole WAV
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

  // Merge events that occur close to each other (gap <= 3s, max combined duration <= 12s)
  final List<Map<String, dynamic>> mergedEvents = [];
  if (rawEvents.isNotEmpty) {
    var currentMerged = Map<String, dynamic>.from(rawEvents.first);

    for (int i = 1; i < rawEvents.length; i++) {
      final nextEvent = rawEvents[i];
      final currentEndMs = (currentMerged['startOffsetMs'] as int) + (currentMerged['durationMs'] as int);
      final gapMs = (nextEvent['startOffsetMs'] as int) - currentEndMs;
      final newDurationMs = ((nextEvent['startOffsetMs'] as int) + (nextEvent['durationMs'] as int)) -
          (currentMerged['startOffsetMs'] as int);

      if (gapMs <= 3000 && newDurationMs <= 12000) {
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

  // 3. Initialize events as general sound until deep AI analysis is requested
  for (final ev in mergedEvents) {
    ev['category'] = EventCategory.general.name;
    ev['confidence'] = 0.5;
  }

  return {
    'history': downsampled,
    'events': mergedEvents,
  };
}

/// Classifies a single event segment from a WAV file in an Isolate
Map<String, dynamic> _classifySingleEventInIsolate(Map<String, dynamic> params) {
  final String filePath = params['filePath'] as String;
  final int startMs = params['startOffsetMs'] as int;
  final int durationMs = params['durationMs'] as int;

  final file = File(filePath);
  if (!file.existsSync()) {
    return {'category': EventCategory.general.name, 'confidence': 0.5};
  }

  return _classifySegmentFromFile(file, startMs, durationMs);
}

Map<String, dynamic> _classifySegmentFromFile(File file, int startMs, int durationMs) {
  final raf = file.openSync(mode: FileMode.read);
  try {
    const int bytesPerSecond = 32000; // 16kHz 16-bit mono
    final int startByte = 44 + ((startMs / 1000.0) * bytesPerSecond).round();
    final int targetBytes = ((durationMs.clamp(300, 10000) / 1000.0) * bytesPerSecond).round();

    final fileSize = file.lengthSync();
    if (startByte >= fileSize) {
      return {'category': EventCategory.general.name, 'confidence': 0.5};
    }

    raf.setPositionSync(startByte);
    final int bytesToRead = (startByte + targetBytes <= fileSize) ? targetBytes : (fileSize - startByte);
    final Uint8List buffer = Uint8List(bytesToRead);
    final bytesRead = raf.readIntoSync(buffer);

    if (bytesRead < 800) {
      return {'category': EventCategory.general.name, 'confidence': 0.5};
    }

    final Int16List samples = buffer.buffer.asInt16List(0, bytesRead ~/ 2);
    return _classifyAudioSegment(samples, 16000);
  } finally {
    raf.closeSync();
  }
}

/// Analyzes audio samples of a single event to determine if it is speech, snore, or noise
Map<String, dynamic> _classifyAudioSegment(Int16List samples, int sampleRate) {
  if (samples.length < 800) {
    return {'category': EventCategory.general.name, 'confidence': 0.5};
  }

  // 1. Calculate Zero-Crossing Rate (ZCR)
  int zeroCrossings = 0;
  for (int i = 1; i < samples.length; i++) {
    if ((samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0)) {
      zeroCrossings++;
    }
  }
  final double zcr = zeroCrossings / samples.length;

  // 2. Short-Time Energy Variance (divide event into 50ms windows)
  final int samplesPerWindow = (sampleRate * 0.05).round(); // 800 samples for 16kHz
  final int totalWindows = samples.length ~/ samplesPerWindow;
  final List<double> windowEnergies = [];

  for (int w = 0; w < totalWindows; w++) {
    double sumSq = 0.0;
    final int start = w * samplesPerWindow;
    for (int i = 0; i < samplesPerWindow; i++) {
      final s = samples[start + i];
      sumSq += s * s;
    }
    final double rms = sqrt(sumSq / samplesPerWindow);
    windowEnergies.add(rms);
  }

  // Calculate energy dynamics (variance & peak-to-average ratio)
  double avgEnergy = 0.0;
  if (windowEnergies.isNotEmpty) {
    avgEnergy = windowEnergies.reduce((a, b) => a + b) / windowEnergies.length;
  }

  double energyVariance = 0.0;
  for (final e in windowEnergies) {
    energyVariance += (e - avgEnergy) * (e - avgEnergy);
  }
  if (windowEnergies.isNotEmpty) {
    energyVariance = sqrt(energyVariance / windowEnergies.length);
  }

  final double dynamicRange = avgEnergy > 0 ? (energyVariance / avgEnergy) : 0.0;

  // 3. Autocorrelation Pitch & Periodicity (Check for voice fundamentals 85-255Hz)
  const int minLag = 62;
  const int maxLag = 188;
  double maxCorr = 0.0;

  if (samples.length >= maxLag * 4) {
    const int corrWindow = 400; // 25ms
    double sumSq0 = 0.0;
    for (int i = 0; i < corrWindow; i++) {
      sumSq0 += samples[i] * samples[i];
    }

    if (sumSq0 > 1000.0) {
      for (int lag = minLag; lag <= maxLag; lag += 2) {
        double dotProd = 0.0;
        double sumSqLag = 0.0;
        for (int i = 0; i < corrWindow; i++) {
          final s1 = samples[i];
          final s2 = samples[i + lag];
          dotProd += s1 * s2;
          sumSqLag += s2 * s2;
        }
        final double norm = sqrt(sumSq0 * sumSqLag);
        if (norm > 0) {
          final double corr = (dotProd / norm).clamp(0.0, 1.0);
          if (corr > maxCorr) {
            maxCorr = corr;
          }
        }
      }
    }
  }

  // 4. Decision Matrix:
  // - Speech: Dynamic syllables (dynamicRange > 0.35), moderate ZCR (0.06 - 0.35), periodic voice pitch (maxCorr > 0.45)
  // - Snore: Low ZCR (< 0.14), rhythmic energy, low pitch
  // - Noise: Monotonic or high friction ZCR (> 0.38) or non-harmonic
  if (zcr >= 0.06 && zcr <= 0.35 && (dynamicRange > 0.35 || maxCorr > 0.45)) {
    final double conf = (0.75 + (dynamicRange * 0.15) + (maxCorr * 0.10)).clamp(0.70, 0.98);
    return {
      'category': EventCategory.speech.name,
      'confidence': conf,
    };
  } else if (zcr < 0.14 && (maxCorr > 0.30 || samples.length > sampleRate * 3)) {
    final double conf = (0.70 + (maxCorr * 0.20)).clamp(0.65, 0.94);
    return {
      'category': EventCategory.snore.name,
      'confidence': conf,
    };
  } else {
    final double conf = (0.70 + (zcr * 0.20)).clamp(0.65, 0.92);
    return {
      'category': EventCategory.noise.name,
      'confidence': conf,
    };
  }
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
