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

    // Merge events that occur within 5 seconds (5000ms) of each other
    final List<DetectedEvent> mergedEvents = [];
    if (events.isNotEmpty) {
      DetectedEvent currentMerged = events.first;

      for (int i = 1; i < events.length; i++) {
        final nextEvent = events[i];
        final currentEndMs = currentMerged.startOffset.inMilliseconds + currentMerged.duration.inMilliseconds;
        final gapMs = nextEvent.startOffset.inMilliseconds - currentEndMs;

        if (gapMs <= 5000) {
          // Merge with currentMerged
          final newDuration = Duration(
            milliseconds: (nextEvent.startOffset.inMilliseconds + nextEvent.duration.inMilliseconds) -
                currentMerged.startOffset.inMilliseconds,
          );
          final newMaxDb = nextEvent.maxDb > currentMerged.maxDb ? nextEvent.maxDb : currentMerged.maxDb;
          final newAvgDb = (currentMerged.avgDb + nextEvent.avgDb) / 2;

          currentMerged = DetectedEvent(
            id: currentMerged.id,
            startOffset: currentMerged.startOffset,
            duration: newDuration,
            maxDb: newMaxDb,
            avgDb: newAvgDb,
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
}
