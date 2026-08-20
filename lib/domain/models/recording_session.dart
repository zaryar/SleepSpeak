import 'detected_event.dart';

class RecordingSession {
  final String id;
  final String title;
  final String filePath;
  final DateTime startTime;
  final Duration duration;
  final List<double> amplitudeHistory; // Decibel values (e.g. -60.0 to 0.0)
  final bool isFavorite;
  final bool isFinalized;
  final int fileSizeBytes;
  final List<DetectedEvent> detectedEvents;

  const RecordingSession({
    required this.id,
    required this.title,
    required this.filePath,
    required this.startTime,
    required this.duration,
    required this.amplitudeHistory,
    this.isFavorite = false,
    this.isFinalized = true,
    required this.fileSizeBytes,
    required this.detectedEvents,
  });

  RecordingSession copyWith({
    String? id,
    String? title,
    String? filePath,
    DateTime? startTime,
    Duration? duration,
    List<double>? amplitudeHistory,
    bool? isFavorite,
    bool? isFinalized,
    int? fileSizeBytes,
    List<DetectedEvent>? detectedEvents,
  }) {
    return RecordingSession(
      id: id ?? this.id,
      title: title ?? this.title,
      filePath: filePath ?? this.filePath,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      amplitudeHistory: amplitudeHistory ?? this.amplitudeHistory,
      isFavorite: isFavorite ?? this.isFavorite,
      isFinalized: isFinalized ?? this.isFinalized,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      detectedEvents: detectedEvents ?? this.detectedEvents,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'filePath': filePath,
        'startTime': startTime.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'amplitudeHistory': amplitudeHistory,
        'isFavorite': isFavorite,
        'isFinalized': isFinalized,
        'fileSizeBytes': fileSizeBytes,
        'detectedEvents': detectedEvents.map((e) => e.toJson()).toList(),
      };

  factory RecordingSession.fromJson(Map<String, dynamic> json) => RecordingSession(
        id: json['id'] as String,
        title: json['title'] as String,
        filePath: json['filePath'] as String,
        startTime: DateTime.parse(json['startTime'] as String),
        duration: Duration(milliseconds: json['durationMs'] as int),
        amplitudeHistory: (json['amplitudeHistory'] as List<dynamic>)
            .map((e) => (e as num).toDouble())
            .toList(),
        isFavorite: json['isFavorite'] as bool? ?? false,
        isFinalized: json['isFinalized'] as bool? ?? true,
        fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
        detectedEvents: (json['detectedEvents'] as List<dynamic>?)
                ?.map((e) => DetectedEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  // Calculates noise events dynamically based on a decibel threshold
  List<DetectedEvent> recalculateEvents(double thresholdDb) {
    final List<DetectedEvent> events = [];
    if (amplitudeHistory.isEmpty || duration.inMilliseconds == 0) return events;

    final msPerSample = duration.inMilliseconds / amplitudeHistory.length;
    bool inPeak = false;
    int peakStartIdx = 0;
    double maxDb = -100.0;
    double sumDb = 0.0;
    int count = 0;

    for (int i = 0; i < amplitudeHistory.length; i++) {
      final db = amplitudeHistory[i];
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
          final startMs = (peakStartIdx * msPerSample).round();
          final endMs = (i * msPerSample).round();
          final peakDuration = Duration(milliseconds: endMs - startMs);

          // Only treat as event if duration is at least 300ms
          if (peakDuration.inMilliseconds >= 300) {
            events.add(
              DetectedEvent(
                id: 'evt_${startMs}_$maxDb',
                startOffset: Duration(milliseconds: startMs),
                duration: peakDuration,
                maxDb: maxDb,
                avgDb: sumDb / count,
              ),
            );
          }
        }
      }
    }

    if (inPeak) {
      final startMs = (peakStartIdx * msPerSample).round();
      final endMs = (amplitudeHistory.length * msPerSample).round();
      events.add(
        DetectedEvent(
          id: 'evt_${startMs}_$maxDb',
          startOffset: Duration(milliseconds: startMs),
          duration: Duration(milliseconds: endMs - startMs),
          maxDb: maxDb,
          avgDb: sumDb / count,
        ),
      );
    }

    // Merge events that occur close to each other (gap <= 3s, max combined duration <= 12s)
    final List<DetectedEvent> mergedEvents = [];
    if (events.isNotEmpty) {
      DetectedEvent currentMerged = events.first;

      for (int i = 1; i < events.length; i++) {
        final nextEvent = events[i];
        final currentEndMs = currentMerged.startOffset.inMilliseconds + currentMerged.duration.inMilliseconds;
        final gapMs = nextEvent.startOffset.inMilliseconds - currentEndMs;
        final newDurationMs = (nextEvent.startOffset.inMilliseconds + nextEvent.duration.inMilliseconds) -
            currentMerged.startOffset.inMilliseconds;

        if (gapMs <= 3000 && newDurationMs <= 12000) {
          // Merge with currentMerged
          final newDuration = Duration(milliseconds: newDurationMs);
          final newMaxDb = nextEvent.maxDb > currentMerged.maxDb ? nextEvent.maxDb : currentMerged.maxDb;
          final newAvgDb = (currentMerged.avgDb + nextEvent.avgDb) / 2;

          currentMerged = DetectedEvent(
            id: currentMerged.id,
            startOffset: currentMerged.startOffset,
            duration: newDuration,
            maxDb: newMaxDb,
            avgDb: newAvgDb,
            category: currentMerged.category,
            confidence: currentMerged.confidence,
            transcription: currentMerged.transcription,
          );
        } else {
          mergedEvents.add(currentMerged);
          currentMerged = nextEvent;
        }
      }
      mergedEvents.add(currentMerged);
    }

    return mergedEvents;
  }

  /// Automatically estimates the background noise floor (Grundrauschen) of the room
  double estimateNoiseFloorDb() {
    if (amplitudeHistory.isEmpty) return -50.0;

    // Filter out extreme disconnects (-100dB)
    final validValues = amplitudeHistory.where((db) => db > -95.0 && db <= 0.0).toList();
    if (validValues.isEmpty) return -50.0;

    validValues.sort();
    // 25th percentile represents steady ambient room noise
    final int p25Index = (validValues.length * 0.25).clamp(0, validValues.length - 1).toInt();
    return validValues[p25Index];
  }

  /// Measures the exact peak noise floor in a 3-second window around a selected timestamp
  double measureNoiseAtTime(Duration position, {Duration window = const Duration(seconds: 3)}) {
    if (amplitudeHistory.isEmpty || duration.inMilliseconds == 0) return -50.0;

    final double msPerSample = duration.inMilliseconds / amplitudeHistory.length;
    final int centerIndex = (position.inMilliseconds / msPerSample).round().clamp(0, amplitudeHistory.length - 1);
    final int windowHalfSamples = ((window.inMilliseconds / 2) / msPerSample).round().clamp(1, 20);

    final int startIdx = (centerIndex - windowHalfSamples).clamp(0, amplitudeHistory.length - 1);
    final int endIdx = (centerIndex + windowHalfSamples).clamp(startIdx, amplitudeHistory.length - 1);

    double maxNoiseInWindow = -100.0;
    for (int i = startIdx; i <= endIdx; i++) {
      final db = amplitudeHistory[i];
      if (db > maxNoiseInWindow) {
        maxNoiseInWindow = db;
      }
    }

    return maxNoiseInWindow > -95.0 ? maxNoiseInWindow : -50.0;
  }
}
