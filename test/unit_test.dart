import 'package:flutter_test/flutter_test.dart';
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
  });
}
