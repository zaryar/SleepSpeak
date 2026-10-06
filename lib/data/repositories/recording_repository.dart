import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../../domain/models/detected_event.dart';
import '../../domain/models/recording_session.dart';
import '../services/platform_file/platform_file.dart';
import '../services/storage_service.dart';

class FavoriteClipItem {
  final RecordingSession session;
  final DetectedEvent event;

  const FavoriteClipItem({required this.session, required this.event});
}

class RecordingRepository extends ChangeNotifier {
  final StorageService _storageService = StorageService();
  StorageService get storageService => _storageService;

  List<RecordingSession> _sessions = [];
  List<RecordingSession> get sessions => List.unmodifiable(_sessions.where((s) => s.filePath.isNotEmpty));
  List<RecordingSession> get allSessionsIncludingArchived => List.unmodifiable(_sessions);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  final double _defaultNoiseThresholdDb = -38.0;
  double get defaultNoiseThresholdDb => _defaultNoiseThresholdDb;

  RecordingSession? _activeOngoingSession;

  Future<void> loadSessions() async {
    _isLoading = true;
    notifyListeners();

    try {
      // Run automatic 7-day retention cleanup on launch & crash recovery
      await _storageService.runRetentionCleanup(retentionDays: 7);
      _sessions = await _storageService.loadAllSessions();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<RecordingSession> createOngoingSession({
    required String audioFilePath,
    required DateTime startTime,
  }) async {
    final sessionId = 'session_${startTime.millisecondsSinceEpoch}';
    final dateStr = DateFormat('dd.MM.yyyy - HH:mm').format(startTime);
    final title = 'Schlaf vom $dateStr Uhr';

    final session = RecordingSession(
      id: sessionId,
      title: title,
      filePath: audioFilePath,
      startTime: startTime,
      duration: Duration.zero,
      amplitudeHistory: [],
      isFavorite: false,
      isFinalized: false,
      fileSizeBytes: 0,
      detectedEvents: [],
    );

    _activeOngoingSession = session;
    await _storageService.saveSessionMetadata(session);
    return session;
  }

  Future<void> discardOngoingSession() async {
    if (_activeOngoingSession != null) {
      final session = _activeOngoingSession!;
      _activeOngoingSession = null;
      try {
        await _storageService.deleteSession(session);
      } catch (_) {}
    }
  }

  Future<void> autoFlushOngoingSession({
    required Duration duration,
    required List<double> amplitudeHistory,
  }) async {
    if (_activeOngoingSession != null) {
      int sizeBytes = 0;
      if (!kIsWeb) {
        try {
          final audioFile = AppFile(_activeOngoingSession!.filePath);
          sizeBytes = await audioFile.exists() ? await audioFile.length() : 0;
        } catch (_) {}
      } else {
        // Approximate bytes on Web (16kHz 16bit mono = 32000 bytes/sec)
        sizeBytes = duration.inSeconds * 32000;
      }

      _activeOngoingSession = _activeOngoingSession!.copyWith(
        duration: duration,
        amplitudeHistory: amplitudeHistory,
        fileSizeBytes: sizeBytes,
      );

      final events = _activeOngoingSession!.recalculateEvents(_defaultNoiseThresholdDb);
      _activeOngoingSession = _activeOngoingSession!.copyWith(detectedEvents: events);

      await _storageService.saveSessionMetadata(_activeOngoingSession!);
    }
  }

  Future<RecordingSession> saveNewSession({
    required String audioFilePath,
    required DateTime startTime,
    required Duration duration,
    required List<double> amplitudeHistory,
  }) async {
    final sessionId = _activeOngoingSession?.id ?? 'session_${startTime.millisecondsSinceEpoch}';
    final dateStr = DateFormat('dd.MM.yyyy - HH:mm').format(startTime);
    final title = 'Schlaf vom $dateStr Uhr';

    int sizeBytes = 0;
    if (!kIsWeb) {
      try {
        final audioFile = AppFile(audioFilePath);
        sizeBytes = await audioFile.exists() ? await audioFile.length() : 0;
      } catch (_) {}
    } else {
      sizeBytes = duration.inSeconds * 32000;
    }

    List<DetectedEvent> events = [];
    List<double> finalWaveform = amplitudeHistory;

    // Estimate room noise floor to set an intelligent adaptive threshold
    final tempSession = RecordingSession(
      id: sessionId,
      title: title,
      filePath: audioFilePath,
      startTime: startTime,
      duration: duration,
      amplitudeHistory: amplitudeHistory,
      isFavorite: false,
      isFinalized: false,
      fileSizeBytes: sizeBytes,
      detectedEvents: const [],
    );
    final adaptiveThreshold = tempSession.getAdaptiveThresholdDb();

    if (!kIsWeb) {
      try {
        final audioFile = AppFile(audioFilePath);
        if (await audioFile.exists()) {
          final analysis = await _storageService.wavAnalyzer.analyzeWavFile(audioFile, thresholdDb: adaptiveThreshold);
          if (analysis.detectedEvents.isNotEmpty) {
            events = analysis.detectedEvents;
          }
          if (analysis.waveformHistory.isNotEmpty) {
            finalWaveform = analysis.waveformHistory;
          }
        }
      } catch (_) {}
    }

    var session = RecordingSession(
      id: sessionId,
      title: title,
      filePath: audioFilePath,
      startTime: startTime,
      duration: duration,
      amplitudeHistory: finalWaveform,
      isFavorite: false,
      isFinalized: true,
      fileSizeBytes: sizeBytes,
      detectedEvents: events,
    );

    if (events.isEmpty && amplitudeHistory.isNotEmpty) {
      final recalculated = session.recalculateEvents(session.getAdaptiveThresholdDb());
      session = session.copyWith(detectedEvents: recalculated);
    }

    await _storageService.saveSessionMetadata(session);
    _activeOngoingSession = null;

    // Refresh sessions list
    _sessions = await _storageService.loadAllSessions();
    notifyListeners();

    return session;
  }

  Future<void> toggleFavorite(String sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final updated = _sessions[idx].copyWith(isFavorite: !_sessions[idx].isFavorite);
      _sessions[idx] = updated;
      await _storageService.saveSessionMetadata(updated);
      notifyListeners();
    }
  }

  Future<void> toggleEventFavorite(String sessionId, String eventId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      DetectedEvent? targetEvent;
      final updatedEvents = session.detectedEvents.map((e) {
        if (e.id == eventId) {
          final newFav = !e.isFavorite;
          targetEvent = e.copyWith(isFavorite: newFav);
          return targetEvent!;
        }
        return e;
      }).toList();

      var updated = session.copyWith(detectedEvents: updatedEvents);
      _sessions[idx] = updated;
      await _storageService.saveSessionMetadata(updated);
      notifyListeners();

      // If newly favorited, pre-extract the snippet into standalone M4A so it's instantly protected
      if (targetEvent != null && targetEvent!.isFavorite) {
        final standalone = await _storageService.extractAndSaveFavoriteClip(updated, targetEvent!);
        if (standalone != null) {
          final remapped = updated.detectedEvents.map((e) {
            if (e.id == eventId) return e.copyWith(standaloneAudioPath: standalone);
            return e;
          }).toList();
          updated = updated.copyWith(detectedEvents: remapped);
          _sessions[idx] = updated;
          await _storageService.saveSessionMetadata(updated);
          notifyListeners();
        }
      }
    }
  }

