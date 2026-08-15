import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'battery_service.dart';
import 'logger_service.dart';
import 'notification_service.dart';
import 'platform_file/platform_file.dart';

enum RecordingState { stopped, testingMic, recordingSleep }

class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();
  final NotificationService _notificationService = NotificationService();
  final BatteryService _batteryService = BatteryService();
  final LoggerService _logger = LoggerService();

  RecordingState _state = RecordingState.stopped;
  RecordingState get state => _state;

  StreamController<double>? _amplitudeStreamController;
  Stream<double>? get amplitudeStream => _amplitudeStreamController?.stream;

  Timer? _recordingTimer;
  Timer? _amplitudeTimer;

  DateTime? _startTime;
  DateTime? get startTime => _startTime;

  Duration _elapsedDuration = Duration.zero;
  Duration get elapsedDuration => _elapsedDuration;

  final List<double> _amplitudeHistory = [];
  List<double> get amplitudeHistory => List.unmodifiable(_amplitudeHistory);

  double _currentDb = -60.0;
  double get currentDb => _currentDb;

  Function(String filePath, Duration duration, List<double> history)? onAutoSaveTriggered;
  Function(Duration duration, List<double> history)? onPeriodicFlush;

  Future<bool> hasMicPermission() async {
    try {
      final perm = await _recorder.hasPermission();
      await _logger.log('Mic permission check: $perm');
      return perm;
    } catch (_) {
      return true;
    }
  }

  /// Starts live mic test mode (for whisper / clap level feedback before sleep)
  Future<void> startLiveMicTest() async {
    if (_state != RecordingState.stopped) return;
    final hasPerm = await hasMicPermission();
    if (!hasPerm) return;

    await _logger.log('Started Live Mic Test Mode');
    _state = RecordingState.testingMic;
    _amplitudeStreamController = StreamController<double>.broadcast();

    // Start temporary recording to sample mic amplitude
    final tempPath = kIsWeb ? '' : '${getSystemTempPath()}/mic_test.wav';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: tempPath,
      );
    } catch (e) {
      await _logger.log('Live mic test start error: $e');
    }

    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
      if (_state == RecordingState.testingMic) {
        try {
          final amp = await _recorder.getAmplitude();
          _currentDb = amp.current.clamp(-60.0, 0.0);
          _amplitudeStreamController?.add(_currentDb);
        } catch (_) {}
      }
    });
  }

  /// Stops live mic test mode
  Future<void> stopLiveMicTest() async {
    if (_state != RecordingState.testingMic) return;
    await _logger.log('Stopped Live Mic Test Mode');
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _amplitudeStreamController?.close();
    _amplitudeStreamController = null;
    _state = RecordingState.stopped;
  }

  /// Starts overnight sleep recording
  Future<bool> startSleepRecording(String targetFilePath) async {
    if (_state == RecordingState.testingMic) {
      await stopLiveMicTest();
    }
    if (_state != RecordingState.stopped) return false;

    final hasPerm = await hasMicPermission();
    if (!hasPerm) {
      await _logger.log('ERROR: Cannot start recording - No Mic Permission!');
      return false;
    }

    await _logger.log('Starting Sleep Recording -> Target: $targetFilePath');
    _state = RecordingState.recordingSleep;
    _startTime = DateTime.now();
    _elapsedDuration = Duration.zero;
    _amplitudeHistory.clear();
    _amplitudeStreamController = StreamController<double>.broadcast();

    // Mobile background services
    if (!kIsWeb) {
      try {
        await WakelockPlus.enable();
        await _logger.log('Wakelock enabled successfully.');
      } catch (e) {
        await _logger.log('Wakelock enable warning: $e');
      }

      try {
        await _notificationService.init();
        await _notificationService.showRecordingNotification(durationText: '00:00:00');
        await _logger.log('Foreground notification started.');
      } catch (e) {
        await _logger.log('Notification error: $e');
      }

      _batteryService.startMonitoring(onLowBattery: () async {
        await _logger.log('CRITICAL: Low battery detected (<5%)! Emergency saving...');
        await emergencyStopAndSave();
      });
    }

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: kIsWeb ? '' : targetFilePath,
      );
      await _logger.log('AudioRecorder engine started writing.');
    } catch (e) {
      await _logger.log('FATAL: AudioRecorder.start exception: $e');
      _state = RecordingState.stopped;
      return false;
    }

    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsedDuration = Duration(seconds: timer.tick);
      final formattedDuration = _formatDuration(_elapsedDuration);
      if (!kIsWeb) {
        _notificationService.showRecordingNotification(durationText: formattedDuration);
      }

      if (timer.tick % 30 == 0) {
        onPeriodicFlush?.call(_elapsedDuration, List.from(_amplitudeHistory));
        _logger.log('Periodic auto-flush at duration: $formattedDuration (${_amplitudeHistory.length} samples)');
      }
    });

    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (_state == RecordingState.recordingSleep) {
        try {
          final amp = await _recorder.getAmplitude();
          final db = amp.current.clamp(-60.0, 0.0);
          _currentDb = db;
          _amplitudeHistory.add(db);
          _amplitudeStreamController?.add(db);
        } catch (e) {
          _logger.log('Amplitude sampling exception: $e');
        }
      }
    });

    return true;
  }

  /// Stops sleep recording and returns recorded metadata
  Future<String?> stopSleepRecording() async {
    if (_state != RecordingState.recordingSleep) return null;

    await _logger.log('Stopping Sleep Recording... Elapsed: ${_formatDuration(_elapsedDuration)}');

    _recordingTimer?.cancel();
    _recordingTimer = null;
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    
    if (!kIsWeb) {
      _batteryService.stopMonitoring();
    }

    String? path;
    try {
      path = await _recorder.stop();
      if (!kIsWeb && path != null) {
        final f = AppFile(path);
        final size = await f.length();
        await _logger.log('Recording stopped cleanly. Saved file size: $size bytes ($path)');
      }
    } catch (e) {
      await _logger.log('Recorder stop exception: $e');
    }

    if (!kIsWeb) {
      await _notificationService.cancelRecordingNotification();
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }

    _amplitudeStreamController?.close();
    _amplitudeStreamController = null;
    _state = RecordingState.stopped;

    return path;
  }

  /// Emergency stop & auto-save (e.g. low battery < 5%)
  Future<void> emergencyStopAndSave() async {
    if (_state == RecordingState.recordingSleep) {
      await _logger.log('Executing emergencyStopAndSave()...');
      final finalPath = await stopSleepRecording();
      if (finalPath != null) {
        onAutoSaveTriggered?.call(finalPath, _elapsedDuration, List.from(_amplitudeHistory));
      }
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  void dispose() {
    _recordingTimer?.cancel();
    _amplitudeTimer?.cancel();
    _recorder.dispose();
  }
}
