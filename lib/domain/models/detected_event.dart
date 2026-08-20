enum EventCategory {
  speech, // 🗣️ Schlafreden / Sprache / Flüstern
  snore, // 😴 Schnarchen / Schweres Atmen
  movement, // 🛏️ Bett & Körperbewegung / Deckenrascheln
  traffic, // 🚗 Verkehr / Auto / Straße
  household, // 🚪 Haushalt / Türen / Möbelknacken
  cough, // 🤧 Husten / Niesen / Räuspern
  pet, // 🐾 Haustiere / Bellen / Miauen
  noise, // 🔊 Sonstige Nebengeräusche
  general, // 🔊 Allgemeines Geräusch (vor KI-Analyse)
}

class DetectedEvent {
  final String id;
  final Duration startOffset;
  final Duration duration;
  final double maxDb;
  final double avgDb;
  final EventCategory category;
  final double confidence; // 0.0 to 1.0
  final String? transcription;
  final String? subType; // e.g. "Bettdeckenrascheln", "Auto", "Husten"
  final String? explanation; // e.g. "Decke wird bewegt, gefolgt von einer Körperdrehung."
  final String? dynamicEmoji; // e.g. 🗣️, 😴, 🛏️, 🚗, 🚪, 🤧, 🐾
  final List<String> tags; // e.g. ["⭐ Favorit", "🤣 Lustig", "🔒 Gesichert"]
  final bool isFavorite;

  const DetectedEvent({
    required this.id,
    required this.startOffset,
    required this.duration,
    required this.maxDb,
    required this.avgDb,
    this.category = EventCategory.general,
    this.confidence = 0.0,
    this.transcription,
    this.subType,
    this.explanation,
    this.dynamicEmoji,
    this.tags = const [],
    this.isFavorite = false,
  });

  bool get isProtected => isFavorite || tags.isNotEmpty;

  bool get isSpeech => category == EventCategory.speech;
  bool get isSnore => category == EventCategory.snore;
  bool get isMovement => category == EventCategory.movement;
  bool get isTraffic => category == EventCategory.traffic;
  bool get isHousehold => category == EventCategory.household;
  bool get isCough => category == EventCategory.cough;
  bool get isPet => category == EventCategory.pet;
  bool get isNoise =>
      category == EventCategory.noise ||
      category == EventCategory.movement ||
      category == EventCategory.traffic ||
      category == EventCategory.household ||
      category == EventCategory.cough ||
      category == EventCategory.pet;

  String get categoryLabel {
    switch (category) {
      case EventCategory.speech:
        return 'Schlafreden';
      case EventCategory.snore:
        return 'Schnarchen';
      case EventCategory.movement:
        return 'Bett & Bewegung';
      case EventCategory.traffic:
        return 'Verkehr';
      case EventCategory.household:
        return 'Haushalt & Türen';
      case EventCategory.cough:
        return 'Husten & Niesen';
      case EventCategory.pet:
        return 'Haustiere';
      case EventCategory.noise:
        return 'Nebengeräusch';
      case EventCategory.general:
        return 'Geräusch';
    }
  }

  String get categoryEmoji {
    if (dynamicEmoji != null && dynamicEmoji!.isNotEmpty) {
      return dynamicEmoji!;
    }
    switch (category) {
      case EventCategory.speech:
        return '🗣️';
      case EventCategory.snore:
        return '😴';
      case EventCategory.movement:
        return '🛏️';
      case EventCategory.traffic:
        return '🚗';
      case EventCategory.household:
        return '🚪';
      case EventCategory.cough:
        return '🤧';
      case EventCategory.pet:
        return '🐾';
      case EventCategory.noise:
        return '🔊';
      case EventCategory.general:
        return '🔊';
    }
  }

  DetectedEvent copyWith({
    String? id,
    Duration? startOffset,
    Duration? duration,
    double? maxDb,
    double? avgDb,
    EventCategory? category,
    double? confidence,
    String? transcription,
    String? subType,
    String? explanation,
    String? dynamicEmoji,
    List<String>? tags,
    bool? isFavorite,
  }) {
    return DetectedEvent(
      id: id ?? this.id,
      startOffset: startOffset ?? this.startOffset,
      duration: duration ?? this.duration,
      maxDb: maxDb ?? this.maxDb,
      avgDb: avgDb ?? this.avgDb,
      category: category ?? this.category,
      confidence: confidence ?? this.confidence,
      transcription: transcription ?? this.transcription,
      subType: subType ?? this.subType,
      explanation: explanation ?? this.explanation,
      dynamicEmoji: dynamicEmoji ?? this.dynamicEmoji,
      tags: tags ?? this.tags,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'startOffsetMs': startOffset.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'maxDb': maxDb,
        'avgDb': avgDb,
        'category': category.name,
        'confidence': confidence,
        'transcription': transcription,
        'subType': subType,
        'explanation': explanation,
        'dynamicEmoji': dynamicEmoji,
        'tags': tags,
        'isFavorite': isFavorite,
      };

  factory DetectedEvent.fromJson(Map<String, dynamic> json) {
    EventCategory cat = EventCategory.general;
    if (json.containsKey('category')) {
      final catStr = json['category'] as String?;
      if (catStr != null) {
        cat = EventCategory.values.firstWhere(
          (e) => e.name == catStr,
          orElse: () => EventCategory.general,
        );
      }
    }

    return DetectedEvent(
      id: json['id'] as String,
      startOffset: Duration(milliseconds: json['startOffsetMs'] as int),
      duration: Duration(milliseconds: json['durationMs'] as int),
      maxDb: (json['maxDb'] as num).toDouble(),
      avgDb: (json['avgDb'] as num).toDouble(),
      category: cat,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      transcription: json['transcription'] as String?,
      subType: json['subType'] as String?,
      explanation: json['explanation'] as String?,
      dynamicEmoji: json['dynamicEmoji'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  String formatShortTime(DateTime sessionStartTime) {
    final eventTime = sessionStartTime.add(startOffset);
    final hour = eventTime.hour.toString().padLeft(2, '0');
    final minute = eventTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute Uhr';
  }

  String formatPeriod(DateTime sessionStartTime) {
    final eventTime = sessionStartTime.add(startOffset);
    final hour = eventTime.hour;
    if (hour >= 22 || hour < 6) return 'nachts';
    if (hour >= 6 && hour < 11) return 'morgens';
    if (hour >= 11 && hour < 14) return 'mittags';
    if (hour >= 14 && hour < 18) return 'nachmittags';
    return 'abends';
  }

  String formatClockTime(DateTime sessionStartTime) {
    final eventTime = sessionStartTime.add(startOffset);
    final hour = eventTime.hour.toString().padLeft(2, '0');
    final minute = eventTime.minute.toString().padLeft(2, '0');
    final period = formatPeriod(sessionStartTime);
    return '$hour:$minute Uhr ($period)';
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
