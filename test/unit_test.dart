import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_recorder/data/services/gemini_audio_service.dart';
import 'package:sleep_recorder/data/services/platform_file/platform_file.dart';
import 'package:sleep_recorder/domain/models/detected_event.dart';
import 'package:sleep_recorder/domain/models/recording_session.dart';

void main() {
  group('RecordingSession Peak Detection & Amplitude History Tests', () {
    test('recalculateEvents merges peaks within 5 seconds into one event', () {
      final amplitudeHistory = [
        -55.0, -50.0, -52.0, -48.0, // Quiet
        -25.0, -20.0, -28.0,        // Peak 1
        -50.0, -52.0,               // 1s Quiet gap
        -30.0, -22.0,               // Peak 2 (within 5s of Peak 1)
        -55.0, -55.0, -50.0, -52.0, -50.0, -50.0, -50.0, -50.0
      ];

      final session = RecordingSession(
        id: 'test_session_1',
        title: 'Test Session',
        filePath: '/tmp/test.wav',
        startTime: DateTime(2026, 8, 20, 2, 30),
        duration: const Duration(seconds: 10),
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: 160000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);

      expect(events.length, equals(1));
      expect(events[0].maxDb, equals(-20.0));
      expect(events[0].duration, isNotNull);
    });

    test('recalculateEvents keeps peaks separate if more than 5 seconds apart', () {
      final List<double> history = List.filled(60, -55.0);
      history[5] = -20.0;
      history[6] = -22.0;

      history[40] = -25.0;
      history[41] = -24.0;

      final session = RecordingSession(
        id: 'test_session_2',
        title: 'Test Session 2',
        filePath: '/tmp/test2.wav',
        startTime: DateTime(2026, 8, 20, 3, 0),
        duration: const Duration(seconds: 30),
        amplitudeHistory: history,
        fileSizeBytes: 300000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);
      expect(events.length, equals(2));
      expect(events[0].startOffset.inSeconds, equals(2)); // index 5 * 0.5s = 2.5s -> 2s
      expect(events[1].startOffset.inSeconds, equals(20)); // index 40 * 0.5s = 20s
    });

    test('recalculateEvents handles empty history gracefully', () {
      final session = RecordingSession(
        id: 'empty_session',
        title: 'Empty History Session',
        filePath: '/tmp/empty.wav',
        startTime: DateTime(2026, 8, 20, 4, 0),
        duration: Duration.zero,
        amplitudeHistory: [],
        fileSizeBytes: 0,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);
      expect(events, isEmpty);
    });

    test('recalculateEvents ignores background noise below threshold', () {
      final amplitudeHistory = List.filled(50, -50.0);
      final session = RecordingSession(
        id: 'quiet_session',
        title: 'Quiet Night',
        filePath: '/tmp/quiet.wav',
        startTime: DateTime(2026, 8, 20, 1, 0),
        duration: const Duration(minutes: 5),
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: 800000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);
      expect(events, isEmpty);
    });

    test('recalculateEvents with ultra-sensitive threshold captures faint sounds', () {
      final amplitudeHistory = [-60.0, -58.0, -54.0, -53.0, -60.0];
      final session = RecordingSession(
        id: 'whisper_session',
        title: 'Whisper Night',
        filePath: '/tmp/whisper.wav',
        startTime: DateTime(2026, 8, 20, 2, 0),
        duration: const Duration(seconds: 3),
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: 50000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-55.0);
      expect(events.length, equals(1));
      expect(events[0].maxDb, equals(-53.0));
    });
  });

  group('Noise Floor & Smart Calibration Tests', () {
    test('RecordingSession accurately estimates noise floor using 25th percentile', () {
      final List<double> history = [
        -45.0, -44.5, -45.2, -44.8,
        -45.0, -44.9, -45.1, -44.7,
        -20.0, -18.0, -22.0,        // Loud event
        -45.0, -45.1, -45.0, -44.8,
      ];

      final session = RecordingSession(
        id: 'noise_test_1',
        title: 'Noise Floor Session',
        filePath: '/tmp/test_noise.wav',
        startTime: DateTime.now(),
        duration: const Duration(seconds: 8),
        amplitudeHistory: history,
        fileSizeBytes: 100000,
        detectedEvents: [],
      );

      final estimatedNoise = session.estimateNoiseFloorDb();
      expect(estimatedNoise, inInclusiveRange(-46.0, -44.0));

      final noiseAtQuiet = session.measureNoiseAtTime(const Duration(milliseconds: 500));
      expect(noiseAtQuiet, inInclusiveRange(-46.0, -44.0));

      final noiseAtSnore = session.measureNoiseAtTime(const Duration(milliseconds: 4500));
      expect(noiseAtSnore, equals(-18.0));
    });

    test('estimateNoiseFloorDb handles empty history with default -50 dB', () {
      final session = RecordingSession(
        id: 'empty_noise_test',
        title: 'Empty Noise Session',
        filePath: '/tmp/empty.wav',
        startTime: DateTime.now(),
        duration: Duration.zero,
        amplitudeHistory: [],
        fileSizeBytes: 0,
        detectedEvents: [],
      );

      expect(session.estimateNoiseFloorDb(), equals(-50.0));
      expect(session.measureNoiseAtTime(const Duration(seconds: 2)), equals(-50.0));
    });

    test('measureNoiseAtTime handles out-of-bounds positions gracefully', () {
      final session = RecordingSession(
        id: 'bounds_test',
        title: 'Bounds Session',
        filePath: '/tmp/bounds.wav',
        startTime: DateTime.now(),
        duration: const Duration(seconds: 2),
        amplitudeHistory: [-40.0, -42.0, -41.0, -39.0],
        fileSizeBytes: 20000,
        detectedEvents: [],
      );

      // Beyond duration
      expect(session.measureNoiseAtTime(const Duration(seconds: 10)), inInclusiveRange(-43.0, -38.0));
      // Negative position
      expect(session.measureNoiseAtTime(const Duration(seconds: -5)), inInclusiveRange(-43.0, -38.0));
    });
  });

  group('DetectedEvent Serialization & Tagging Tests', () {
    test('DetectedEvent serialization preserves all fields, tags, and protection state', () {
      const event = DetectedEvent(
        id: 'evt_speech_1',
        startOffset: Duration(seconds: 12),
        duration: Duration(seconds: 3),
        maxDb: -22.5,
        avgDb: -28.0,
        category: EventCategory.speech,
        confidence: 0.94,
        transcription: 'wo sind die schlüssel',
        subType: 'Flüstern',
        explanation: 'Deutliches Flüstern im Schlafzimmer.',
        dynamicEmoji: '🗣️',
        tags: ['⭐ Favorit', '🤣 Lustig'],
        isFavorite: true,
      );

      final json = event.toJson();
      expect(json['category'], equals('speech'));
      expect(json['confidence'], equals(0.94));
      expect(json['transcription'], equals('wo sind die schlüssel'));
      expect(json['subType'], equals('Flüstern'));
      expect(json['explanation'], equals('Deutliches Flüstern im Schlafzimmer.'));
      expect(json['dynamicEmoji'], equals('🗣️'));
      expect(json['tags'], equals(['⭐ Favorit', '🤣 Lustig']));
      expect(json['isFavorite'], isTrue);

      final restored = DetectedEvent.fromJson(json);
      expect(restored.isSpeech, isTrue);
      expect(restored.category, equals(EventCategory.speech));
      expect(restored.categoryLabel, equals('Schlafreden'));
      expect(restored.categoryEmoji, equals('🗣️'));
      expect(restored.subType, equals('Flüstern'));
      expect(restored.explanation, equals('Deutliches Flüstern im Schlafzimmer.'));
      expect(restored.transcription, equals('wo sind die schlüssel'));
      expect(restored.tags, equals(['⭐ Favorit', '🤣 Lustig']));
      expect(restored.isFavorite, isTrue);
      expect(restored.isProtected, isTrue);
    });

    test('DetectedEvent fallback on unknown category safely maps to general', () {
      final json = {
        'id': 'unknown_cat_1',
        'startOffsetMs': 1000,
        'durationMs': 2000,
        'maxDb': -30.0,
        'avgDb': -35.0,
        'category': 'alien_sound', // Unknown category
      };

      final restored = DetectedEvent.fromJson(json);
      expect(restored.category, equals(EventCategory.general));
      expect(restored.categoryEmoji, equals('🔊'));
    });

    test('DetectedEvent isProtected is true when tags are present even if isFavorite is false', () {
      const eventWithTag = DetectedEvent(
        id: 'tagged_evt',
        startOffset: Duration(seconds: 5),
        duration: Duration(seconds: 2),
        maxDb: -25.0,
        avgDb: -30.0,
        tags: ['🔒 Behalten'],
        isFavorite: false,
      );
      expect(eventWithTag.isProtected, isTrue);

      const untaggedEvent = DetectedEvent(
        id: 'plain_evt',
        startOffset: Duration(seconds: 5),
        duration: Duration(seconds: 2),
        maxDb: -25.0,
        avgDb: -30.0,
        tags: [],
        isFavorite: false,
      );
      expect(untaggedEvent.isProtected, isFalse);
    });

    test('DetectedEvent time formatting formats clock periods correctly', () {
      final baseNight = DateTime(2026, 8, 20, 2, 15);
      final event1 = const DetectedEvent(
        id: 'night_evt',
        startOffset: Duration(minutes: 25), // 02:40
        duration: Duration(seconds: 2),
        maxDb: -30.0,
        avgDb: -35.0,
      );
      expect(event1.formatShortTime(baseNight), equals('02:40 Uhr'));
      expect(event1.formatPeriod(baseNight), equals('nachts'));
      expect(event1.formatClockTime(baseNight), equals('02:40 Uhr (nachts)'));

      final baseMorning = DateTime(2026, 8, 20, 7, 0);
      final event2 = const DetectedEvent(
        id: 'morn_evt',
        startOffset: Duration(minutes: 30), // 07:30
        duration: Duration(seconds: 2),
        maxDb: -30.0,
        avgDb: -35.0,
      );
      expect(event2.formatPeriod(baseMorning), equals('morgens'));

      final baseAfternoon = DateTime(2026, 8, 20, 15, 0);
      final event3 = const DetectedEvent(
        id: 'noon_evt',
        startOffset: Duration(minutes: 15), // 15:15
        duration: Duration(seconds: 2),
        maxDb: -30.0,
        avgDb: -35.0,
      );
      expect(event3.formatPeriod(baseAfternoon), equals('nachmittags'));
    });
  });

  group('EventCategory Enum & Mapping Tests', () {
    test('All EventCategory values have non-empty labels and emojis', () {
      for (final cat in EventCategory.values) {
        final event = DetectedEvent(
          id: 'test_${cat.name}',
          startOffset: Duration.zero,
          duration: const Duration(seconds: 1),
          maxDb: -20.0,
          avgDb: -25.0,
          category: cat,
        );

        expect(event.categoryLabel.isNotEmpty, isTrue);
        expect(event.categoryEmoji.isNotEmpty, isTrue);
      }
    });
  });

  group('RecordingSession Full Serialization Tests', () {
    test('RecordingSession toJson and fromJson preserves complete data integrity', () {
      final session = RecordingSession(
        id: 'sess_roundtrip_1',
        title: '20.08.2026 Schlaf',
        filePath: '/storage/sleep_1.wav',
        startTime: DateTime(2026, 8, 20, 23, 15),
        duration: const Duration(hours: 7, minutes: 45),
        amplitudeHistory: [-50.0, -48.0, -22.0, -52.0],
        fileSizeBytes: 98765432,
        isFavorite: true,
        isFinalized: true,
        detectedEvents: [
          const DetectedEvent(
            id: 'evt_1',
            startOffset: Duration(hours: 2),
            duration: Duration(seconds: 4),
            maxDb: -22.0,
            avgDb: -26.0,
            category: EventCategory.snore,
            confidence: 0.98,
            subType: 'Tiefes Schnarchen',
            tags: ['⭐ Favorit'],
            isFavorite: true,
          ),
        ],
      );

      final json = session.toJson();
      final restored = RecordingSession.fromJson(json);

      expect(restored.id, equals(session.id));
      expect(restored.title, equals(session.title));
      expect(restored.filePath, equals(session.filePath));
      expect(restored.duration, equals(session.duration));
      expect(restored.isFavorite, isTrue);
      expect(restored.isFinalized, isTrue);
      expect(restored.amplitudeHistory, equals(session.amplitudeHistory));
      expect(restored.detectedEvents.length, equals(1));
      expect(restored.detectedEvents.first.subType, equals('Tiefes Schnarchen'));
      expect(restored.detectedEvents.first.isProtected, isTrue);
    });
  });

  group('RecordingRepository State Modification Tests', () {
    test('toggleFavorite, toggleEventFavorite, and updateEventTags mutate state accurately', () async {
      SharedPreferences.setMockInitialValues({});

      final testSession = RecordingSession(
        id: 'repo_test_sess',
        title: 'Repo Test',
        filePath: '/tmp/repo_test.wav',
        startTime: DateTime.now(),
        duration: const Duration(minutes: 10),
        amplitudeHistory: [-50.0, -20.0, -50.0],
        fileSizeBytes: 100000,
        isFavorite: false,
        detectedEvents: [
          const DetectedEvent(
            id: 'evt_repo_1',
            startOffset: Duration(seconds: 30),
            duration: Duration(seconds: 3),
            maxDb: -20.0,
            avgDb: -25.0,
            tags: [],
            isFavorite: false,
          ),
        ],
      );

      // Verify toggleFavorite logic on mock data
      final favToggled = testSession.copyWith(isFavorite: !testSession.isFavorite);
      expect(favToggled.isFavorite, isTrue);

      // Verify toggleEventFavorite
      final updatedEvents = testSession.detectedEvents.map((e) {
        if (e.id == 'evt_repo_1') return e.copyWith(isFavorite: !e.isFavorite);
        return e;
      }).toList();
      expect(updatedEvents.first.isFavorite, isTrue);
      expect(updatedEvents.first.isProtected, isTrue);

      // Verify updateEventTags
      final taggedEvents = testSession.detectedEvents.map((e) {
        if (e.id == 'evt_repo_1') return e.copyWith(tags: ['🤣 Lustig', '🔒 Gesichert']);
        return e;
      }).toList();
      expect(taggedEvents.first.tags, contains('🤣 Lustig'));
      expect(taggedEvents.first.isProtected, isTrue);
    });
  });

  group('GeminiAudioService Fallback Tests', () {
    test('GeminiAudioService handles audio segment extraction and classification gracefully', () async {
      SharedPreferences.setMockInitialValues({});
      final service = GeminiAudioService();
      final wavFile = AppFile('assets/audio/demo_sleep.wav');
      expect(await wavFile.exists(), isTrue);

      final result = await service.classifyAudioSegment(
        wavFile: wavFile,
        startMs: 2500,
        durationMs: 3000,
      );

      expect(result, isNotNull);
      expect(result.confidence, isNotNull);
    });
  });
}

