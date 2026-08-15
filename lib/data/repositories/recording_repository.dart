import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../../domain/models/recording_session.dart';
import '../services/storage_service.dart';

class RecordingRepository extends ChangeNotifier {
  final StorageService _storageService = StorageService();

  List<RecordingSession> _sessions = [];
  List<RecordingSession> get sessions => List.unmodifiable(_sessions);

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

  Future<void> autoFlushOngoingSession({
    required Duration duration,
    required List<double> amplitudeHistory,
  }) async {
    if (_activeOngoingSession != null) {
      final audioFile = File(_activeOngoingSession!.filePath);
      final sizeBytes = await audioFile.exists() ? await audioFile.length() : 0;

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

    final audioFile = File(audioFilePath);
    final sizeBytes = await audioFile.exists() ? await audioFile.length() : 0;

    var session = RecordingSession(
      id: sessionId,
      title: title,
      filePath: audioFilePath,
      startTime: startTime,
      duration: duration,
      amplitudeHistory: amplitudeHistory,
      isFavorite: false,
      isFinalized: true,
      fileSizeBytes: sizeBytes,
      detectedEvents: [],
    );

    final events = session.recalculateEvents(_defaultNoiseThresholdDb);
    session = session.copyWith(detectedEvents: events);

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

  Future<void> updateSessionEvents(String sessionId, double thresholdDb) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final newEvents = session.recalculateEvents(thresholdDb);
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
      _sessions.removeAt(idx);
      notifyListeners();
    }
  }
}