  /// Returns all favorite clips across all nights (including nights whose raw WAV was deleted),
  /// sorted with the newest first.
  List<FavoriteClipItem> getAllFavoriteClips() {
    final List<FavoriteClipItem> list = [];
    for (final session in _sessions) {
      for (final event in session.detectedEvents) {
        if (event.isFavorite) {
          list.add(FavoriteClipItem(session: session, event: event));
        }
      }
    }
    list.sort((a, b) {
      final timeA = a.session.startTime.add(a.event.startOffset);
      final timeB = b.session.startTime.add(b.event.startOffset);
      return timeB.compareTo(timeA);
    });
    return list;
  }

  Future<void> updateEventTags(String sessionId, String eventId, List<String> tags) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final updatedEvents = session.detectedEvents.map((e) {
        if (e.id == eventId) {
          return e.copyWith(tags: tags);
        }
        return e;
      }).toList();
      final updated = session.copyWith(detectedEvents: updatedEvents);
      _sessions[idx] = updated;
      await _storageService.saveSessionMetadata(updated);
      notifyListeners();
    }
  }

  Future<void> updateSessionEvents(String sessionId, double thresholdDb) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      List<DetectedEvent> newEvents = [];

      if (!kIsWeb) {
        try {
          final audioFile = AppFile(session.filePath);
          if (await audioFile.exists()) {
            final result = await _storageService.wavAnalyzer.analyzeWavFile(audioFile, thresholdDb: thresholdDb);
            newEvents = result.detectedEvents;
          }
        } catch (_) {}
      }

      if (newEvents.isEmpty && session.amplitudeHistory.isNotEmpty) {
        newEvents = session.recalculateEvents(thresholdDb);
      }

      final updated = session.copyWith(detectedEvents: newEvents);
      _sessions[idx] = updated;
      await _storageService.saveSessionMetadata(updated);
      notifyListeners();
    }
  }

  Future<void> deleteSession(String sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      await _storageService.deleteSession(session);
      _sessions = await _storageService.loadAllSessions();
      notifyListeners();
    }
  }

  Future<String?> createBackupZip({void Function(double progress, String status)? onProgress}) async {
    return _storageService.createBackupZip(onProgress: onProgress);
  }

  Future<List<String>> getBackupFiles() async {
    return _storageService.getAllBackupFilePaths();
  }

  Future<RecordingSession> classifySessionWithAI(
    RecordingSession session, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final updated = await _storageService.classifySessionWithAI(session, onProgress: onProgress);
    final idx = _sessions.indexWhere((s) => s.id == session.id);
    if (idx != -1) {
      _sessions[idx] = updated;
    }
    notifyListeners();
    return updated;
  }

  Future<RecordingSession?> importRecording(String filePath, {String? customTitle}) async {
    final session = await _storageService.importAudioFile(filePath, customTitle: customTitle);
    if (session != null) {
      _sessions = await _storageService.loadAllSessions();
      notifyListeners();
    }
    return session;
  }
}
