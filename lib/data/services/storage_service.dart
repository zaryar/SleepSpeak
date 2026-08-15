import 'dart:convert';
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

  static const String _webStorageKey = 'sleep_sessions_web_storage_v2';

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
    // 10-second real playable audio session (assets/audio/demo_sleep.wav)
    // 50 samples (200ms per sample for 10s duration)
    final List<double> amp10s = [
      -50.5, -51.2, -50.8, -50.6, -51.0, -50.9, -51.1, -50.7, -50.9, -51.0, // 0-2s quiet background
      -50.8, -50.7, -51.0, -50.9, -51.2,                                    // 2-3s quiet background
      -38.0, -32.5, -26.4, -22.1, -20.5, -19.8, -20.2, -21.5, -23.8, -27.2, // 3-5s SLEEP TALKING SPIKE
      -31.0, -35.2, -37.8,                                                 // 5-5.6s fading
      -50.6, -51.0, -50.8, -50.9, -51.1, -50.7, -50.9, -51.0, -50.8,        // 5.6-7.4s quiet
      -36.2, -31.4, -30.8, -32.5, -36.0,                                    // 7.4-8.4s MURMUR SPIKE
      -50.8, -51.2, -50.9, -51.0, -50.8, -51.1, -50.9, -51.0               // 8.4-10.0s quiet
    ];

    final time1 = DateTime.now().subtract(const Duration(minutes: 45));
    var session1 = RecordingSession(
      id: 'demo_session_playable',
      title: '🔊 10s Demo-Aufnahme (Hörbar & Interaktiv)',
      filePath: 'assets/audio/demo_sleep.wav',
      startTime: time1,
      duration: const Duration(seconds: 10),
      amplitudeHistory: amp10s,
      isFavorite: true,
      isFinalized: true,
      fileSizeBytes: 320044,
      detectedEvents: [],
    );
    session1 = session1.copyWith(detectedEvents: session1.recalculateEvents(-38.0));

    return [session1];
  }
}

