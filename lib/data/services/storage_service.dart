import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/recording_session.dart';
import 'logger_service.dart';
import 'platform_file/platform_file.dart';
import 'wav_analyzer_service.dart';

class StorageService {
  final LoggerService _logger = LoggerService();
  final WavAnalyzerService _wavAnalyzer = WavAnalyzerService();

  static const String _webStorageKey = 'sleep_sessions_web_storage';

  Future<AppDirectory?> get _recordingsDir async {
    if (kIsWeb) return null;
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = AppDirectory(p.join(docsDir.path, 'sleep_recordings'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<AppDirectory?> get _snippetsDir async {
    if (kIsWeb) return null;
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = AppDirectory(p.join(docsDir.path, 'sleep_snippets'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> generateAudioFilePath(String sessionId) async {
    if (kIsWeb) return 'web_memory://$sessionId.wav';
    final dir = await _recordingsDir;
    return p.join(dir?.path ?? '', '$sessionId.wav');
  }

  Future<String> generateSnippetFilePath(String snippetId) async {
    if (kIsWeb) return 'web_memory://snippet_$snippetId.m4a';
    final dir = await _snippetsDir;
    return p.join(dir?.path ?? '', 'snippet_$snippetId.m4a');
  }

  Future<void> saveSessionMetadata(RecordingSession session) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final currentList = prefs.getStringList(_webStorageKey) ?? [];
      final encoded = jsonEncode(session.toJson());
      
      final index = currentList.indexWhere((item) {
        try {
          final m = jsonDecode(item) as Map<String, dynamic>;
          return m['id'] == session.id;
        } catch (_) {
          return false;
        }
      });

      if (index != -1) {
        currentList[index] = encoded;
      } else {
        currentList.insert(0, encoded);
      }
      await prefs.setStringList(_webStorageKey, currentList);
      return;
    }

    final dir = await _recordingsDir;
    final jsonFile = AppFile(p.join(dir!.path, '${session.id}.json'));
    await jsonFile.writeAsString(jsonEncode(session.toJson()), flush: true);
  }

  /// Crash recovery: Scans for unfinalized sessions or interrupted WAV files and restores them
  Future<void> recoverUnfinalizedSessions() async {
    if (kIsWeb) return;

    try {
      final dir = await _recordingsDir;
      if (dir == null) return;
      final files = dir.listJsonFiles();

      for (final entity in files) {
        try {
          final jsonString = await entity.readAsString();
          final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
          var session = RecordingSession.fromJson(jsonMap);

          final audioFile = AppFile(session.filePath);
          if (await audioFile.exists()) {
            final bytes = await audioFile.length();
            // WAV 16kHz 16bit mono = 32000 bytes per second
            final seconds = (bytes - 44) > 0 ? ((bytes - 44) / 32000).round() : 0;
            final actualDuration = Duration(seconds: seconds);

            // If unfinalized or if amplitudeHistory is sparse, extract from WAV file
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
    } catch (e) {
      _logger.log('General crash recovery error: $e');
    }
  }

  Future<List<RecordingSession>> loadAllSessions() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final storedList = prefs.getStringList(_webStorageKey);
      
      // If first time opening in web, create rich realistic demo sessions
      if (storedList == null || storedList.isEmpty) {
        final demoSessions = _createWebDemoSessions();
        final encodedList = demoSessions.map((s) => jsonEncode(s.toJson())).toList();
        await prefs.setStringList(_webStorageKey, encodedList);
        return demoSessions;
      }

      final List<RecordingSession> sessions = [];
      for (final item in storedList) {
        try {
          final jsonMap = jsonDecode(item) as Map<String, dynamic>;
          sessions.add(RecordingSession.fromJson(jsonMap));
        } catch (_) {}
      }
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      return sessions;
    }

    await recoverUnfinalizedSessions();

    final dir = await _recordingsDir;
    final List<RecordingSession> sessions = [];
    if (dir == null) return sessions;

    final files = dir.listJsonFiles();
    for (final entity in files) {
      try {
        final jsonString = await entity.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        final session = RecordingSession.fromJson(jsonMap);

        // Ensure actual audio file exists and has size
        final audioFile = AppFile(session.filePath);
        if (await audioFile.exists() && (await audioFile.length()) > 0) {
          sessions.add(session);
        }
      } catch (e) {
        // Ignore corrupt metadata
      }
    }

    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    return sessions;
  }

  Future<void> deleteSession(RecordingSession session) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final currentList = prefs.getStringList(_webStorageKey) ?? [];
      currentList.removeWhere((item) {
        try {
          final m = jsonDecode(item) as Map<String, dynamic>;
          return m['id'] == session.id;
        } catch (_) {
          return false;
        }
      });
      await prefs.setStringList(_webStorageKey, currentList);
      return;
    }

    final dir = await _recordingsDir;
    if (dir == null) return;
    final jsonFile = AppFile(p.join(dir.path, '${session.id}.json'));
    if (await jsonFile.exists()) {
      await jsonFile.delete();
    }

    final audioFile = AppFile(session.filePath);
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

  /// Generates realistic interactive demo sleep sessions for web visitors
  List<RecordingSession> _createWebDemoSessions() {
    final rand = Random(42);

    List<double> generateNightAmplitudes(int minutes, List<int> spikeMinuteIndices) {
      final samplesCount = minutes * 60 * 5; // 5 samples per sec
      final result = List<double>.filled(samplesCount, -52.0);
      
      for (int i = 0; i < samplesCount; i++) {
        result[i] = -52.0 + (rand.nextDouble() * 6.0 - 3.0);
      }

      for (final spikeMin in spikeMinuteIndices) {
        final centerIdx = spikeMin * 60 * 5;
        final spikeLen = (3 + rand.nextInt(5)) * 5; // 3-8 seconds
        final peakDb = -18.0 - rand.nextDouble() * 14.0; // -18 dB to -32 dB
        
        for (int k = 0; k < spikeLen && (centerIdx + k) < samplesCount; k++) {
          result[centerIdx + k] = peakDb + (rand.nextDouble() * 4.0 - 2.0);
        }
      }
      return result;
    }

    final time1 = DateTime.now().subtract(const Duration(days: 1, hours: 8));
    final amp1 = generateNightAmplitudes(435, [45, 112, 190, 260, 315, 390]);
    var session1 = RecordingSession(
      id: 'demo_session_1',
      title: 'Schlaf vom gestern Nacht (Demo)',
      filePath: 'web_memory://demo_1.wav',
      startTime: time1,
      duration: const Duration(hours: 7, minutes: 15),
      amplitudeHistory: amp1,
      isFavorite: true,
      isFinalized: true,
      fileSizeBytes: 835200000,
      detectedEvents: [],
    );
    session1 = session1.copyWith(detectedEvents: session1.recalculateEvents(-38.0));

    final time2 = DateTime.now().subtract(const Duration(days: 2, hours: 8, minutes: 30));
    final amp2 = generateNightAmplitudes(400, [75, 210, 340]);
    var session2 = RecordingSession(
      id: 'demo_session_2',
      title: 'Schlaf vom Vorgestern (Demo)',
      filePath: 'web_memory://demo_2.wav',
      startTime: time2,
      duration: const Duration(hours: 6, minutes: 40),
      amplitudeHistory: amp2,
      isFavorite: false,
      isFinalized: true,
      fileSizeBytes: 768000000,
      detectedEvents: [],
    );
    session2 = session2.copyWith(detectedEvents: session2.recalculateEvents(-38.0));

    return [session1, session2];
  }
}
