import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../domain/models/detected_event.dart';
import '../../domain/models/recording_session.dart';
import 'audio_trimmer_service.dart';
import 'gemini_audio_service.dart';
import 'logger_service.dart';
import 'notification_service.dart';
import 'platform_file/platform_file.dart';
import 'wav_analyzer_service.dart';

class StorageService {
  final LoggerService _logger = LoggerService();
  final WavAnalyzerService _wavAnalyzer = WavAnalyzerService();
  final GeminiAudioService _geminiService = GeminiAudioService();
  final AudioTrimmerService _audioTrimmer = AudioTrimmerService();
  final NotificationService _notificationService = NotificationService();

  WavAnalyzerService get wavAnalyzer => _wavAnalyzer;

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

  Future<AppDirectory?> get _favoritesDir async {
    if (kIsWeb) return null;
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = AppDirectory(p.join(docsDir.path, 'sleep_favorites'));
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

  /// Extracts a favorite clip into an independent, compact M4A file in sleep_favorites/
  /// so it stays preserved and playable even if the original full-night WAV is deleted.
  Future<String?> extractAndSaveFavoriteClip(RecordingSession session, DetectedEvent event) async {
    if (kIsWeb) return null;
    if (event.standaloneAudioPath != null && await AppFile(event.standaloneAudioPath!).exists()) {
      return event.standaloneAudioPath;
    }

    final sessionAudioFile = AppFile(session.filePath);
    if (!await sessionAudioFile.exists()) return null;

    final favDir = await _favoritesDir;
    if (favDir == null) return null;

    final outPath = p.join(favDir.path, 'fav_${session.id}_${event.id}.m4a');
    final outFile = AppFile(outPath);

    try {
      final savedFile = await _audioTrimmer.trimAudioSnippet(
        inputFile: sessionAudioFile,
        outputFile: outFile,
        startOffset: event.startOffset,
        duration: event.duration,
      );
      if (await savedFile.exists()) {
        return savedFile.path;
      }
    } catch (e) {
      _logger.log('Error extracting favorite clip ${event.id}: $e');
    }
    return null;
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
          final audioExists = await audioFile.exists();
          if (audioExists) {
            final bytes = await audioFile.length();

            // If audio file has no real data and session was interrupted, clean it up
            if (bytes <= 44 && !session.isFinalized) {
              _logger.log('Cleaning up empty interrupted session ${session.id} ($bytes bytes)...');
              try { await audioFile.delete(); } catch (_) {}
              try { await entity.delete(); } catch (_) {}
              continue;
            }

            // WAV 16kHz 16bit mono = 32000 bytes per second
            final seconds = (bytes - 44) > 0 ? ((bytes - 44) / 32000).round() : 0;
            final actualDuration = Duration(seconds: seconds);

            // Only process unfinalized sessions that were interrupted by a crash/reboot
            if (!session.isFinalized) {
              _logger.log('Finalizing crashed/interrupted session ${session.id} ($bytes bytes)...');
              final analysis = await _wavAnalyzer.analyzeWavFile(audioFile, thresholdDb: session.getAdaptiveThresholdDb());

              session = session.copyWith(
                duration: actualDuration,
                isFinalized: true,
                fileSizeBytes: bytes,
                amplitudeHistory: analysis.waveformHistory.isNotEmpty ? analysis.waveformHistory : session.amplitudeHistory,
                detectedEvents: analysis.detectedEvents.isNotEmpty ? analysis.detectedEvents : session.detectedEvents,
              );

              await saveSessionMetadata(session);
              _logger.log('Finalized session ${session.id} with ${session.detectedEvents.length} detected noise events.');
            }
          } else if (!session.isFinalized) {
            // Audio file was never created, clean up orphan metadata
            _logger.log('Deleting orphan unfinalized session ${session.id} (audio file missing)');
            try { await entity.delete(); } catch (_) {}
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

  Future<void> deleteSession(RecordingSession session, {bool keepFavorites = true}) async {
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

    final hasFavorites = session.detectedEvents.any((e) => e.isFavorite);

    if (keepFavorites && hasFavorites) {
      // 1. Ensure all favorite clips are safely extracted into standalone files
      final List<DetectedEvent> updatedEvents = [];
      for (final event in session.detectedEvents) {
        if (event.isFavorite) {
          final standalonePath = await extractAndSaveFavoriteClip(session, event);
          updatedEvents.add(event.copyWith(standaloneAudioPath: standalonePath));
        }
      }

      // 2. Delete the huge multi-hundred megabyte raw audio file
      final audioFile = AppFile(session.filePath);
      if (await audioFile.exists()) {
        await audioFile.delete();
      }

      // 3. Keep the lightweight metadata record holding the standalone favorite clips
      final preservedSession = session.copyWith(
        filePath: '', // Raw full-night audio deleted
        detectedEvents: updatedEvents,
      );
      await saveSessionMetadata(preservedSession);
      _logger.log('Session ${session.id} raw audio deleted; safely preserved ${updatedEvents.length} favorite clips.');
      return;
    }

    // No favorites to preserve: completely remove metadata and raw audio
    final dir = await _recordingsDir;
    if (dir != null) {
      final jsonFile = AppFile(p.join(dir.path, '${session.id}.json'));
      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }
    }

    final audioFile = AppFile(session.filePath);
    if (await audioFile.exists()) {
      await audioFile.delete();
    }
  }

  /// Retention policy: Auto-deletes recordings older than retentionDays
  /// Safely preserves favorite clips by deleting only the huge raw audio file!
  Future<int> runRetentionCleanup({int retentionDays = 7}) async {
    final sessions = await loadAllSessions();
    final cutoffDate = DateTime.now().subtract(Duration(days: retentionDays));
    int cleanedCount = 0;

    for (final session in sessions) {
      if (session.startTime.isBefore(cutoffDate) && !session.isFavorite) {
        final hasFavorites = session.detectedEvents.any((e) => e.isFavorite);
        if (hasFavorites) {
          final audioFile = AppFile(session.filePath);
          if (await audioFile.exists()) {
            await deleteSession(session, keepFavorites: true);
            cleanedCount++;
          }
        } else {
          await deleteSession(session, keepFavorites: false);
          cleanedCount++;
        }
      }
    }
    return cleanedCount;
  }

  /// Creates a single .zip archive containing all .wav and .json files with real-time progress
  Future<String?> createBackupZip({void Function(double progress, String status)? onProgress}) async {
    if (kIsWeb) return null;
    final recDir = await _recordingsDir;
    if (recDir == null) return null;

    final jsonFiles = recDir.listJsonFiles();
    if (jsonFiles.isEmpty) return null;

    onProgress?.call(0.05, 'Vorbereiten der Dateien...');

    final archive = Archive();
    final totalFiles = jsonFiles.length;

    for (int i = 0; i < jsonFiles.length; i++) {
      final jf = jsonFiles[i];
      try {
        final currentFileNum = i + 1;
        final progressRatio = 0.1 + (0.7 * (i / totalFiles));
        onProgress?.call(progressRatio, 'Packe Aufnahme $currentFileNum von $totalFiles...');

        final jsonBytes = await jf.readAsBytes();
        final jsonFileName = p.basename(jf.path);
        archive.addFile(ArchiveFile(jsonFileName, jsonBytes.length, jsonBytes));

        final jsonString = await jf.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        final wavOriginalPath = jsonMap['filePath'] as String?;

        if (wavOriginalPath != null) {
          final wavFile = AppFile(wavOriginalPath);
          if (await wavFile.exists()) {
            final wavBytes = await wavFile.readAsBytes();
            final wavFileName = p.basename(wavOriginalPath);
            archive.addFile(ArchiveFile(wavFileName, wavBytes.length, wavBytes));
          }
        }
      } catch (e) {
        _logger.log('Error packing file ${jf.path}: $e');
      }
    }

    if (archive.isEmpty) return null;

    onProgress?.call(0.85, 'ZIP-Archiv wird komprimiert...');
    final zipData = ZipEncoder().encode(archive);
    if (zipData.isEmpty) return null;

    onProgress?.call(0.95, 'Backup-Datei wird geschrieben...');
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final zipPath = p.join(tempDir.path, 'SleepSpeak_Backup_$timestamp.zip');
    final zipFile = AppFile(zipPath);
    await zipFile.writeAsBytes(zipData);
    onProgress?.call(1.0, 'Fertig!');
    _logger.log('Created backup zip: $zipPath with ${archive.length} files');
    return zipPath;
  }

  /// Runs AI classification on all events of a session using Oracle Server or Gemini
  Future<RecordingSession> classifySessionWithAI(
    RecordingSession session, {
    void Function(double progress, String status)? onProgress,
  }) async {
    if (kIsWeb || session.detectedEvents.isEmpty) return session;

    final wavFile = AppFile(session.filePath);
    if (!await wavFile.exists()) return session;

    final List<DetectedEvent> updatedEvents = [];
    final int total = session.detectedEvents.length;

    final provider = await _geminiService.getProvider();
    final providerName = provider == AiProvider.oracle ? 'Oracle Server' : 'Google Gemini';
    onProgress?.call(0.05, 'Initialisiere $providerName...');

    // Start background Foreground Service & acquire WakeLock so analysis never stops when minimized
    await _notificationService.startAiAnalysisNotification(
      title: '🤖 KI-Geräuschanalyse läuft (0%)',
      content: '0 von $total Clips ($providerName)',
      progress: 0,
      maxProgress: total,
    );
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    try {
      const int batchSize = 5;
      for (int i = 0; i < total; i += batchSize) {
        final int end = (i + batchSize < total) ? i + batchSize : total;
        final batchEvents = session.detectedEvents.sublist(i, end);

        final percent = ((i / total) * 100).toInt();
        try {
          onProgress?.call(
            0.05 + (0.90 * (i / total)),
            'Analysiere Geräusche ${i + 1} bis $end von $total ($providerName)...',
          );
        } catch (_) {}

        // Update Android notification drawer in real-time
        await _notificationService.updateAiAnalysisNotification(
          title: '🤖 KI-Geräuschanalyse ($percent%)',
          content: 'Clip ${i + 1} bis $end von $total ($providerName)',
          progress: i,
          maxProgress: total,
        );

        try {
          final batchResults = await _geminiService.classifyAudioSegmentsBatch(
            wavFile: wavFile,
            events: batchEvents,
            onStatusUpdate: (status) {
              try {
                onProgress?.call(0.05 + (0.90 * (i / total)), status);
              } catch (_) {}
            },
          );

          for (int j = 0; j < batchEvents.length; j++) {
            final ev = batchEvents[j];
            if (j < batchResults.length) {
              final geminiRes = batchResults[j];
              updatedEvents.add(ev.copyWith(
                category: geminiRes.category,
                confidence: geminiRes.confidence,
                transcription: geminiRes.transcription,
                subType: geminiRes.subType,
                explanation: geminiRes.explanation,
                dynamicEmoji: geminiRes.dynamicEmoji,
              ));
            } else {
              updatedEvents.add(ev);
            }
          }
        } catch (e, stack) {
          _logger.log('KI Batch Error for events $i to $end: $e\n$stack');
          debugPrint('KI Batch Error: $e\n$stack');
          updatedEvents.addAll(batchEvents);
        }
      }

      try {
        onProgress?.call(1.0, 'KI-Analyse abgeschlossen ($providerName)!');
      } catch (_) {}
      final updatedSession = session.copyWith(detectedEvents: updatedEvents);
      await saveSessionMetadata(updatedSession);
      _logger.log('Classified and saved session ${session.id} with ${updatedEvents.length} events via $providerName');
      return updatedSession;
    } finally {
      // Release notification & wakelock cleanly
      await _notificationService.stopAiAnalysisNotification(
        completionTitle: '✨ KI-Analyse abgeschlossen!',
        completionContent: '$total Clips mit $providerName erfolgreich analysiert.',
      );
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }
  }

  /// Restores all recordings from a .zip backup archive
  Future<int> restoreBackupZip(String zipPath) async {
    if (kIsWeb) return 0;
    final zipFile = AppFile(zipPath);
    if (!await zipFile.exists()) return 0;

    final recDir = await _recordingsDir;
    if (recDir == null) return 0;

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    int restoredCount = 0;

    for (final file in archive) {
      if (file.isFile) {
        final filename = p.basename(file.name);
        final targetPath = p.join(recDir.path, filename);
        final targetFile = AppFile(targetPath);
        await targetFile.writeAsBytes(file.content as List<int>);
      }
    }

    // Update filePath in every restored JSON to match local device directory
    final jsonFiles = recDir.listJsonFiles();
    for (final jf in jsonFiles) {
      try {
        final jsonString = await jf.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        final sessionId = jsonMap['id'] as String? ?? p.basenameWithoutExtension(jf.path);
        final localWavPath = p.join(recDir.path, '$sessionId.wav');
        final wavFile = AppFile(localWavPath);

        if (await wavFile.exists()) {
          jsonMap['filePath'] = localWavPath;
          await jf.writeAsString(jsonEncode(jsonMap), flush: true);
          restoredCount++;
        }
      } catch (_) {}
    }

    await recoverUnfinalizedSessions();
    _logger.log('Restored $restoredCount sessions from $zipPath');
    return restoredCount;
  }

  /// Returns all available audio and metadata files for backup
  Future<List<String>> getAllBackupFilePaths() async {
    if (kIsWeb) return [];
    final dir = await _recordingsDir;
    if (dir == null) return [];

    final List<String> paths = [];
    final jsonFiles = dir.listJsonFiles();
    for (final jf in jsonFiles) {
      if (!paths.contains(jf.path)) {
        paths.add(jf.path);
      }
      try {
        final jsonString = await jf.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        final wavOriginalPath = jsonMap['filePath'] as String?;
        if (wavOriginalPath != null) {
          final wavFile = AppFile(wavOriginalPath);
          if (await wavFile.exists() && !paths.contains(wavOriginalPath)) {
            paths.add(wavOriginalPath);
          }
        }
      } catch (_) {}
    }
    return paths;
  }

  /// Imports an external WAV audio file or .zip backup into the app with automatic analysis
  Future<RecordingSession?> importAudioFile(String pickedFilePath, {String? customTitle}) async {
    if (kIsWeb) return null;

    final sourceFile = AppFile(pickedFilePath);
    if (!await sourceFile.exists()) return null;

    // If a ZIP backup was picked, extract and restore all sessions
    if (pickedFilePath.toLowerCase().endsWith('.zip')) {
      final restored = await restoreBackupZip(pickedFilePath);
      if (restored > 0) {
        final all = await loadAllSessions();
        return all.isNotEmpty ? all.first : null;
      }
      return null;
    }

    final sizeBytes = await sourceFile.length();
    if (sizeBytes <= 44) return null;

    final sessionId = 'session_imported_${DateTime.now().millisecondsSinceEpoch}';
    final targetAudioPath = await generateAudioFilePath(sessionId);
    final targetFile = AppFile(targetAudioPath);

    // Copy source audio into app storage
    await sourceFile.copy(targetAudioPath);

    // Analyze WAV
    final analysis = await _wavAnalyzer.analyzeWavFile(targetFile, thresholdDb: -38.0);
    final seconds = (sizeBytes - 44) > 0 ? ((sizeBytes - 44) / 32000).round() : 0;
    final duration = Duration(seconds: seconds);

    final title = customTitle ?? 'Importierte Aufnahme (${DateFormat('dd.MM.yyyy - HH:mm').format(DateTime.now())})';

    final session = RecordingSession(
      id: sessionId,
      title: title,
      filePath: targetAudioPath,
      startTime: DateTime.now(),
      duration: duration,
      amplitudeHistory: analysis.waveformHistory,
      isFavorite: true,
      isFinalized: true,
      fileSizeBytes: sizeBytes,
      detectedEvents: analysis.detectedEvents,
    );

    await saveSessionMetadata(session);
    _logger.log('Successfully imported external recording: $sessionId ($sizeBytes bytes, ${analysis.detectedEvents.length} events)');
    return session;
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
