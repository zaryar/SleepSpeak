import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../domain/models/recording_session.dart';
import 'logger_service.dart';
import 'wav_analyzer_service.dart';

class StorageService {
  final LoggerService _logger = LoggerService();
  final WavAnalyzerService _wavAnalyzer = WavAnalyzerService();

  Future<Directory> get _recordingsDir async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'sleep_recordings'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get _snippetsDir async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'sleep_snippets'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> generateAudioFilePath(String sessionId) async {
    final dir = await _recordingsDir;
    return p.join(dir.path, '$sessionId.wav');
  }

  Future<String> generateSnippetFilePath(String snippetId) async {
    final dir = await _snippetsDir;
    return p.join(dir.path, 'snippet_$snippetId.m4a');
  }

  Future<void> saveSessionMetadata(RecordingSession session) async {
    final dir = await _recordingsDir;
    final jsonFile = File(p.join(dir.path, '${session.id}.json'));
    await jsonFile.writeAsString(jsonEncode(session.toJson()), flush: true);
  }

  /// Crash recovery: Scans for unfinalized sessions or interrupted WAV files and restores them
  Future<void> recoverUnfinalizedSessions() async {
    try {
      final dir = await _recordingsDir;
      final files = dir.listSync();

      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final jsonString = await entity.readAsString();
            final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
            var session = RecordingSession.fromJson(jsonMap);

            final audioFile = File(session.filePath);
            if (await audioFile.exists()) {
              final bytes = await audioFile.length();
              // WAV 16kHz 16bit mono = 32000 bytes per second
              final seconds = (bytes - 44) > 0 ? ((bytes - 44) / 32000).round() : 0;
              final actualDuration = Duration(seconds: seconds);

              // If unfinalized or if amplitudeHistory is sparse (e.g. Doze mode froze live sampling), extract from WAV file
              final expectedSamples = (seconds * 5); // 5 samples per sec (200ms)
              if (!session.isFinalized || session.amplitudeHistory.length < expectedSamples * 0.5) {
                _logger.log('Analyzing WAV file on disk for session ${session.id} ($bytes bytes)...');
                final extractedHistory = await _wavAnalyzer.extractAmplitudeHistory(audioFile);

                session = session.copyWith(
                  duration: actualDuration,
                  isFinalized: true,
                  fileSizeBytes: bytes,
                  amplitudeHistory: extractedHistory.isNotEmpty ? extractedHistory : session.amplitudeHistory,
                );

                final events = session.recalculateEvents(-38.0);
                session = session.copyWith(detectedEvents: events);

                await saveSessionMetadata(session);
                _logger.log('Finalized session ${session.id} with ${session.detectedEvents.length} detected noise events.');
              }
            }
          } catch (e) {
            _logger.log('Recovery error for ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      _logger.log('General crash recovery error: $e');
    }
  }

  Future<List<RecordingSession>> loadAllSessions() async {
    await recoverUnfinalizedSessions();

    final dir = await _recordingsDir;
    final List<RecordingSession> sessions = [];

    final files = dir.listSync();
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final jsonString = await entity.readAsString();
          final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
          final session = RecordingSession.fromJson(jsonMap);

          // Ensure actual audio file exists and has size
          final audioFile = File(session.filePath);
          if (await audioFile.exists() && (await audioFile.length()) > 0) {
            sessions.add(session);
          }
        } catch (e) {
          // Ignore corrupt metadata
        }
      }
    }

    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    return sessions;
  }

  Future<void> deleteSession(RecordingSession session) async {
    final dir = await _recordingsDir;
    final jsonFile = File(p.join(dir.path, '${session.id}.json'));
    if (await jsonFile.exists()) {
      await jsonFile.delete();
    }

    final audioFile = File(session.filePath);
    if (await audioFile.exists()) {
      await audioFile.delete();
    }
  }

  /// Retention policy: Auto-deletes non-starred recordings older than retentionDays
  Future<int> runRetentionCleanup({int retentionDays = 7}) async {
    final sessions = await loadAllSessions();
    final cutoffDate = DateTime.now().subtract(Duration(days: retentionDays));
    int deletedCount = 0;

    for (final session in sessions) {
      if (!session.isFavorite && session.startTime.isBefore(cutoffDate)) {
        await deleteSession(session);
        deletedCount++;
      }
    }
    return deletedCount;
  }
}
