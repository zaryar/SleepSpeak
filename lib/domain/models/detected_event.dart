class DetectedEvent {
  final String id;
  final Duration startOffset;
  final Duration duration;
  final double maxDb;
  final double avgDb;

  const DetectedEvent({
    required this.id,
    required this.startOffset,
    required this.duration,
    required this.maxDb,
    required this.avgDb,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'startOffsetMs': startOffset.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'maxDb': maxDb,
        'avgDb': avgDb,
      };

  factory DetectedEvent.fromJson(Map<String, dynamic> json) => DetectedEvent(
        id: json['id'] as String,
        startOffset: Duration(milliseconds: json['startOffsetMs'] as int),
        duration: Duration(milliseconds: json['durationMs'] as int),
        maxDb: (json['maxDb'] as num).toDouble(),
        avgDb: (json['avgDb'] as num).toDouble(),
      );

  String formatClockTime(DateTime sessionStartTime) {
    final eventTime = sessionStartTime.add(startOffset);
    final hour = eventTime.hour;
    final minute = eventTime.minute.toString().padLeft(2, '0');

    String period;
    if (hour >= 22 || hour < 6) {
      period = 'nachts';
    } else if (hour >= 6 && hour < 11) {
      period = 'morgens';
    } else if (hour >= 11 && hour < 14) {
      period = 'mittags';
    } else if (hour >= 14 && hour < 18) {
      period = 'nachmittags';
    } else {
      period = 'abends';
    }

    return 'Geräusch um $hour:$minute Uhr ($period)';
  }

  String formatTimestamp() {
    final minutes = startOffset.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = startOffset.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = startOffset.inHours;
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
