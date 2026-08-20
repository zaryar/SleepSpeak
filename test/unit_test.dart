import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_recorder/data/services/gemini_audio_service.dart';
import 'package:sleep_recorder/data/services/platform_file/platform_file.dart';
import 'package:sleep_recorder/domain/models/detected_event.dart';
import 'package:sleep_recorder/domain/models/recording_session.dart';

void main() {
  group('RecordingSession Peak Detection Tests', () {
    test('recalculateEvents merges peaks within 5 seconds into one event', () {
      // 10 seconds recording with peaks close together (< 5 sec gap)
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
        startTime: DateTime.now(),
        duration: const Duration(seconds: 10),
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: 160000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);

      // Should be merged into 1 single event because gap is <= 5 sec
      expect(events.length, equals(1));
      expect(events[0].maxDb, equals(-20.0));
    });

    test('recalculateEvents keeps peaks separate if more than 5 seconds apart', () {
      // 30 seconds recording with peaks 15 seconds apart
      final List<double> history = List.filled(60, -55.0);
      history[5] = -20.0;
      history[6] = -22.0;

      history[40] = -25.0;
      history[41] = -24.0;

      final session = RecordingSession(
        id: 'test_session_2',
        title: 'Test Session 2',
        filePath: '/tmp/test2.wav',
        startTime: DateTime.now(),
        duration: const Duration(seconds: 30),
        amplitudeHistory: history,
        fileSizeBytes: 300000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);
      expect(events.length, equals(2));
    });

    test('recalculateEvents ignores background noise below threshold', () {
      final amplitudeHistory = List.filled(50, -50.0);
      final session = RecordingSession(
        id: 'quiet_session',
        title: 'Quiet Night',
        filePath: '/tmp/quiet.wav',
        startTime: DateTime.now(),
        duration: const Duration(minutes: 5),
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: 800000,
        detectedEvents: [],
      );

      final events = session.recalculateEvents(-35.0);
      expect(events, isEmpty);
    });

    test('DetectedEvent serialization preserves category and confidence', () {
      const event = DetectedEvent(
        id: 'evt_speech_1',
        startOffset: Duration(seconds: 12),
        duration: Duration(seconds: 3),
        maxDb: -22.5,
        avgDb: -28.0,
        category: EventCategory.speech,
        confidence: 0.94,
        transcription: 'Test phrase',
        subType: 'Flüstern',
        explanation: 'Deutliches Flüstern im Schlafzimmer.',
        dynamicEmoji: '🗣️',
        tags: ['⭐ Favorit', '🤣 Lustig'],
        isFavorite: true,
      );

      final json = event.toJson();
      expect(json['category'], equals('speech'));
      expect(json['confidence'], equals(0.94));
      expect(json['transcription'], equals('Test phrase'));
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
      expect(restored.transcription, equals('Test phrase'));
      expect(restored.tags, equals(['⭐ Favorit', '🤣 Lustig']));
      expect(restored.isFavorite, isTrue);
      expect(restored.isProtected, isTrue);
    });

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

    test('RecordingSession accurately estimates noise floor and measures position noise', () {
      final List<double> history = [
        -45.0, -44.5, -45.2, -44.8, // Ambient noise around -45dB
        -45.0, -44.9, -45.1, -44.7,
        -20.0, -18.0, -22.0,        // Loud snoring at index 8-10 (4s)
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

      // At position 0.5s, it is ambient noise
      final noiseAtQuiet = session.measureNoiseAtTime(const Duration(milliseconds: 500));
      expect(noiseAtQuiet, inInclusiveRange(-46.0, -44.0));

      // At position 4.5s (loud snoring), measureNoiseAtTime returns the max peak (-18.0 dB)
      final noiseAtSnore = session.measureNoiseAtTime(const Duration(milliseconds: 4500));
      expect(noiseAtSnore, equals(-18.0));
    });
  });
}
